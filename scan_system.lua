-- ============================================================
-- Rate Tracking & Queue Variables
-- ============================================================

-- Normalize raw diff to items per minute based on actual interval between readings
local function get_rate_per_min(entry)
  local n = #entry.pf_history
  if n < 2 then return 0 end
  local ticks_diff = entry.tick_history[n] - entry.tick_history[n - 1]
  if ticks_diff <= 0 then return 0 end
  return entry.last_diff * 3600 / ticks_diff
end

function get_products_finished(entity)
  local ok, val = pcall(function() return entity.products_finished end)
  return ok and val or 0
end

-- Format a building's production info for logging:
--   rate if tracker has enough data, else raw products_finished
function format_pf_rate(entity)
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

-- ============================================================
-- Scan Scheduler
-- ============================================================

-- Queue-based processing: per-surface queues, process 1 per tick per surface
processing_queues = {} -- surface_name -> {queue = {}, batch_upgraded = 0, batch_filled = 0}

-- Building tracker: unit_number -> {entity, pf_history, tick_history, last_diff, modules_plan, removal_plan, info}
-- Tracks buildings with actionable work; after multiple pf reads, sorts by diff for priority queuing
building_tracker = {}

-- Pending building quality replacements: buildings marked for deconstruction + ghost placed
-- {surface_name, position={x,y}, entity_name, target_quality, saved_pf, modules_plan, removal_plan, info, tick_queued}
pending_replacements = {}
local DEFERRED_MAX_AGE = 3600 * 60 -- 1 hour timeout in ticks

scan_queue = {}
local queued_scan_surfaces = {}
scan_cycle_surfaces = {}
active_scan_job = nil
local platform_scan_queue = {}
local queued_platform_scan_surfaces = {}
local active_platform_scan_job = nil

-- Per-surface scan status for GUI: surface_name -> {last_scan_tick, current_scan_start_tick, phase, candidates, queued, scanned}
scan_status = {}

-- Player scan window state: player_index -> {window, visible}
amu_gui_players = {}

local SCAN_PLANETS_SETTING = "amu-scan-planets"
local SCAN_SPACE_PLATFORMS_SETTING = "amu-scan-space-platforms"
local SCAN_INTERVAL_SETTING = "amu-scan-interval-seconds"
local SCAN_CHUNKS_SETTING = "amu-scan-chunks-per-step"
local SCAN_ENTITIES_SETTING = "amu-scan-entities-per-step"
local QUEUE_SIZE_SETTING = "amu-queue-size-per-surface"

local function setting_enabled(name, default_value)
  if not settings or not settings.global or not settings.global[name] then
    return default_value
  end
  return settings.global[name].value == true
end

local function setting_int(name, default_value)
  if not settings or not settings.global or not settings.global[name] then
    return default_value
  end
  local value = settings.global[name].value
  if type(value) ~= "number" then
    return default_value
  end
  return math.floor(value)
end

function amu_scan_planets_enabled()
  return setting_enabled(SCAN_PLANETS_SETTING, true)
end

function amu_scan_space_platforms_enabled()
  return setting_enabled(SCAN_SPACE_PLATFORMS_SETTING, true)
end

function amu_scan_interval_ticks()
  return math.max(UPS, setting_int(SCAN_INTERVAL_SETTING, SCAN_INTERVAL_SEC) * UPS)
end

local function amu_scan_chunks_per_step()
  return math.max(1, setting_int(SCAN_CHUNKS_SETTING, SCAN_CHUNKS_PER_STEP))
end

local function amu_scan_entities_per_step()
  return math.max(1, setting_int(SCAN_ENTITIES_SETTING, SCAN_ENTITIES_PER_STEP))
end

local function amu_queue_size_per_surface()
  return math.max(1, setting_int(QUEUE_SIZE_SETTING, QUEUE_SIZE_PER_PLANET))
end

local function get_force_name(force)
  if type(force) == "string" then return force end
  if not force then return nil end
  local ok, name = pcall(function() return force.name end)
  return ok and name or nil
end

local function get_planet(name)
  local ok, planets = pcall(function() return game.planets end)
  if not ok or not planets then return nil end
  local planet = planets[name]
  if planet and planet.valid ~= false then
    return planet
  end
  return nil
