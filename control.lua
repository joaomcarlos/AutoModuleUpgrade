local DEBUG = false
local LOG_TICKS = false -- If true, print [TICK] and [SKIP] queue logs
local MOVE_CAMERA_AFTER_UPGRADE = false -- Center camera on building after applying module upgrades
local HOVER_APPLY = false -- If true, auto-apply module upgrades on crosshair select (on_selected_entity_changed)

local USE_RATE_PRIORITY = true -- If true, use tracker-based queuing; if false, direct queue from scan
local USE_ABSOLUTE_PF = false -- If true and USE_RATE_PRIORITY is true, sort by total products_finished; if false, sort by production rate diff

-- Priority configuration
local MIN_READINGS = 2 -- Minimum pf snapshots before rate-based sorting kicks in (only for USE_RATE_PRIORITY)

-- Scan configuration
local UPS = 60 -- Game updates per second
local SCAN_INTERVAL_SEC = 30 -- Seconds between scans
local SCAN_INTERVAL = SCAN_INTERVAL_SEC * UPS -- Ticks between scans
-- 16 aggressive, 4 conservative
local SCAN_CHUNKS_PER_STEP = 64 -- Max chunks scanned per scheduler step
-- 100 aggresive, 25 conservative
local SCAN_ENTITIES_PER_STEP = 100 -- Max candidate buildings evaluated per scheduler step

-- Priority configuration
local MIN_PF_DIFF = 15 -- Minimum production rate in items per minute to be eligible for rate-priority queuing
local QUEUE_SIZE_PER_PLANET = 100 -- Max buildings queued per surface per scan
local MAX_TRACKED_PER_PLANET = 1000 -- Max buildings tracked per surface for rate-based priority

-- Planet configuration
local PLANETS = {"nauvis", "vulcanus", "gleba", "fulgora", "aquilo"}
local NO_PF_ENTITIES = {["agricultural-tower"] = true, ["beacon"] = true} -- Buildings that don't track products_finished; skip PF checks
local AMU_WINDOW_NAME = "amu_scan_window"

-- Entity types that can receive quality upgrades but have no module slots
local QUALITY_UPGRADEABLE_TYPES = {
  ["agricultural-tower"] = true,
}

-- Module-level lookup tables (rebuilt on load, not stored in storage)
local module_tiers = {}
local module_categories = {}
local quality_order = {"normal", "uncommon", "rare", "epic", "legendary"}
local quality_index = {normal = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5}

-- Build lookup tables from item prototypes
-- Uses LuaItemPrototype.category and LuaItemPrototype.tier (official API)
local function build_module_lookups()
  module_tiers = {}
  module_categories = {}
  for name, proto in pairs(prototypes.item) do
    if proto.module_effects and proto.category and proto.tier then
      module_tiers[name] = proto.tier
      module_categories[name] = proto.category
    end
  end
end

-- Helpers for tracking network reservations during a scan
local function network_has_items(logistic_network, name, quality, count, reservations)
  if not logistic_network then return false end
  if not prototypes.item[name] then return false end
  local available = logistic_network.get_item_count({name = name, quality = quality})
  if available < count then return false end
  if not reservations then return true end
  local key = name .. ":" .. quality
  local reserved = reservations[key] or 0
  return available - reserved >= count
end

local function reserve_items(reservations, name, quality, count)
  if not reservations then return end
  local key = name .. ":" .. quality
  reservations[key] = (reservations[key] or 0) + count
end

local function reserve_module_plan_items(reservations, modules_plan)
  if not reservations or not modules_plan then return end
  for _, request in ipairs(modules_plan) do
    if request.id and request.id.name then
      reserve_items(reservations, request.id.name, request.id.quality or "normal", 1)
    end
  end
end

-- Power-score-based search for quality modules
local function find_quality_module_upgrade(module_name, module_quality, logistic_network, reservations)
  local current_tier = module_tiers[module_name]
  if not current_tier then return nil, nil end

  local proto = prototypes.item[module_name]
  if not proto then return nil, nil end

  -- Extract quality bonus from module_effects table: {quality = 0.01}
  local base_effect = 0
  if proto.module_effects and proto.module_effects.quality then
    base_effect = proto.module_effects.quality
  end

  local current_q = prototypes.quality[module_quality]
  local current_score = base_effect * (current_q and current_q.default_multiplier or 1)

  -- Collect all better quality-module variants
  local candidates = {}
  for name, tier in pairs(module_tiers) do
    if module_categories[name] == "quality" then
      local p = prototypes.item[name]
      if p and p.module_effects and p.module_effects.quality then
        local be = p.module_effects.quality
        for qname, qproto in pairs(prototypes.quality) do
          local score = be * qproto.default_multiplier
          if score > current_score then
            table.insert(candidates, {
              name = name,
              quality = qname,
              score = score
            })
          end
        end
      end
    end
  end

  -- Sort by score descending (best first)
  table.sort(candidates, function(a, b) return a.score > b.score end)

  -- Return first available in network
  for _, cand in ipairs(candidates) do
    if network_has_items(logistic_network, cand.name, cand.quality, 1, reservations) then
      return cand.name, cand.quality
    end
  end

  return nil, nil
end

-- Get the next upgrade candidate for a module
-- Returns: upgrade_name, upgrade_quality or nil, nil
local function find_upgrade(module_name, module_quality, logistic_network, reservations)
  if not module_name or not module_quality then return nil, nil end

  local category = module_categories[module_name]
  local tier = module_tiers[module_name]
  if not category or not tier then
    if DEBUG then game.print("[AutoModuleUpgrade] [UPG DEBUG] No category/tier for " .. tostring(module_name)) end
    return nil, nil
  end

  -- Is this a quality module? Use power-score-based search
  if category == "quality" then
    return find_quality_module_upgrade(module_name, module_quality, logistic_network, reservations)
  end

  -- Speed, efficiency, productivity: tier-first, then quality
  local current_qidx = quality_index[module_quality] or 1

  -- Step 1: Same tier, better quality (best to worst)
  for qidx = 5, current_qidx + 1, -1 do
    local qname = quality_order[qidx]
    if network_has_items(logistic_network, module_name, qname, 1, reservations) then
      return module_name, qname
    end
  end

  -- Step 2: Next tier, normal quality
  local next_tier = tier + 1
  local next_tier_name = category .. "-module-" .. next_tier
  if prototypes.item[next_tier_name] and network_has_items(logistic_network, next_tier_name, "normal", 1, reservations) then
    return next_tier_name, "normal"
  end

  return nil, nil
end

-- Find best available module of a given category for empty slots
-- For speed/efficiency/productivity: highest tier, then best quality
-- For quality modules: highest power score (quality.bonus * multiplier)
-- needed_count: how many items are required (defaults to 1)
local function find_best_available(category, logistic_network, reservations, needed_count)
  needed_count = needed_count or 1
  local best = nil

  if category == "quality" then
    -- Power-score based for quality modules
    local best_score = -1
    for name, tier in pairs(module_tiers) do
      if module_categories[name] == "quality" then
        local p = prototypes.item[name]
        if p and p.module_effects and p.module_effects.quality then
          local be = p.module_effects.quality
          for qname, qproto in pairs(prototypes.quality) do
            if network_has_items(logistic_network, name, qname, needed_count, reservations) then
              local score = be * qproto.default_multiplier
              if score > best_score then
                best = {name = name, quality = qname}
                best_score = score
              end
            end
          end
        end
      end
    end
  else
    -- Tier-first for speed/efficiency/productivity
    local best_tier = 0
    local best_qidx = 0
    for name, tier in pairs(module_tiers) do
      if module_categories[name] == category then
        for qname, qproto in pairs(prototypes.quality) do
          if network_has_items(logistic_network, name, qname, needed_count, reservations) then
            local qidx = quality_index[qname] or 0
            if tier > best_tier or (tier == best_tier and qidx > best_qidx) then
              best_tier = tier
              best_qidx = qidx
              best = {name = name, quality = qname}
            end
          end
        end
      end
    end
  end

  return best
