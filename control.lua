local DEBUG = true
local HOVER_APPLY = false -- If true, auto-apply module upgrades on crosshair select (on_selected_entity_changed)
local USE_RATE_PRIORITY = true -- If true, use tracker-based queuing; if false, direct queue from scan
local USE_ABSOLUTE_PF = false -- If true and USE_RATE_PRIORITY is true, sort by total products_finished; if false, sort by production rate diff
local MIN_READINGS = 3 -- Minimum pf snapshots before rate-based sorting kicks in (only for USE_RATE_PRIORITY)
local UPS = 60 -- Game updates per second
local SCAN_INTERVAL_SEC = 30 -- Seconds between scans
local SCAN_INTERVAL = SCAN_INTERVAL_SEC * UPS -- Ticks between scans
local SCAN_CHUNKS_PER_STEP = 4 -- Max chunks scanned per scheduler step
local SCAN_ENTITIES_PER_STEP = 25 -- Max candidate buildings evaluated per scheduler step
local MIN_PF_DIFF = 15 -- Minimum production rate in items per minute to be eligible for rate-priority queuing
local QUEUE_SIZE_PER_PLANET = 100 -- Max buildings queued per surface per scan
local MAX_TRACKED_PER_PLANET = 1000 -- Max buildings tracked per surface for rate-based priority
local MOVE_CAMERA_AFTER_UPGRADE = true -- Center camera on building after applying module upgrades
local PLANETS = {"nauvis", "vulcanus", "gleba", "fulgora", "aquilo"}

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