end

local function get_surface_platform(surface)
  if not surface or not surface.valid then return nil end
  local ok, platform = pcall(function() return surface.platform end)
  if ok and platform and platform.valid ~= false then
    return platform
  end
  return nil
end

local function get_platform_location_planet_name(platform)
  if not platform or platform.valid == false then return nil end
  local ok, location = pcall(function() return platform.space_location end)
  if not ok or not location then return nil end
  local planet = get_planet(location.name)
  if planet then
    return location.name
  end
  return nil
end

local function get_platform_surface(platform)
  if not platform or platform.valid == false then return nil end
  local ok, surface = pcall(function() return platform.surface end)
  if ok and surface and surface.valid then
    return surface
  end
  return nil
end

local function get_platforms_orbiting_planet(planet, force_name)
  if not planet or not force_name then return {} end
  local ok, platforms = pcall(function() return planet.get_space_platforms(force_name) end)
  if ok and platforms then
    return platforms
  end
  return {}
end

local function make_network_pool(networks, planet_name)
  if not networks or #networks == 0 then return nil end
  return {
    amu_is_platform_supply_pool = true,
    amu_supply_planet_name = planet_name,
    get_item_count = function(item)
      local total = 0
      for _, network in ipairs(networks) do
        local ok, count = pcall(function()
          if network.valid then
            return network.get_item_count(item)
          end
          return 0
        end)
        if ok and count then
          total = total + count
        end
      end
      return total
    end
  }
end

local function get_planet_rocket_supply_network(planet_name, force)
  local force_name = get_force_name(force)
  if not planet_name or not force_name then return nil end

  local surface = game.surfaces[planet_name]
  if not surface then
    local planet = get_planet(planet_name)
    if planet then
      local ok, planet_surface = pcall(function() return planet.surface end)
      if ok then surface = planet_surface end
    end
  end
  if not surface or not surface.valid then return nil end

  local ok, silos = pcall(function()
    return surface.find_entities_filtered{type = "rocket-silo", force = force_name}
  end)
  if not ok or not silos then return nil end

  local networks = {}
  local seen = {}
  for _, silo in ipairs(silos) do
    if silo.valid and not silo.to_be_deconstructed() then
      local network = surface.find_logistic_network_by_position(silo.position, force_name)
      if network and network.valid then
        local id = network.network_id
        if not seen[id] then
          seen[id] = true
          table.insert(networks, network)
        end
      end
    end
  end

  return make_network_pool(networks, planet_name)
end

function amu_get_surface_platform_supply_network(surface, force)
  if not amu_scan_space_platforms_enabled() then return nil end
  local platform = get_surface_platform(surface)
  if not platform then return nil end

  local force_name = get_force_name(force)
  if not force_name then
    force_name = get_force_name(platform.force)
  end
  if not force_name then return nil end

  local planet_name = get_platform_location_planet_name(platform)
  if not planet_name then return nil end

  return get_planet_rocket_supply_network(planet_name, force_name)
end

local function platform_supply_available(surface, force, expected_planet_name)
  local platform = get_surface_platform(surface)
  if not platform then return true end
  local planet_name = get_platform_location_planet_name(platform)
  if not planet_name or (expected_planet_name and planet_name ~= expected_planet_name) then
    return false
  end
  return amu_get_surface_platform_supply_network(surface, force) ~= nil
end

local function platform_still_at_planet(surface, expected_planet_name)
  local platform = get_surface_platform(surface)
  if not platform then return false end
  local planet_name = get_platform_location_planet_name(platform)
  return planet_name ~= nil and planet_name == expected_planet_name
end

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

local function add_platform_scan_surfaces(surface_names, seen)
  if not amu_scan_space_platforms_enabled() then return end

  for _, force_name in ipairs(get_player_force_names()) do
    for _, planet_name in ipairs(PLANETS) do
      local planet = get_planet(planet_name)
      for _, platform in ipairs(get_platforms_orbiting_planet(planet, force_name)) do
        local surface = get_platform_surface(platform)
        if surface and not seen[surface.name] then
          local scheduled = 0
          local ok_scheduled, value = pcall(function() return platform.scheduled_for_deletion end)
          if ok_scheduled and value then scheduled = value end
          if scheduled == 0 then
            seen[surface.name] = true
            table.insert(surface_names, surface.name)
          end
        end
      end
    end
  end