end

-- Create or update item-request-proxy
local function create_module_proxy(entity, slot_index, old_module, old_quality, new_module, new_quality)
  local surface = entity.surface
  local module_inv = entity.get_module_inventory()
  if not module_inv then return end

  local inv_index = module_inv.index
  local stack_0based = slot_index - 1

  -- Remove existing proxy if any
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    entity.item_request_proxy.destroy()
  end

  -- Create new proxy with insert + removal plan
  local modules_plan = {
    {
      id = {name = new_module, quality = new_quality},
      items = {in_inventory = {{inventory = inv_index, stack = stack_0based}}}
    }
  }

  local removal_plan = {
    {
      id = {name = old_module, quality = old_quality},
      items = {in_inventory = {{inventory = inv_index, stack = stack_0based}}}
    }
  }

  surface.create_entity{
    name = "item-request-proxy",
    target = entity,
    position = entity.position,
    force = entity.force,
    modules = modules_plan,
    removal_plan = removal_plan
  }
end

-- Create insert-only proxy for empty slots
local function create_insert_proxy(entity, requests)
  local surface = entity.surface

  -- Remove existing proxy if any
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    entity.item_request_proxy.destroy()
  end

  local modules_plan = {}
  for _, req in ipairs(requests) do
    table.insert(modules_plan, {
      id = {name = req.name, quality = req.quality},
      items = {in_inventory = {{inventory = req.inventory, stack = req.stack}}}
    })
  end

  surface.create_entity{
    name = "item-request-proxy",
    target = entity,
    position = entity.position,
    force = entity.force,
    modules = modules_plan
  }
end

-- Get the next higher quality level for a building (e.g. epic -> legendary)
local function get_next_building_quality(entity)
  if not entity.quality then return nil end
  local current_name = entity.quality.name
  local idx = quality_index[current_name]
  if not idx or idx >= #quality_order then return nil end
  return quality_order[idx + 1]
end