-- Check a single building for upgrades/fills
-- Returns: "upgrade", "fill", "none", or "skip" (plus optional info string)
local function check_building(entity, context)
  if not entity.valid then return "skip", "invalid" end
  if entity.type == "entity-ghost" or entity.type == "tile-ghost" or entity.to_be_deconstructed() then return "skip", "ghost/decon" end
  if not entity.prototype or not entity.prototype.module_inventory_size or entity.prototype.module_inventory_size <= 0 then return "skip", "no modules" end
  local logistic_network = entity.surface.find_logistic_network_by_position(entity.position, entity.force)
  if not logistic_network then return "none", "no logistic network" end

  local reservations = context and context.reservations or nil

  local module_inv = entity.get_module_inventory()
  if not module_inv then return "none", "no module inventory" end

  local module_count = #module_inv
  local filled_slots = {}
  local empty_slots = {}
  local category_counts = {}

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
      -- Empty machine: prefer productivity, then speed
      best = find_best_available("productivity", logistic_network, reservations, #empty_slots)
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
      if MOVE_CAMERA_AFTER_UPGRADE then
        for _, player in pairs(game.connected_players) do
          if player.force == entity.force then
            player.centered_on = entity
            break
          end
        end
      end
      if DEBUG then
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

-- Get the next higher quality level for a building (e.g. epic -> legendary)
local function get_next_building_quality(entity)
  if not entity.quality then return nil end
  local current_name = entity.quality.name
  local idx = quality_index[current_name]
  if not idx or idx >= #quality_order then return nil end
  return quality_order[idx + 1]
end

-- Attempt to defer a building for quality upgrade; returns true if deferred
-- Uses order_upgrade so the building stays functional until bots replace it
local function try_defer_quality_upgrade(entity, surface_name, modules_plan, removal_plan, info, reservations)
  local target_quality = get_next_building_quality(entity)
  if not target_quality or not modules_plan or not next(modules_plan) then return false end
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
      game.print("[AutoModuleUpgrade] [DEFER] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " -> " .. target_quality .. " (pf=" .. saved_pf .. ")")
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

local function is_module_candidate(entity)
  return entity.valid
    and entity.prototype
    and entity.prototype.module_inventory_size
    and entity.prototype.module_inventory_size > 0
    and entity.type ~= "entity-ghost"
    and entity.type ~= "tile-ghost"
    and not entity.to_be_deconstructed()
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
        local first_pf = job.all_entities[1] and get_products_finished(job.all_entities[1]) or "n/a"
        game.print("[AutoModuleUpgrade] [SCAN] Collected " .. #job.all_entities .. " candidates for " .. job.surface_name .. " top_pf=" .. first_pf)
      end
      return
    end

    if job.surface.is_chunk_generated({chunk.x, chunk.y}) then
      for _, force_name in ipairs(job.force_names) do
        for _, entity in pairs(job.surface.find_entities_filtered{area = chunk.area, force = force_name}) do
          if is_module_candidate(entity) then
            table.insert(job.all_entities, entity)
          end
        end
      end
    end
    chunks_scanned = chunks_scanned + 1
  end
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
      if pf < MIN_PRODUCTS then
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
    return
  end

  if job.phase == "prepare_tracked_queue" then
    if DEBUG then
      local first_pf = job.all_entities[1] and get_products_finished(job.all_entities[1]) or "n/a"
      game.print("[AutoModuleUpgrade] [DIAG] total=" .. #job.all_entities .. " top_pf=" .. first_pf .. " proxy=" .. job.skipped_proxy .. " low_pf=" .. job.skipped_low_pf .. " no_work=" .. job.skipped_no_work .. " tracked=" .. job.scanned)
    end

    for un, entry in pairs(building_tracker) do
      if not entry.entity or not entry.entity.valid then
        building_tracker[un] = nil
      end
    end

    job.tracked_list = {}
    for un, entry in pairs(building_tracker) do
      if entry.entity and entry.entity.valid and #entry.pf_history >= MIN_READINGS and get_rate_per_min(entry) >= MIN_PF_DIFF then
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
    local ok, pf = pcall(function() return entity.products_finished end)
    local pf_str = ""
    if ok and pf then
      local tracker_entry = entity.unit_number and building_tracker[entity.unit_number]
      if tracker_entry then
        local rate = get_rate_per_min(tracker_entry)
        if rate > 0 then
          pf_str = " [rate=" .. math.floor(rate + 0.5) .. "/min]"
        else
          pf_str = " [pf=" .. pf .. "]"
        end
      else
        pf_str = " [pf=" .. pf .. "]"
      end
    end
    game.print("[AutoModuleUpgrade] [APPLY] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. pf_str .. " — " .. (info or ""))
  end
end

-- Process one building from each surface queue every tick
local function on_tick_handler()
  for surface_name, sq in pairs(processing_queues) do
    if DEBUG and #sq.queue > 0 then
      game.print("[AutoModuleUpgrade] [TICK] " .. surface_name .. " queue=" .. #sq.queue)
    end
    if #sq.queue > 0 then
      local entry = table.remove(sq.queue, 1)
      local entity = entry.entity
      if entity.valid then
        apply_building_plan(entity, entry.modules_plan, entry.removal_plan, entry.info)
        sq.batch_upgraded = sq.batch_upgraded + 1
        if MOVE_CAMERA_AFTER_UPGRADE then
          for _, player in pairs(game.connected_players) do
            if player.force == entity.force then
              player.centered_on = entity
              break
            end
          end
        end
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
        if DEBUG then
          game.print("[AutoModuleUpgrade] [RESTORE] " .. e.name .. " at " .. e.position.x .. "," .. e.position.y .. " quality=" .. task.target_quality .. " pf=" .. task.saved_pf .. (pf_ok and "" or " (PF write failed)"))
        end
        table.remove(pending_replacements, i)
        goto next_deferred
      end
      ::skip_entity::
    end

    ::next_deferred::
  end

  step_scan_scheduler()
end

-- Build lookups on configuration changed (prototypes are not available during on_init)
script.on_configuration_changed(function()
  game.print("[AutoModuleUpgrade] Mod loaded, rebuilding module lookups...")
  build_module_lookups()
end)

script.on_init(function()
  game.print("[AutoModuleUpgrade] Mod initialized.")
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