end

function get_scan_surface_names()
  local surface_names = {}
  local seen = {}

  if amu_scan_planets_enabled() then
    for _, surface_name in ipairs(PLANETS) do
      seen[surface_name] = true
      table.insert(surface_names, surface_name)
    end
  end

  add_platform_scan_surfaces(surface_names, seen)
  return surface_names
end

local function should_skip_rate_priority(entity)
  return NO_PF_ENTITIES[entity.name] or QUALITY_UPGRADEABLE_TYPES[entity.type] == true
end

local RATE_MIN_PRODUCTS = 50

local function update_rate_candidate(job, entity)
  if not entity.valid then return end
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    job.skipped_proxy = job.skipped_proxy + 1
    return
  end

  local un = entity.unit_number
  if not un then return end

  local pf = get_products_finished(entity)
  local skip_pf_check = should_skip_rate_priority(entity)
  if not skip_pf_check and pf < RATE_MIN_PRODUCTS then
    job.skipped_low_pf = job.skipped_low_pf + 1
    return
  end

  local result, info, modules_plan, removal_plan, module_upgrade_details = check_building(entity, {dry_run = true, logistic_network = job.logistic_network})
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
      entry.module_upgrades = module_upgrade_details
    else
      building_tracker[un] = {
        entity = entity,
        pf_history = {pf},
        tick_history = {job.current_tick},
        last_diff = 0,
        modules_plan = modules_plan,
        removal_plan = removal_plan,
        info = info,
        module_upgrades = module_upgrade_details
      }
    end
    job.scanned = job.scanned + 1
  else
    job.skipped_no_work = job.skipped_no_work + 1
    building_tracker[un] = nil
  end
end

local function is_upgrade_candidate(entity)
  if not entity.valid then return false end
  if entity.type == "entity-ghost" or entity.type == "tile-ghost" or entity.to_be_deconstructed() or entity.to_be_upgraded() then return false end
  local entity_name = entity.name
  if scan_module_entity_name_set[entity_name] then
    return true
  end
  if scan_quality_entity_name_set[entity_name] and get_next_building_quality(entity) then
    return true
  end
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
  if get_surface_platform(game.surfaces[surface_name]) then
    return false
  end
  scan_cycle_surfaces[surface_name] = true
  queued_scan_surfaces[surface_name] = true
  table.insert(scan_queue, surface_name)
  return true
end

local function enqueue_platform_scan(surface_name)
  if not amu_scan_space_platforms_enabled() then
    return false
  end
  if active_platform_scan_job and active_platform_scan_job.surface_name == surface_name then
    return false
  end
  if queued_platform_scan_surfaces[surface_name] then
    return false
  end
  local surface = game.surfaces[surface_name]
  if not surface or not get_surface_platform(surface) then
    return false
  end
  queued_platform_scan_surfaces[surface_name] = true
  table.insert(platform_scan_queue, surface_name)
  return true
end

function enqueue_platform_scan_for_platform(platform)
  if not amu_scan_space_platforms_enabled() then return false end
  if not get_platform_location_planet_name(platform) then return false end
  local surface = get_platform_surface(platform)
  if not surface then return false end
  return enqueue_platform_scan(surface.name)
end