-- Check a single building for upgrades/fills
-- Returns: "upgrade", "fill", "none", or "skip" (plus optional info string)
local function check_building(entity, context)
  if not entity.valid then return "skip", "invalid" end
  if entity.type == "entity-ghost" or entity.type == "tile-ghost" or entity.to_be_deconstructed() then return "skip", "ghost/decon" end
  local logistic_network = entity.surface.find_logistic_network_by_position(entity.position, entity.force)
  if not logistic_network then return "none", "no logistic network" end

  local reservations = context and context.reservations or nil

  local has_modules = entity.prototype and entity.prototype.module_inventory_size and entity.prototype.module_inventory_size > 0
  local module_inv = has_modules and entity.get_module_inventory() or nil

  local filled_slots = {}
  local empty_slots = {}
  local category_counts = {}
  local module_count = 0

  if module_inv then
    module_count = #module_inv
    -- Scan all slots
    for slot = 1, module_count do
      local stack = module_inv[slot]
      if stack and stack.valid_for_read then
        table.insert(filled_slots, {slot = slot, name = stack.name, quality = stack.quality.name})
        local cat = module_categories[stack.name]
        if cat then
          category_counts[cat] = (category_counts[cat] or 0) + 1
        end
      else
        table.insert(empty_slots, slot)
      end
    end
  end

  -- Helper: abbreviate module name for logs
  local function abbr(name, quality)
    local cat = module_categories[name] or name:match("^(.-)-module") or name
    local tier = module_tiers[name] or ""
    local q = (quality or ""):sub(1, 3)
    return cat:sub(1, 4) .. tier .. q
  end

  local modules_plan = {}
  local removal_plan = {}
  local upgrade_counts = {} -- key -> count for grouping
  local fill_details = {}
  local did_anything = false

  -- Phase A: Upgrade existing modules
  for _, slot_info in ipairs(filled_slots) do
    local new_name, new_quality = find_upgrade(slot_info.name, slot_info.quality, logistic_network, reservations)
    if new_name and new_quality then
      local stack_0based = slot_info.slot - 1
      table.insert(modules_plan, {
        id = {name = new_name, quality = new_quality},
        items = {in_inventory = {{inventory = module_inv.index, stack = stack_0based}}}
      })
      table.insert(removal_plan, {
        id = {name = slot_info.name, quality = slot_info.quality},
        items = {in_inventory = {{inventory = module_inv.index, stack = stack_0based}}}
      })
      local key = abbr(slot_info.name, slot_info.quality) .. "->" .. abbr(new_name, new_quality)
      upgrade_counts[key] = (upgrade_counts[key] or 0) + 1
      if reservations then
        reserve_items(reservations, new_name, new_quality, 1)
      end
      did_anything = true
    end
  end

  -- Phase B: Fill empty slots
  if #empty_slots > 0 then
    local best = nil
    if #filled_slots > 0 then
      -- Match category of the first existing module in this building
      local target_category = module_categories[filled_slots[1].name] or "productivity"
      best = find_best_available(target_category, logistic_network, reservations, #empty_slots)
      if not best then
        best = find_best_available("speed", logistic_network, reservations, #empty_slots)
      end
    else
      -- Empty machine: prefer productivity if allowed, else speed
      local proto = entity.prototype
      local productivity_allowed = proto.allowed_effects and proto.allowed_effects.productivity == true
      if productivity_allowed then
        best = find_best_available("productivity", logistic_network, reservations, #empty_slots)
      end
      if not best then
        best = find_best_available("speed", logistic_network, reservations, #empty_slots)
      end
    end
    if best then
      for _, slot in ipairs(empty_slots) do
        table.insert(modules_plan, {
          id = {name = best.name, quality = best.quality},
          items = {in_inventory = {{inventory = module_inv.index, stack = slot - 1}}}
        })
      end
      table.insert(fill_details, abbr(best.name, best.quality) .. " x" .. #empty_slots)
      if reservations then
        reserve_items(reservations, best.name, best.quality, #empty_slots)
      end
      did_anything = true
    end
  end

  if not did_anything then
    -- No module work; check if the building itself can receive a quality upgrade
    local target_quality = get_next_building_quality(entity)
    if target_quality and network_has_items(logistic_network, entity.name, target_quality, 1, reservations) then
      local info_str = "quality -> " .. target_quality
      if not (context and context.dry_run) then
        if try_defer_quality_upgrade(entity, entity.surface.name, modules_plan, removal_plan, info_str, reservations) then
          return "upgrade", info_str, modules_plan, removal_plan
        end
      end
      -- dry_run path for scan: still report as upgrade so it gets queued
      return "upgrade", info_str, modules_plan, removal_plan
    end
  end

  if did_anything then
    local parts = {}
    if next(upgrade_counts) then
      local upg_parts = {}
      for key, count in pairs(upgrade_counts) do
        table.insert(upg_parts, count .. "x" .. key)
      end
      table.insert(parts, "upg: " .. table.concat(upg_parts, ", "))
    end
    if #fill_details > 0 then table.insert(parts, "fill: " .. table.concat(fill_details, ", ")) end
    local info_str = table.concat(parts, "; ")

    -- Create combined proxy if anything was done (skipped in dry_run mode)
    if not (context and context.dry_run) then
      if entity.item_request_proxy and entity.item_request_proxy.valid then
        entity.item_request_proxy.destroy()
      end
      entity.surface.create_entity{
        name = "item-request-proxy",
        target = entity,
        position = entity.position,
        force = entity.force,
        modules = modules_plan,
        removal_plan = removal_plan
      }
      local surf_name = entity.surface.name
      local do_camera = storage.global_camera_follow
      if do_camera == nil then
        do_camera = storage.surface_camera_follow[surf_name] == true
      end
      if do_camera then
        for _, player in pairs(game.connected_players) do
          if player.force == entity.force then
            player.centered_on = entity
            break
          end
        end
      end
      if DEBUG or storage.LOG_OVERRIDE then
        game.print("[AutoModuleUpgrade] [APPLY] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " — " .. info_str)
      end
    end

    return "upgrade", info_str, modules_plan, removal_plan
  end

  return "none", "no upgrade or fill available", nil, nil
end

-- Queue-based processing: per-surface queues, process 1 per tick per surface
local processing_queues = {} -- surface_name -> {queue = {}, batch_upgraded = 0, batch_filled = 0}

-- Building tracker: unit_number -> {entity, pf_history, tick_history, last_diff, modules_plan, removal_plan, info}
-- Tracks up to 1000 buildings; after 3 pf reads, sorts by diff for priority queuing
local building_tracker = {}

-- Pending building quality replacements: buildings marked for deconstruction + ghost placed
-- {surface_name, position={x,y}, entity_name, target_quality, saved_pf, modules_plan, removal_plan, info, tick_queued}
local pending_replacements = {}
local DEFERRED_MAX_AGE = 3600 * 60 -- 1 hour timeout in ticks

-- Normalize raw diff to items per minute based on actual interval between readings
local function get_rate_per_min(entry)
  local n = #entry.pf_history
  if n < 2 then return 0 end
  local ticks_diff = entry.tick_history[n] - entry.tick_history[n - 1]
  if ticks_diff <= 0 then return 0 end
  return entry.last_diff * 3600 / ticks_diff
end

local function get_products_finished(entity)
  local ok, val = pcall(function() return entity.products_finished end)
  return ok and val or 0
end

-- Format a building's production info for logging:
--   rate if tracker has enough data, else raw products_finished
local function format_pf_rate(entity)
  local ok, pf = pcall(function() return entity.products_finished end)
  if not ok then return "n/a" end
  if entity.unit_number and building_tracker[entity.unit_number] then
    local r = get_rate_per_min(building_tracker[entity.unit_number])
    if r > 0 then
      return math.floor(r + 0.5) .. "/min"
    end
  end
  -- No meaningful rate yet; show raw products_finished
  return tostring(pf)
end

-- Attempt to defer a building for quality upgrade; returns true if deferred
-- Uses order_upgrade so the building stays functional until bots replace it
local function try_defer_quality_upgrade(entity, surface_name, modules_plan, removal_plan, info, reservations)
  local target_quality = get_next_building_quality(entity)
  if not target_quality then return false end
  local logistic_network = entity.surface.find_logistic_network_by_position(entity.position, entity.force)
  if not network_has_items(logistic_network, entity.name, target_quality, 1, reservations) then
    return false
  end
  local saved_pf = get_products_finished(entity)
  local upgrade_ok = pcall(function()
    entity.order_upgrade{
      force = entity.force,
      target = {name = entity.name, quality = target_quality}
    }
  end)
  if upgrade_ok then
    reserve_items(reservations, entity.name, target_quality, 1)
    reserve_module_plan_items(reservations, modules_plan)
    table.insert(pending_replacements, {
      surface_name = surface_name,
      position = entity.position,
      entity_name = entity.name,
      target_quality = target_quality,
      saved_pf = saved_pf,
      modules_plan = modules_plan,
      removal_plan = removal_plan,
      info = info,
      tick_queued = game.tick,
      original_unit_number = entity.unit_number
    })
    if DEBUG then
      game.print("[AutoModuleUpgrade] [DEFER] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " -> " .. target_quality .. " (pf_rate=" .. format_pf_rate(entity) .. ")")
    end
    return true
  end
  return false
end

local function get_or_create_surface_queue(surface_name)
  if not processing_queues[surface_name] then
    processing_queues[surface_name] = {queue = {}, batch_upgraded = 0, batch_filled = 0}
  end
  return processing_queues[surface_name]
end

local function seed_pending_replacement_reservations(surface_name, reservations)
  for _, task in ipairs(pending_replacements) do
    if task.surface_name == surface_name then
      reserve_items(reservations, task.entity_name, task.target_quality, 1)
      reserve_module_plan_items(reservations, task.modules_plan)
    end
  end
end

local scan_queue = {}
local queued_scan_surfaces = {}
local scan_cycle_surfaces = {}
local active_scan_job = nil

-- Per-surface scan status for GUI: surface_name -> {last_scan_tick, current_scan_start_tick, phase, candidates, queued, scanned}
local scan_status = {}

-- Persistent data stored in storage (survives save/load):
--   storage.surface_buildings_upgraded[surface_name] -> count
--   storage.surface_modules_placed[surface_name] -> {module_name -> count}
--   storage.surface_last_upgraded[surface_name] -> {x, y, tick}
--   storage.surface_camera_follow[surface_name] -> boolean
--   storage.global_camera_follow -> nil/true/false
--   storage.LOG_OVERRIDE -> boolean

-- Player scan window state: player_index -> {window, visible}
local amu_gui_players = {}

local function get_player_force_names()
  local force_names = {}
  local seen = {}
  for _, player in pairs(game.players) do
    if player.force and not seen[player.force.name] then
      seen[player.force.name] = true
      table.insert(force_names, player.force.name)
    end
  end
  return force_names
end

local function is_upgrade_candidate(entity)
  if not entity.valid then return false end
  if entity.type == "entity-ghost" or entity.type == "tile-ghost" or entity.to_be_deconstructed() then return false end
  if entity.prototype and entity.prototype.module_inventory_size and entity.prototype.module_inventory_size > 0 then
    return true
  end
  -- Also include buildings that can receive a quality upgrade (e.g. agricultural tower)
  if QUALITY_UPGRADEABLE_TYPES[entity.type] and get_next_building_quality(entity) then
    return true
  end
  return false
end

local function enqueue_scan(surface_name)
  if active_scan_job and active_scan_job.surface_name == surface_name then
    return false
  end
  if scan_cycle_surfaces[surface_name] or queued_scan_surfaces[surface_name] then
    return false
  end
  if not game.surfaces[surface_name] then
    return false
  end
  scan_cycle_surfaces[surface_name] = true
  queued_scan_surfaces[surface_name] = true
  table.insert(scan_queue, surface_name)
  return true
end

local function enqueue_all_scans()
  local added = 0
  for _, surface_name in ipairs(PLANETS) do
    if enqueue_scan(surface_name) then
      added = added + 1
    end
  end
  return added
end

local function finish_scan_job(job)
  if DEBUG then
    if job.mode == "rate" then
      local with_rate = 0
      for _, e in ipairs(job.tracked_list or {}) do
        if get_rate_per_min(e) > 0 then with_rate = with_rate + 1 end
      end
      local mode = with_rate > 0 and "[RATE]" or "[TOTAL]"
      game.print("[AutoModuleUpgrade] [QUEUE] Tracked=" .. #(job.tracked_list or {}) .. " (rate-ready=" .. with_rate .. "), queued=" .. job.queued .. " " .. mode)
    elseif job.mode == "absolute" and job.queued > 0 then
      game.print("[AutoModuleUpgrade] [QUEUE] Absolute queued=" .. job.queued .. " for " .. job.surface_name)
    elseif job.mode == "direct" and job.queued > 0 then
      game.print("[AutoModuleUpgrade] [QUEUE] Direct queued=" .. job.queued .. " for " .. job.surface_name)
    end
  end
  scan_status[job.surface_name] = {
    last_scan_tick = game.tick,
    current_scan_start_tick = nil,
    phase = "idle",
    candidates = job.all_entities and #job.all_entities or 0,
    queued = job.queued,
    scanned = job.scanned
  }
  active_scan_job = nil
  if #scan_queue == 0 then
    scan_cycle_surfaces = {}
  end
end

local function start_next_scan_job()
  if not next(module_tiers) then
    build_module_lookups()
  end

  while #scan_queue > 0 do
    local surface_name = table.remove(scan_queue, 1)
    queued_scan_surfaces[surface_name] = nil

    local surface = game.surfaces[surface_name]
    if surface then
      local sq = get_or_create_surface_queue(surface_name)
      sq.queue = {}
      sq.batch_upgraded = 0
      sq.batch_filled = 0

      local reservations = {}
      seed_pending_replacement_reservations(surface_name, reservations)

      active_scan_job = {
        surface_name = surface_name,
        surface = surface,
        chunk_iterator = surface.get_chunks(),
        force_names = get_player_force_names(),
        phase = "collect",
        mode = USE_ABSOLUTE_PF and "absolute" or (USE_RATE_PRIORITY and "rate" or "direct"),
        all_entities = {},
        index = 1,
        queued = 0,
        reservations = reservations,
        current_tick = game.tick,
        scanned = 0,
        skipped_proxy = 0,
        skipped_low_pf = 0,
        skipped_no_work = 0,
        sq = sq
      }

      scan_status[surface_name] = {
        last_scan_tick = scan_status[surface_name] and scan_status[surface_name].last_scan_tick or nil,
        current_scan_start_tick = game.tick,
        phase = "collect",
        candidates = 0,
        queued = 0,
        scanned = 0
      }

      if DEBUG then
        game.print("[AutoModuleUpgrade] [SCAN] Started incremental scan for " .. surface_name)
      end
      return
    end
  end
end

local function step_scan_collect(job)
  local chunks_scanned = 0

  while chunks_scanned < SCAN_CHUNKS_PER_STEP do
    local ok, chunk = pcall(job.chunk_iterator)
    if not ok or not chunk then
      if #job.all_entities == 0 then
        finish_scan_job(job)
        return
      end

      table.sort(job.all_entities, function(a, b)
        return get_products_finished(a) > get_products_finished(b)
      end)

      job.phase = "evaluate"
      job.index = 1
      if DEBUG then
        local first_ent = job.all_entities[1]
        local top_rate = first_ent and format_pf_rate(first_ent) or "n/a"
        game.print("[AutoModuleUpgrade] [SCAN] Collected " .. #job.all_entities .. " candidates for " .. job.surface_name .. " top_pf_rate=" .. top_rate)
      end
      return
    end

    if job.surface.is_chunk_generated({chunk.x, chunk.y}) then
      for _, force_name in ipairs(job.force_names) do
        for _, entity in pairs(job.surface.find_entities_filtered{area = chunk.area, force = force_name}) do
          if is_upgrade_candidate(entity) then
            table.insert(job.all_entities, entity)
          end
        end
      end
    end
    chunks_scanned = chunks_scanned + 1
  end
  local st = scan_status[job.surface_name]
  if st then st.candidates = #job.all_entities end
end

local function queue_entity_from_scan(job, entity)
  local result, info, modules_plan, removal_plan = check_building(entity, {dry_run = true, reservations = job.reservations})
  if result == "upgrade" or result == "fill" then
    if try_defer_quality_upgrade(entity, job.surface_name, modules_plan, removal_plan, info, job.reservations) then
      job.queued = job.queued + 1
      return
    end
    table.insert(job.sq.queue, {
      entity = entity,
      modules_plan = modules_plan,
      removal_plan = removal_plan,
      info = info
    })
    job.queued = job.queued + 1
  end
end

local function step_absolute_or_direct_scan(job)
  local processed = 0

  while processed < SCAN_ENTITIES_PER_STEP and job.index <= #job.all_entities do
    if job.queued >= QUEUE_SIZE_PER_PLANET then
      finish_scan_job(job)
      return
    end

    local entity = job.all_entities[job.index]
    job.index = job.index + 1

    if entity.valid and not (entity.item_request_proxy and entity.item_request_proxy.valid) then
      queue_entity_from_scan(job, entity)
    end
    processed = processed + 1
  end

  if job.index > #job.all_entities then
    finish_scan_job(job)
  end
  local st = scan_status[job.surface_name]
  if st then st.queued = job.queued end
end

local function step_rate_scan(job)
  local MIN_PRODUCTS = 50

  if job.phase == "evaluate" then
    local processed = 0
    while processed < SCAN_ENTITIES_PER_STEP and job.index <= #job.all_entities do
      if job.scanned >= MAX_TRACKED_PER_PLANET then
        job.phase = "prepare_tracked_queue"
        return
      end

      local entity = job.all_entities[job.index]
      job.index = job.index + 1
      processed = processed + 1

      if not entity.valid then goto rate_continue end
      if entity.item_request_proxy and entity.item_request_proxy.valid then
        job.skipped_proxy = job.skipped_proxy + 1
        goto rate_continue
      end

      local un = entity.unit_number
      if not un then goto rate_continue end

      local pf = get_products_finished(entity)
      local skip_pf_check = NO_PF_ENTITIES[entity.name]
      if not skip_pf_check and pf < MIN_PRODUCTS then
        job.skipped_low_pf = job.skipped_low_pf + 1
        goto rate_continue
      end

      local result, info, modules_plan, removal_plan = check_building(entity, {dry_run = true})
      if result == "upgrade" or result == "fill" then
        local entry = building_tracker[un]
        if entry then
          table.insert(entry.pf_history, pf)
          table.insert(entry.tick_history, job.current_tick)
          if #entry.pf_history > 5 then
            table.remove(entry.pf_history, 1)
            table.remove(entry.tick_history, 1)
          end
          local n = #entry.pf_history
          if n >= 2 then
            entry.last_diff = entry.pf_history[n] - entry.pf_history[n - 1]
          end
          entry.entity = entity
          entry.modules_plan = modules_plan
          entry.removal_plan = removal_plan
          entry.info = info
        else
          building_tracker[un] = {
            entity = entity,
            pf_history = {pf},
            tick_history = {job.current_tick},
            last_diff = 0,
            modules_plan = modules_plan,
            removal_plan = removal_plan,
            info = info
          }
        end
        job.scanned = job.scanned + 1
      else
        job.skipped_no_work = job.skipped_no_work + 1
        building_tracker[un] = nil
      end
      ::rate_continue::
    end

    if job.index > #job.all_entities then
      job.phase = "prepare_tracked_queue"
    end
    local st = scan_status[job.surface_name]
    if st then st.scanned = job.scanned; st.phase = job.phase end
    return
  end

  if job.phase == "prepare_tracked_queue" then
    local st = scan_status[job.surface_name]
    if st then st.phase = job.phase; st.candidates = #job.all_entities end
    if DEBUG then
      local first_ent = job.all_entities[1]
      local top_rate = first_ent and format_pf_rate(first_ent) or "n/a"
      game.print("[AutoModuleUpgrade] [DIAG] total=" .. #job.all_entities .. " top_pf_rate=" .. top_rate .. " proxy=" .. job.skipped_proxy .. " low_pf=" .. job.skipped_low_pf .. " no_work=" .. job.skipped_no_work .. " tracked=" .. job.scanned)
    end

    for un, entry in pairs(building_tracker) do
      if not entry.entity or not entry.entity.valid then
        building_tracker[un] = nil
      end
    end

    job.tracked_list = {}
    for un, entry in pairs(building_tracker) do
      if entry.entity and entry.entity.valid then
        table.insert(job.tracked_list, entry)
      end
    end

    table.sort(job.tracked_list, function(a, b)
      local a_rate = get_rate_per_min(a)
      local b_rate = get_rate_per_min(b)
      local a_has_data = a_rate > 0
      local b_has_data = b_rate > 0
      if a_has_data and b_has_data then
        return a_rate > b_rate
      elseif a_has_data then
        return true
      elseif b_has_data then
        return false
      else
        local a_pf = a.pf_history[#a.pf_history] or 0
        local b_pf = b.pf_history[#b.pf_history] or 0
        return a_pf > b_pf
      end
    end)

    job.phase = "queue_tracked"
    job.index = 1
    return
  end

  if job.phase == "queue_tracked" then
    local processed = 0
    while processed < SCAN_ENTITIES_PER_STEP and job.index <= #job.tracked_list do
      if job.queued >= QUEUE_SIZE_PER_PLANET then
        finish_scan_job(job)
        return
      end

      local entry = job.tracked_list[job.index]
      job.index = job.index + 1
      processed = processed + 1

      if entry.entity and entry.entity.valid then
        queue_entity_from_scan(job, entry.entity)
      end
    end

    if job.index > #job.tracked_list then
      finish_scan_job(job)
    end
  end
  local st = scan_status[job.surface_name]
  if st then st.queued = job.queued; st.phase = job.phase end
end

local function step_scan_scheduler()
  if not active_scan_job then
    start_next_scan_job()
  end
  local job = active_scan_job
  if not job then return end

  if not job.surface or not job.surface.valid or not game.surfaces[job.surface_name] then
    finish_scan_job(job)
    return
  end

  if job.phase == "collect" then
    step_scan_collect(job)
  elseif job.mode == "rate" then
    step_rate_scan(job)
  else
    step_absolute_or_direct_scan(job)
  end
end

local function refill_queue(surface_name)
  enqueue_scan(surface_name)
end

-- Apply a pre-computed plan directly (no re-evaluation)
local function apply_building_plan(entity, modules_plan, removal_plan, info)
  if not entity.valid then return end
  local has_modules = modules_plan and next(modules_plan)
  local has_removals = removal_plan and next(removal_plan)
  if not has_modules and not has_removals then return end

  -- Track stats
  local surface_name = entity.surface.name
  storage.surface_buildings_upgraded[surface_name] = (storage.surface_buildings_upgraded[surface_name] or 0) + 1
  storage.surface_last_upgraded[surface_name] = {
    x = entity.position.x,
    y = entity.position.y,
    tick = game.tick
  }
  if has_modules then
    if not storage.surface_modules_placed[surface_name] then
      storage.surface_modules_placed[surface_name] = {}
    end
    for _, module_name in pairs(modules_plan) do
      storage.surface_modules_placed[surface_name][module_name] = (storage.surface_modules_placed[surface_name][module_name] or 0) + 1
    end
  end

  if entity.item_request_proxy and entity.item_request_proxy.valid then
    entity.item_request_proxy.destroy()
  end
  entity.surface.create_entity{
    name = "item-request-proxy",
    target = entity,
    position = entity.position,
    force = entity.force,
    modules = modules_plan,
    removal_plan = removal_plan
  }
  if DEBUG then
    game.print("[AutoModuleUpgrade] [APPLY] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " pf_rate=" .. format_pf_rate(entity) .. " — " .. (info or ""))
  end
end

-- Process one building from each surface queue every tick
local function on_tick_handler()
  for surface_name, sq in pairs(processing_queues) do
    if LOG_TICKS and #sq.queue > 0 then
      game.print("[AutoModuleUpgrade] [TICK] " .. surface_name .. " queue=" .. #sq.queue)
    end
    if #sq.queue > 0 then
      local entry = table.remove(sq.queue, 1)
      local entity = entry.entity
      if entity.valid then
        -- Skip if rate-priority mode and building has no meaningful rate yet
        if USE_RATE_PRIORITY then
          local skip_rate = NO_PF_ENTITIES[entity.name]
          if not skip_rate then
            local tr = entity.unit_number and building_tracker[entity.unit_number]
            if not tr or get_rate_per_min(tr) < MIN_PF_DIFF then
              if LOG_TICKS then
                game.print("[AutoModuleUpgrade] [SKIP] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " — rate below threshold")
              end
              goto skip_apply
            end
          end
        end
        apply_building_plan(entity, entry.modules_plan, entry.removal_plan, entry.info)
        sq.batch_upgraded = sq.batch_upgraded + 1
        local do_camera = storage.global_camera_follow
        if do_camera == nil then
          do_camera = storage.surface_camera_follow[surface_name] == true
        end
        if do_camera then
          for _, player in pairs(game.connected_players) do
            if player.force == entity.force then
              player.centered_on = entity
              break
            end
          end
        end
        ::skip_apply::
      end
    end

    -- Reset counters when queue is exhausted
    if #sq.queue == 0 then
      sq.batch_upgraded = 0
      sq.batch_filled = 0
    end
  end

  -- Process pending building quality replacements
  for i = #pending_replacements, 1, -1 do
    local task = pending_replacements[i]
    if game.tick - task.tick_queued > DEFERRED_MAX_AGE then
      table.remove(pending_replacements, i)
      goto next_deferred
    end

    local surface = game.get_surface(task.surface_name)
    if not surface then
      table.remove(pending_replacements, i)
      goto next_deferred
    end

    local area = {
      {task.position.x - 0.5, task.position.y - 0.5},
      {task.position.x + 0.5, task.position.y + 0.5}
    }
    local entities = surface.find_entities_filtered{area = area, name = task.entity_name}
    for _, e in ipairs(entities) do
      if e.valid and e.quality and e.quality.name == task.target_quality then
        -- Verify this is the NEW entity, not the original still waiting for upgrade
        local is_original = false
        if task.original_unit_number then
          local same_ok, same_entity = pcall(function() return e.unit_number == task.original_unit_number end)
          if same_ok and same_entity then
            is_original = true
          end
        end
        if is_original then goto skip_entity end
        -- Found the newly upgraded higher-quality building
        local pf_ok = pcall(function() e.products_finished = task.saved_pf end)
        apply_building_plan(e, task.modules_plan, task.removal_plan, task.info)
        local do_camera = storage.global_camera_follow
        if do_camera == nil then
          do_camera = storage.surface_camera_follow[task.surface_name] == true
        end
        if do_camera then
          for _, player in pairs(game.connected_players) do
            if player.force == e.force then
              player.centered_on = e
              break
            end
          end
        end
        if DEBUG or storage.LOG_OVERRIDE then
          game.print("[AutoModuleUpgrade] [UPGRADED] " .. e.name .. " at " .. e.position.x .. "," .. e.position.y .. " quality=" .. task.target_quality .. " pf_rate=" .. format_pf_rate(e) .. (pf_ok and "" or " (PF write failed)"))
        end
        table.remove(pending_replacements, i)
        goto next_deferred
      end
      ::skip_entity::
    end

    ::next_deferred::
  end

  step_scan_scheduler()

  -- Re-sync GUI tracking after save/load (windows persist but local vars don't)
  for _, player in pairs(game.connected_players) do
    local window = player.gui.screen[AMU_WINDOW_NAME]
    if window and window.valid then
      if not amu_gui_players[player.index] then
        amu_gui_players[player.index] = {window = window, visible = window.visible}
      end
    end
  end

  -- Refresh scan status GUI for any players with the window open
  for _, player in pairs(game.connected_players) do
    local gui_data = amu_gui_players[player.index]
    if gui_data and gui_data.visible then
      update_scan_window(player)
    end
  end
end

-- Build lookups on configuration changed (prototypes are not available during on_init)
script.on_configuration_changed(function()
  game.print("[AutoModuleUpgrade] Mod loaded, rebuilding module lookups...")
  build_module_lookups()
  -- Ensure persistent storage tables exist
  storage.surface_buildings_upgraded = storage.surface_buildings_upgraded or {}
  storage.surface_modules_placed = storage.surface_modules_placed or {}
  storage.surface_last_upgraded = storage.surface_last_upgraded or {}
  storage.surface_camera_follow = storage.surface_camera_follow or {}
  if storage.global_camera_follow == nil then storage.global_camera_follow = nil end
  if storage.LOG_OVERRIDE == nil then storage.LOG_OVERRIDE = false end
  storage.amu_gui_locations = storage.amu_gui_locations or {}
  -- Destroy any stale windows so they get recreated with new layout
  for _, player in pairs(game.players) do
    if player.gui.screen[AMU_WINDOW_NAME] then
      player.gui.screen[AMU_WINDOW_NAME].destroy()
    end
  end
  amu_gui_players = {}
end)

script.on_init(function()
  game.print("[AutoModuleUpgrade] Mod initialized.")
  -- Initialize persistent storage tables
  storage.surface_buildings_upgraded = {}
  storage.surface_modules_placed = {}
  storage.surface_last_upgraded = {}
  storage.surface_camera_follow = {}
  storage.global_camera_follow = nil
  storage.LOG_OVERRIDE = false
  storage.amu_gui_locations = {}
end)

-- Manual test command: type /amu-test in console
commands.add_command("amu-test", "Manually trigger AutoModuleUpgrade queue refill for all planets", function()
  local added = enqueue_all_scans()
  game.print("[AutoModuleUpgrade] Manual test scheduled " .. added .. " incremental scan(s).")
end)

-- Manual hover command: type /amu-hover while looking at a building
commands.add_command("amu-hover", "Check module upgrades for currently selected entity", function(event)
  local player = game.players[event.player_index]
  local entity = player.selected
  if not entity or not entity.valid then
    player.print("[AutoModuleUpgrade] No entity selected. Look at a building and try again.")
    return
  end
  if not entity.prototype or not entity.prototype.module_inventory_size or entity.prototype.module_inventory_size <= 0 then
    player.print("[AutoModuleUpgrade] " .. entity.name .. " has no module slots.")
    return
  end
  if not next(module_tiers) then
    build_module_lookups()
  end
  local result, info = check_building(entity, {move_camera = false})
  if result == "upgrade" then
    player.print("[AutoModuleUpgrade] [HOVER] " .. info .. " in " .. entity.name)
  elseif result == "fill" then
    player.print("[AutoModuleUpgrade] [HOVER] " .. info .. " in " .. entity.name)
  elseif result == "none" then
    player.print("[AutoModuleUpgrade] [HOVER] " .. entity.name .. " — " .. info)
  else
    player.print("[AutoModuleUpgrade] [HOVER] " .. entity.name .. " — skipped (" .. tostring(info) .. ")")
  end
end)

-- Process one building every 6 ticks (10 per second at 60 UPS)
script.on_nth_tick(6, on_tick_handler)

-- Schedule incremental queue refills every SCAN_INTERVAL ticks
script.on_nth_tick(SCAN_INTERVAL, function()
  enqueue_all_scans()
end)

-- Auto-apply on crosshair select when HOVER_APPLY is enabled
if HOVER_APPLY then
  script.on_event(defines.events.on_selected_entity_changed, function(event)
    local player = game.players[event.player_index]
    local entity = player.selected
    if not entity or not entity.valid then return end
    if entity.force ~= player.force then return end
    if not entity.prototype or not entity.prototype.module_inventory_size or entity.prototype.module_inventory_size <= 0 then return end

    if not next(module_tiers) then
      build_module_lookups()
    end

    local result, info = check_building(entity, {move_camera = false})
    -- if result == "upgrade" then
    --   game.print("[AutoModuleUpgrade] [SELECT] " .. info .. " in " .. entity.name)
    -- elseif result == "none" then
    --   game.print("[AutoModuleUpgrade] [SELECT] " .. entity.name .. " — " .. info)
    -- elseif result == "skip" then
    --   game.print("[AutoModuleUpgrade] [SELECT] " .. entity.name .. " — skipped: " .. tostring(info))
    -- end
  end)
end

-- Debug: dump module lookup tables and prototype info
commands.add_command("amu-debug-lookups", "Debug module lookup tables", function()
  if not next(module_tiers) then
    build_module_lookups()
  end
  local names = {}
  for n, _ in pairs(module_tiers) do table.insert(names, n) end
  table.sort(names)
  game.print("[AutoModuleUpgrade] [DEBUG] Known modules (" .. #names .. "): " .. table.concat(names, ", "))

  local p = prototypes.item["productivity-module-3"]
  if p then
    game.print("[AutoModuleUpgrade] [DEBUG] productivity-module-3 type=" .. tostring(p.type))
    if p.module_effects then
      game.print("[AutoModuleUpgrade] [DEBUG]   module_effects.quality=" .. tostring(p.module_effects.quality))
    end
  else
    game.print("[AutoModuleUpgrade] [DEBUG] productivity-module-3 NOT FOUND in prototypes.item")
  end
end)

-- ============================================================
-- Scan Status GUI
-- ============================================================

-- Helper: format tick delta as mm:ss
local function format_time(ticks)
  if not ticks or ticks < 0 then return "0:00" end
  local total_seconds = math.floor(ticks / 60)
  local minutes = math.floor(total_seconds / 60)
  local seconds = total_seconds % 60
  return string.format("%d:%02d", minutes, seconds)
end

-- Helper: get valid planet sprite path
local function get_planet_sprite(surface_name)
  local path = "space-location/" .. surface_name
  if helpers.is_valid_sprite_path(path) then
    return path
  end
  return "utility/questionmark"
end

-- Create or recreate the scan status window for a player
local function create_scan_window(player)
  if not player or not player.valid then return end
  local screen = player.gui.screen
  if screen[AMU_WINDOW_NAME] then
    screen[AMU_WINDOW_NAME].destroy()
  end

  local window = screen.add{
    type = "frame",
    name = AMU_WINDOW_NAME,
    direction = "vertical"
  }
  window.style.maximal_width = 720

  -- Title bar with drag handle and close button
  local titlebar = window.add{
    type = "flow",
    name = AMU_WINDOW_NAME .. "-titlebar",
    direction = "horizontal"
  }
  titlebar.drag_target = window

  titlebar.add{
    type = "label",
    caption = "AutoModuleUpgrade Scans",
    style = "frame_title",
    ignored_by_interaction = true
  }

  local dragger = titlebar.add{
    type = "empty-widget",
    style = "draggable_space_header",
    ignored_by_interaction = true
  }
  dragger.style.horizontally_stretchable = true
  dragger.style.vertically_stretchable = true

  titlebar.add{
    type = "sprite-button",
    sprite = "utility/show_player_names_in_map_view",
    style = "frame_action_button",
    name = AMU_WINDOW_NAME .. "-eye",
    mouse_button_filter = {"left"}
  }

  titlebar.add{
    type = "sprite-button",
    sprite = "utility/search_icon",
    style = "frame_action_button",
    name = AMU_WINDOW_NAME .. "-log",
    mouse_button_filter = {"left"}
  }

  titlebar.add{
    type = "sprite-button",
    sprite = "utility/close",
    style = "frame_action_button",
    name = AMU_WINDOW_NAME .. "-close",
    mouse_button_filter = {"left"}
  }

  -- Content frame
  local content = window.add{
    type = "frame",
    name = AMU_WINDOW_NAME .. "-content",
    style = "inside_shallow_frame",
    direction = "vertical"
  }

  local scroll = content.add{
    type = "scroll-pane",
    name = AMU_WINDOW_NAME .. "-scroll",
    style = "naked_scroll_pane",
    horizontal_scroll_policy = "never"
  }
  scroll.style.padding = 2
  scroll.style.maximal_height = 300

  local table_el = scroll.add{
    type = "table",
    name = AMU_WINDOW_NAME .. "-table",
    column_count = 9,
    draw_horizontal_lines = true,
    draw_horizontal_line_after_headers = true,
    draw_vertical_lines = false
  }
  table_el.style.horizontal_spacing = 8
  table_el.style.vertical_spacing = 4
  table_el.style.column_alignments[1] = "center"
  table_el.style.column_alignments[2] = "right"
  table_el.style.column_alignments[3] = "right"
  table_el.style.column_alignments[4] = "right"
  table_el.style.column_alignments[5] = "right"
  table_el.style.column_alignments[6] = "right"
  table_el.style.column_alignments[7] = "center"
  table_el.style.column_alignments[8] = "center"
  table_el.style.column_alignments[9] = "left"

  -- Headers
  table_el.add{type = "sprite", sprite = "space-location/nauvis", tooltip = "Planet"}.style.size = {26, 26}
  table_el.add{type = "label", caption = "Queued", style = "bold_label"}
  table_el.add{type = "label", caption = "Cand", style = "bold_label"}
  table_el.add{type = "label", caption = "Upgraded", style = "bold_label"}
  table_el.add{type = "label", caption = "Mods", style = "bold_label"}
  local clock_header = table_el.add{type = "sprite", sprite = "utility/clock", tooltip = "Scan time / age"}
  clock_header.style.size = {26, 26}
  table_el.add{type = "label", caption = "Status", style = "bold_label"}
  table_el.add{type = "label", caption = "Jump", style = "bold_label"}
  table_el.add{type = "label", caption = "Cam", style = "bold_label"}

  -- Store reference
  amu_gui_players[player.index] = {window = window, visible = true}

  -- Restore location if known
  local pdata = storage.amu_gui_locations and storage.amu_gui_locations[player.index]
  if pdata then
    window.location = pdata
  else
    window.location = {x = 200, y = 100}
  end

  update_scan_window(player)
end

-- Update the scan status window for a player
function update_scan_window(player)
  if not player or not player.valid then return end
  local gui_data = amu_gui_players[player.index]
  if not gui_data or not gui_data.visible then return end

  local window = player.gui.screen[AMU_WINDOW_NAME]
  if not window then
    create_scan_window(player)
    window = player.gui.screen[AMU_WINDOW_NAME]
    if not window then return end
  end

  -- Update title bar button states
  local titlebar = window[AMU_WINDOW_NAME .. "-titlebar"]
  if titlebar then
    local eye_btn = titlebar[AMU_WINDOW_NAME .. "-eye"]
    if eye_btn and eye_btn.valid then
      if storage.global_camera_follow == true then
        eye_btn.sprite = "utility/show_player_names_in_map_view"
        eye_btn.tooltip = "Global camera follow ON (click to use per-surface)"
        eye_btn.toggled = true
      else
        eye_btn.sprite = "utility/cross_select"
        eye_btn.tooltip = "Global camera follow OFF — per-surface (click to force ON)"
        eye_btn.toggled = false
      end
    end
    local log_btn = titlebar[AMU_WINDOW_NAME .. "-log"]
    if log_btn and log_btn.valid then
      if storage.LOG_OVERRIDE then
        log_btn.sprite = "utility/search_icon"
        log_btn.tooltip = "Logging ON (click to disable)"
        log_btn.toggled = true
      else
        log_btn.sprite = "utility/warning"
        log_btn.tooltip = "Logging OFF (click to enable)"
        log_btn.toggled = false
      end
    end
  end

  local table_el = window[AMU_WINDOW_NAME .. "-content"][AMU_WINDOW_NAME .. "-scroll"][AMU_WINDOW_NAME .. "-table"]
  if not table_el then return end

  local columns = 9
  local header_cells = columns
  local child_count = #table_el.children
  local current_rows = 0
  if child_count >= header_cells then
    current_rows = math.floor((child_count - header_cells) / columns)
  end

  local target_rows = #PLANETS
  -- Add or remove rows to match planet count
  if current_rows < target_rows then
    for r = current_rows + 1, target_rows do
      local surface_name = PLANETS[r]
      -- Planet sprite
      local spr = table_el.add{type = "sprite", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-planet"}
      spr.style.size = {26, 26}
      spr.style.stretch_image_to_widget_size = true
      -- Queued
      local q = table_el.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-queued", caption = "0"}
      q.style.horizontal_align = "right"
      -- Candidates
      local c = table_el.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-cand", caption = "0"}
      c.style.horizontal_align = "right"
      -- Upgraded
      local u = table_el.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-upgraded", caption = "0"}
      u.style.horizontal_align = "right"
      -- Modules
      local m = table_el.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-mods", caption = "0"}
      m.style.horizontal_align = "right"
      -- Time / watch
      local t = table_el.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-time", caption = ""}
      t.style.horizontal_align = "right"
      t.style.minimal_width = 50
      -- Status
      local s = table_el.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-status", caption = ""}
      -- Jump button
      local jump = table_el.add{
        type = "sprite-button",
        name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-jump",
        sprite = "utility/search",
        tooltip = "Jump to latest upgrade",
        mouse_button_filter = {"left"}
      }
      jump.style.size = {26, 26}
      -- Camera toggle button
      local cam = table_el.add{
        type = "sprite-button",
        name = AMU_WINDOW_NAME .. "-cell-" .. r .. "-cam",
        sprite = "utility/check_mark",
        tooltip = "Toggle auto camera follow",
        mouse_button_filter = {"left"}
      }
      cam.style.size = {26, 26}
    end
  elseif current_rows > target_rows then
    local to_remove = (current_rows - target_rows) * columns
    for _ = 1, to_remove do
      local children = table_el.children
      local last = children[#children]
      if last and last.valid then last.destroy() end
    end
  end

  -- Populate rows
  for i, surface_name in ipairs(PLANETS) do
    local st = scan_status[surface_name] or {}
    local is_scanning = st.current_scan_start_tick ~= nil
    local elapsed = 0
    if is_scanning then
      elapsed = game.tick - st.current_scan_start_tick
    elseif st.last_scan_tick then
      elapsed = game.tick - st.last_scan_tick
    end

    -- Planet icon
    local planet_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-planet"]
    if planet_cell and planet_cell.valid then
      planet_cell.sprite = get_planet_sprite(surface_name)
      planet_cell.tooltip = surface_name
    end

    -- Queued
    local queued_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-queued"]
    if queued_cell and queued_cell.valid then
      local sq = processing_queues[surface_name]
      local queue_size = sq and #sq.queue or 0
      queued_cell.caption = tostring(queue_size)
      queued_cell.tooltip = "Queued: " .. queue_size
    end

    -- Candidates
    local cand_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-cand"]
    if cand_cell and cand_cell.valid then
      cand_cell.caption = tostring(st.candidates or 0)
      cand_cell.tooltip = "Candidates collected"
    end

    -- Upgraded (buildings)
    local upgraded_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-upgraded"]
    if upgraded_cell and upgraded_cell.valid then
      local count = storage.surface_buildings_upgraded[surface_name] or 0
      upgraded_cell.caption = tostring(count)
      upgraded_cell.tooltip = "Buildings upgraded: " .. count
    end

    -- Modules placed (grouped by category: quality / prod / speed; efficiency ignored)
    local mods_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-mods"]
    if mods_cell and mods_cell.valid then
      local mod_stats = storage.surface_modules_placed[surface_name]
      local total = 0
      local by_cat = {} -- category -> count
      if mod_stats then
        for mod_name, mod_count in pairs(mod_stats) do
          total = total + mod_count
          local cat = module_categories[mod_name]
          if cat and cat ~= "efficiency" then
            by_cat[cat] = (by_cat[cat] or 0) + mod_count
          end
        end
      end
      mods_cell.caption = tostring(total)
      if next(by_cat) then
        local tooltip_parts = {}
        for cat, count in pairs(by_cat) do
          table.insert(tooltip_parts, cat:sub(1,1):upper() .. cat:sub(2) .. ": " .. count)
        end
        table.sort(tooltip_parts)
        mods_cell.tooltip = table.concat(tooltip_parts, "\n")
      else
        mods_cell.tooltip = "No modules placed yet"
      end
    end

    -- Time / watch (green when scanning, white when idle)
    local time_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-time"]
    if time_cell and time_cell.valid then
      if is_scanning then
        time_cell.caption = format_time(elapsed)
        time_cell.style.font_color = {r = 0.3, g = 1.0, b = 0.3} -- green
        time_cell.tooltip = "Scanning for " .. format_time(elapsed)
      else
        time_cell.caption = st.last_scan_tick and format_time(elapsed) or "—"
        time_cell.style.font_color = {r = 1.0, g = 1.0, b = 1.0} -- white
        time_cell.tooltip = st.last_scan_tick and ("Last scan " .. format_time(elapsed) .. " ago") or "Not scanned yet"
      end
    end

    -- Status
    local status_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-status"]
    if status_cell and status_cell.valid then
      if is_scanning then
        status_cell.caption = st.phase or "scanning"
        status_cell.tooltip = "Currently scanning"
      else
        local sq = processing_queues[surface_name]
        local queue_size = sq and #sq.queue or 0
        if queue_size > 0 then
          status_cell.caption = "queueing"
          status_cell.tooltip = queue_size .. " buildings queued"
        else
          status_cell.caption = "idle"
          status_cell.tooltip = "Waiting for next scan"
        end
      end
    end

    -- Jump button: center camera on last upgraded building
    local jump_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-jump"]
    if jump_cell and jump_cell.valid then
      local last = storage.surface_last_upgraded[surface_name]
      if last and last.tick then
        jump_cell.enabled = true
        jump_cell.tooltip = "Jump to last upgraded building"
      else
        jump_cell.enabled = false
        jump_cell.tooltip = "No upgraded building yet"
      end
    end

    -- Camera toggle button: shows check_mark when enabled, close when disabled
    local cam_cell = table_el[AMU_WINDOW_NAME .. "-cell-" .. i .. "-cam"]
    if cam_cell and cam_cell.valid then
      local enabled = storage.surface_camera_follow[surface_name] == true
      cam_cell.sprite = enabled and "utility/check_mark" or "utility/close"
      cam_cell.tooltip = enabled and "Auto camera follow ON (click to disable)" or "Auto camera follow OFF (click to enable)"
    end
  end
end

-- Toggle scan window visibility
local function toggle_scan_window(player)
  if not player or not player.valid then return end
  local gui_data = amu_gui_players[player.index]
  local window = player.gui.screen[AMU_WINDOW_NAME]

  if window and window.valid then
    if not gui_data then
      -- Stale window from previous save: destroy and recreate with new layout
      window.destroy()
      create_scan_window(player)
      return
    end
    local new_visible = not window.visible
    window.visible = new_visible
    gui_data.visible = new_visible
    if new_visible then
      update_scan_window(player)
    end
  else
    create_scan_window(player)
  end
end

-- Event: GUI click
script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if not element or not element.valid then return end
  local name = element.name or ""
  local player = game.get_player(event.player_index)
  if not player or not player.valid then return end

  if name == AMU_WINDOW_NAME .. "-close" then
    local window = player.gui.screen[AMU_WINDOW_NAME]
    if window and window.valid then
      window.visible = false
      local gui_data = amu_gui_players[player.index]
      if gui_data then gui_data.visible = false end
    end
    return
  end

  -- Jump button: center camera on last upgraded building for this surface
  if name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-jump$") then
    local row = tonumber(name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-jump$"))
    local surface_name = PLANETS[row]
    local last = storage.surface_last_upgraded[surface_name]
    if last then
      player.zoom_to_world({x = last.x, y = last.y}, 1)
    end
    return
  end

  -- Camera toggle button: enable/disable auto-follow for this surface
  if name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-cam$") then
    local row = tonumber(name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-cam$"))
    local surface_name = PLANETS[row]
    local current = storage.surface_camera_follow[surface_name] == true
    storage.surface_camera_follow[surface_name] = not current
    update_scan_window(player)
    return
  end

  -- Eye button: toggle global camera follow override
  if name == AMU_WINDOW_NAME .. "-eye" then
    if storage.global_camera_follow == true then
      storage.global_camera_follow = nil -- back to per-surface
    else
      storage.global_camera_follow = true -- force ON everywhere
    end
    update_scan_window(player)
    return
  end

  -- Log button: toggle LOG_OVERRIDE
  if name == AMU_WINDOW_NAME .. "-log" then
    storage.LOG_OVERRIDE = not storage.LOG_OVERRIDE
    update_scan_window(player)
    return
  end
end)

-- Event: window moved
script.on_event(defines.events.on_gui_location_changed, function(event)
  local element = event.element
  if not element or not element.valid then return end
  if element.name == AMU_WINDOW_NAME then
    if not storage.amu_gui_locations then
      storage.amu_gui_locations = {}
    end
    storage.amu_gui_locations[event.player_index] = {x = element.location.x, y = element.location.y}
  end
end)

-- Command to toggle scan window
commands.add_command("amu-scans", "Toggle AutoModuleUpgrade scan status window", function(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then
    toggle_scan_window(player)
  end
end)

-- Shortcut bar button handler: toggle scan window
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "amu_toggle_scan_window" then
    local player = game.get_player(event.player_index)
    if player and player.valid then
      toggle_scan_window(player)
      local gui_data = amu_gui_players[player.index]
      if gui_data then
        player.set_shortcut_toggled("amu_toggle_scan_window", gui_data.visible)
      end
    end
  end
end)