function enqueue_all_scans()
  ensure_storage()
  local added = 0
  if amu_scan_planets_enabled() then
    local start_index = storage.last_scanned_planet_index or 0
    for i = 1, #PLANETS do
      local idx = ((start_index + i - 1) % #PLANETS) + 1
      local surface_name = PLANETS[idx]
      if enqueue_scan(surface_name) then
        added = added + 1
      end
    end
  end

  local platform_surfaces = {}
  add_platform_scan_surfaces(platform_surfaces, {})
  for _, surface_name in ipairs(platform_surfaces) do
    if enqueue_platform_scan(surface_name) then
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
    candidates = job.candidates_seen or (job.all_entities and #job.all_entities or 0),
    queued = job.queued,
    scanned = job.scanned
  }
  -- Save which planet was just scanned so we resume from the next one after load
  for i, name in ipairs(PLANETS) do
    if name == job.surface_name then
      storage.last_scanned_planet_index = i
      break
    end
  end
  if job.is_space_platform then
    active_platform_scan_job = nil
  else
    active_scan_job = nil
    if #scan_queue == 0 then
      scan_cycle_surfaces = {}
    end
  end
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

local function get_scan_context(surface_name)
  local surface = game.surfaces[surface_name]
  if not surface or not surface.valid then return nil end

  local platform = get_surface_platform(surface)
  if platform then
    if not amu_scan_space_platforms_enabled() then return nil end
    local force_name = get_force_name(platform.force)
    local planet_name = get_platform_location_planet_name(platform)
    if not force_name or not planet_name then return nil end

    local supply_network = get_planet_rocket_supply_network(planet_name, force_name)
    if not supply_network then return nil end

    return {
      surface = surface,
      force_names = {force_name},
      logistic_network = supply_network,
      is_space_platform = true,
      supply_planet_name = planet_name
    }
  end

  if not amu_scan_planets_enabled() then return nil end
  return {
    surface = surface,
    force_names = get_player_force_names(),
    logistic_network = nil,
    is_space_platform = false
  }
end

local function create_scan_job(surface_name, context)
  local sq = get_or_create_surface_queue(surface_name)
  sq.queue = {}
  sq.batch_upgraded = 0
  sq.batch_filled = 0

  local reservations = {}
  seed_pending_replacement_reservations(surface_name, reservations)

  local job = {
    surface_name = surface_name,
    surface = context.surface,
    chunk_iterator = context.surface.get_chunks(),
    force_names = context.force_names,
    force_filter = #context.force_names == 1 and context.force_names[1] or context.force_names,
    logistic_network = context.logistic_network,
    is_space_platform = context.is_space_platform,
    supply_planet_name = context.supply_planet_name,
    phase = "collect",
    mode = USE_ABSOLUTE_PF and "absolute" or (USE_RATE_PRIORITY and "rate" or "direct"),
    all_entities = {},
    pending_entities = nil,
    pending_index = 1,
    candidates_seen = 0,
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

  return job
end

local function start_next_scan_job()
  if not next(module_tiers) then
    build_module_lookups()
  end

  while #scan_queue > 0 do
    local surface_name = table.remove(scan_queue, 1)
    queued_scan_surfaces[surface_name] = nil

    local context = get_scan_context(surface_name)
    if context and not context.is_space_platform then
      active_scan_job = create_scan_job(surface_name, context)
      return
    end
  end
  if #scan_queue == 0 then
    scan_cycle_surfaces = {}
  end
end

local function start_next_platform_scan_job()
  if not next(module_tiers) then
    build_module_lookups()
  end

  while #platform_scan_queue > 0 do
    local surface_name = table.remove(platform_scan_queue, 1)
    queued_platform_scan_surfaces[surface_name] = nil

    local context = get_scan_context(surface_name)
    if context and context.is_space_platform then
      active_platform_scan_job = create_scan_job(surface_name, context)
      return
    end
  end
end

local function step_scan_collect(job)
  if not scan_candidate_entity_names or #scan_candidate_entity_names == 0 then
    finish_scan_job(job)
    return
  end

  local chunks_scanned = 0
  local entities_processed = 0
  local max_chunks = amu_scan_chunks_per_step()
  local max_entities = amu_scan_entities_per_step()

  while entities_processed < max_entities do
    if job.pending_entities and job.pending_index <= #job.pending_entities then
      local entity = job.pending_entities[job.pending_index]
      job.pending_index = job.pending_index + 1
      entities_processed = entities_processed + 1

      if is_upgrade_candidate(entity) then
        job.candidates_seen = job.candidates_seen + 1
        if job.mode == "rate" then
          update_rate_candidate(job, entity)
        else
          table.insert(job.all_entities, entity)
        end
      end
    else
      job.pending_entities = nil
      job.pending_index = 1

      if chunks_scanned >= max_chunks then
        break
      end

      local ok, chunk = pcall(job.chunk_iterator)
      if not ok or not chunk then
        if job.mode == "rate" then
          if job.candidates_seen == 0 then
            finish_scan_job(job)
            return
          end
          job.phase = "prepare_tracked_queue"
        else
          if #job.all_entities == 0 then
            finish_scan_job(job)
            return
          end
          job.phase = "evaluate"
          job.index = 1
        end
        if DEBUG then
          local first_ent = job.all_entities[1]
          local top_rate = first_ent and format_pf_rate(first_ent) or "n/a"
          game.print("[AutoModuleUpgrade] [SCAN] Collected " .. job.candidates_seen .. " candidates for " .. job.surface_name .. " top_pf_rate=" .. top_rate)
        end
        return
      end

      job.pending_entities = job.surface.find_entities_filtered{
        area = chunk.area,
        force = job.force_filter,
        name = scan_candidate_entity_names,
        to_be_deconstructed = false,
        to_be_upgraded = false
      }
      chunks_scanned = chunks_scanned + 1
    end
  end

  local st = scan_status[job.surface_name]
  if st then st.candidates = job.candidates_seen; st.scanned = job.scanned end
end

local function queue_entity_from_scan(job, entity)
  local result, info, modules_plan, removal_plan, module_upgrade_details = check_building(entity, {
    dry_run = true,
    reservations = job.reservations,
    logistic_network = job.logistic_network
  })
  if result == "upgrade" or result == "fill" then
    if try_defer_quality_upgrade(entity, job.surface_name, modules_plan, removal_plan, info, job.reservations, true, job.logistic_network, job.supply_planet_name) then
      job.queued = job.queued + 1
      return
    end
    table.insert(job.sq.queue, {
      entity = entity,
      modules_plan = modules_plan,
      removal_plan = removal_plan,
      info = info,
      module_upgrades = module_upgrade_details,
      platform_supply_required = job.is_space_platform,
      supply_planet_name = job.supply_planet_name
    })
    job.queued = job.queued + 1
  end
end

local function step_absolute_or_direct_scan(job)
  local processed = 0
  local max_entities = amu_scan_entities_per_step()
  local max_queue = amu_queue_size_per_surface()

  while processed < max_entities and job.index <= #job.all_entities do
    if job.queued >= max_queue then
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
  if job.phase == "evaluate" then
    local processed = 0
    local max_entities = amu_scan_entities_per_step()
    while processed < max_entities and job.index <= #job.all_entities do
      local entity = job.all_entities[job.index]
      job.index = job.index + 1
      processed = processed + 1

      update_rate_candidate(job, entity)
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
    if st then st.phase = job.phase; st.candidates = job.candidates_seen end

    for un, entry in pairs(building_tracker) do
      if not entry.entity or not entry.entity.valid then
        building_tracker[un] = nil
      end
    end

    job.tracked_list = {}
    for un, entry in pairs(building_tracker) do
      if entry.entity and entry.entity.valid and entry.entity.surface.name == job.surface_name then
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

    if DEBUG then
      local first_entry = job.tracked_list[1]
      local top_rate = first_entry and first_entry.entity and format_pf_rate(first_entry.entity) or "n/a"
      game.print("[AutoModuleUpgrade] [DIAG] total=" .. job.candidates_seen .. " top_pf_rate=" .. top_rate .. " proxy=" .. job.skipped_proxy .. " low_pf=" .. job.skipped_low_pf .. " no_work=" .. job.skipped_no_work .. " tracked=" .. job.scanned)
    end

    job.phase = "queue_tracked"
    job.index = 1
    return
  end

  if job.phase == "queue_tracked" then
    local processed = 0
    local max_entities = amu_scan_entities_per_step()
    local max_queue = amu_queue_size_per_surface()
    while processed < max_entities and job.index <= #job.tracked_list do
      if job.queued >= max_queue then
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

local function step_scan_job(job)
  if not job then return end

  if not job.surface or not job.surface.valid or not game.surfaces[job.surface_name] then
    finish_scan_job(job)
    return
  end

  if job.is_space_platform and (not amu_scan_space_platforms_enabled() or not platform_still_at_planet(job.surface, job.supply_planet_name)) then
    finish_scan_job(job)
    return
  end

  if not job.is_space_platform and not amu_scan_planets_enabled() then
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

function step_platform_scan_scheduler()
  if not active_platform_scan_job then
    start_next_platform_scan_job()
  end
  step_scan_job(active_platform_scan_job)
end

local function has_pending_planet_scan_work()
  return active_scan_job ~= nil or #scan_queue > 0
end

local function has_pending_platform_scan_work()
  return active_platform_scan_job ~= nil or #platform_scan_queue > 0
end

local function step_planet_scan_scheduler()
  if not active_scan_job then
    start_next_scan_job()
  end
  step_scan_job(active_scan_job)
end

local function step_scan_scheduler()
  local planet_pending = has_pending_planet_scan_work()
  local platform_pending = has_pending_platform_scan_work()

  if platform_pending and not active_platform_scan_job then
    step_platform_scan_scheduler()
    return
  end

  if planet_pending and not active_scan_job and not platform_pending then
    step_planet_scan_scheduler()
    return
  end

  if planet_pending and platform_pending then
    if math.floor(game.tick / 6) % 2 == 0 then
      step_planet_scan_scheduler()
    else
      step_platform_scan_scheduler()
    end
    return
  end

  if planet_pending then
    step_planet_scan_scheduler()
  elseif platform_pending then
    step_platform_scan_scheduler()
  end
end

local function refill_queue(surface_name)
  enqueue_scan(surface_name)
end

-- Apply a pre-computed plan directly (no re-evaluation)
local function apply_building_plan(entity, modules_plan, removal_plan, info)
  ensure_storage()
  if not entity.valid then return end
  if entity.to_be_upgraded() then return end
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
    for _, plan in ipairs(modules_plan) do
      local mod_name = plan.id and plan.id.name
      if mod_name then
        storage.surface_modules_placed[surface_name][mod_name] = (storage.surface_modules_placed[surface_name][mod_name] or 0) + 1
      end
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
  amu_record_changed_building(entity)
  if DEBUG then
    game.print("[AutoModuleUpgrade] [APPLY] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " pf_rate=" .. format_pf_rate(entity) .. " — " .. (info or ""))
  end
  return true
end

-- ============================================================
-- Tick Processing (main loop)
-- ============================================================

-- Process one building from each surface queue every tick
function on_tick_handler()
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
          local skip_rate = should_skip_rate_priority(entity)
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
        if entry.platform_supply_required and not platform_supply_available(entity.surface, entity.force, entry.supply_planet_name) then
          goto skip_apply
        end
        apply_building_plan(entity, entry.modules_plan, entry.removal_plan, entry.info)
        sq.batch_upgraded = sq.batch_upgraded + 1
        if entry.module_upgrades then
          if not storage.surface_module_upgrades[surface_name] then storage.surface_module_upgrades[surface_name] = {} end
          for _, upg in ipairs(entry.module_upgrades) do
            local m_key = upg.old_name .. "|" .. upg.old_quality .. "|" .. upg.new_name .. "|" .. upg.new_quality
            storage.surface_module_upgrades[surface_name][m_key] = (storage.surface_module_upgrades[surface_name][m_key] or 0) + 1
          end
        end
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
    if task.next_check_tick and game.tick < task.next_check_tick then
      goto next_deferred
    end
    task.next_check_tick = game.tick + DEFERRED_REPLACEMENT_CHECK_INTERVAL

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
        local needs_followup_supply = (task.modules_plan and next(task.modules_plan)) or (task.removal_plan and next(task.removal_plan))
        if task.platform_supply_required and needs_followup_supply and not platform_supply_available(e.surface, e.force, task.supply_planet_name) then
          goto skip_entity
        end
        local applied_followup = apply_building_plan(e, task.modules_plan, task.removal_plan, task.info)
        if not applied_followup then
          amu_record_changed_building(e)
        end
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
        -- Track building quality upgrade breakdown
        if not storage.surface_building_upgrades[task.surface_name] then storage.surface_building_upgrades[task.surface_name] = {} end
        local b_key = task.entity_name .. "|" .. task.original_quality .. "|" .. task.target_quality
        storage.surface_building_upgrades[task.surface_name][b_key] = (storage.surface_building_upgrades[task.surface_name][b_key] or 0) + 1
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

  if game.tick % (GUI_UPDATE_INTERVAL or 60) == 0 then
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
end
