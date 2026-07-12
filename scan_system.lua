-- ============================================================
-- Rate Tracking & Queue Variables
-- ============================================================

-- Non-persistent by design: profiler timings are non-deterministic diagnostics
-- and a dump session can be restarted after loading a save.
amu_runtime_profile = nil

function amu_start_runtime_profile()
  local total = helpers.create_profiler(true)
  local window = helpers.create_profiler(true)
  amu_runtime_profile = {
    started_tick = game.tick,
    total = total,
    samples = 0,
    window = window,
    window_started_tick = game.tick,
    window_samples = 0,
    previous_window = nil,
    previous_window_samples = 0,
    previous_window_ticks = 0
  }
end

function amu_get_runtime_profile()
  return amu_runtime_profile
end

local function begin_runtime_profile_sample()
  -- Profiling is opt-in from the performance dump. Creating and combining
  -- profilers on every scheduler call would otherwise add permanent overhead.
  if not amu_runtime_profile then return nil end
  return helpers.create_profiler(false)
end

local function finish_runtime_profile_sample(sample)
  local profile = amu_runtime_profile
  if not sample or not profile then return end
  sample.stop()
  profile.total.add(sample)
  profile.window.add(sample)
  profile.samples = profile.samples + 1
  profile.window_samples = profile.window_samples + 1

  if game.tick - profile.window_started_tick >= 3600 then
    profile.previous_window = profile.window
    profile.previous_window_samples = profile.window_samples
    profile.previous_window_ticks = game.tick - profile.window_started_tick
    profile.window = helpers.create_profiler(true)
    profile.window_started_tick = game.tick
    profile.window_samples = 0
  end
end

-- Normalize raw diff to items per minute based on actual interval between readings
local function get_rate_per_min(entry)
  local n = #entry.pf_history
  if n < 2 then return 0 end
  local ticks_diff = entry.tick_history[n] - entry.tick_history[n - 1]
  if ticks_diff <= 0 then return 0 end
  return entry.last_diff * 3600 / ticks_diff
end

local function rate_entry_has_higher_priority(a, b)
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
  end

  local a_pf = a.pf_history[#a.pf_history] or 0
  local b_pf = b.pf_history[#b.pf_history] or 0
  return a_pf > b_pf
end

local function rate_heap_push(heap, entry)
  local index = #heap + 1
  heap[index] = entry
  while index > 1 do
    local parent = math.floor(index / 2)
    if not rate_entry_has_higher_priority(heap[index], heap[parent]) then break end
    heap[index], heap[parent] = heap[parent], heap[index]
    index = parent
  end
end

local function rate_heap_pop(heap)
  local count = #heap
  if count == 0 then return nil end

  local first = heap[1]
  local last = heap[count]
  heap[count] = nil
  count = count - 1
  if count == 0 then return first end

  heap[1] = last
  local index = 1
  while true do
    local left = index * 2
    if left > count then break end
    local right = left + 1
    local highest = left
    if right <= count and rate_entry_has_higher_priority(heap[right], heap[left]) then
      highest = right
    end
    if not rate_entry_has_higher_priority(heap[highest], heap[index]) then break end
    heap[index], heap[highest] = heap[highest], heap[index]
    index = highest
  end
  return first
end

function get_products_finished(entity)
  local ok, val = pcall(function() return entity.products_finished end)
  return ok and val or 0, ok
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
local pending_replacement_cursor = 1

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

local function make_platform_hub_pool(platform)
  if not platform or platform.valid == false then return nil end
  local hub = platform.hub
  if not hub or not hub.valid then return nil end
  return {
    amu_is_platform_supply_pool = true,
    amu_supply_planet_name = get_platform_location_planet_name(platform),
    get_item_count = function(item)
      if not hub.valid then return 0 end
      local ok, count = pcall(function() return hub.get_item_count(item) end)
      return ok and count or 0
    end
  }
end

function amu_get_surface_platform_supply_network(surface, force)
  if not amu_scan_space_platforms_enabled() then return nil end
  local platform = get_surface_platform(surface)
  if not platform then return nil end
  return make_platform_hub_pool(platform)
end

local function platform_supply_available(surface, force, expected_planet_name)
  local platform = get_surface_platform(surface)
  if not platform then return false end
  return amu_get_surface_platform_supply_network(surface, force) ~= nil
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

local function should_include_planet_surface(surface)
  if not surface or not surface.valid or get_surface_platform(surface) then return false end
  return get_planet(surface.name) ~= nil
end

local function should_include_platform_surface(surface)
  local platform = get_surface_platform(surface)
  if not platform then return false end
  local scheduled = 0
  local ok_scheduled, value = pcall(function() return platform.scheduled_for_deletion end)
  if ok_scheduled and value then scheduled = value end
  if scheduled ~= 0 then return false end
  return true
end

local function add_platform_scan_surfaces(surface_names, seen)
  if not amu_scan_space_platforms_enabled() then return end

  for _, surface in pairs(game.surfaces) do
    if not seen[surface.name] and should_include_platform_surface(surface) then
      seen[surface.name] = true
      table.insert(surface_names, surface.name)
    end
  end
end

local function surface_planet_sort_key(surface_name)
  local planet = get_planet(surface_name)
  if not planet or not planet.valid or not planet.prototype then return nil end
  return planet.prototype.order or surface_name
end

local function sort_scan_surface_names(surface_names)
  table.sort(surface_names, function(a, b)
    local a_surface = game.surfaces[a]
    local b_surface = game.surfaces[b]
    local a_platform = a_surface and get_surface_platform(a_surface) ~= nil or false
    local b_platform = b_surface and get_surface_platform(b_surface) ~= nil or false

    if a_platform ~= b_platform then
      return not a_platform
    end

    if not a_platform then
      local a_order = surface_planet_sort_key(a) or a
      local b_order = surface_planet_sort_key(b) or b
      if a_order ~= b_order then
        return a_order < b_order
      end
      return a < b
    end

    return a < b
  end)
end

function get_scan_surface_names()
  local surface_names = {}
  local seen = {}

  if amu_scan_planets_enabled() then
    for _, surface in pairs(game.surfaces) do
      if should_include_planet_surface(surface) then
        seen[surface.name] = true
        table.insert(surface_names, surface.name)
      end
    end
  end

  add_platform_scan_surfaces(surface_names, seen)
  sort_scan_surface_names(surface_names)
  return surface_names
end

local function should_skip_rate_priority(entity, products_finished_supported)
  if NO_PF_ENTITY_TYPES[entity.type] or amu_can_quality_upgrade_entity(entity) then return true end
  if products_finished_supported ~= nil then return not products_finished_supported end
  local _, supported = get_products_finished(entity)
  return not supported
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

  local pf, pf_supported = get_products_finished(entity)
  local skip_pf_check = should_skip_rate_priority(entity, pf_supported)
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
      entry = {
        entity = entity,
        pf_history = {pf},
        tick_history = {job.current_tick},
        last_diff = 0,
        modules_plan = modules_plan,
        removal_plan = removal_plan,
        info = info,
        module_upgrades = module_upgrade_details
      }
      building_tracker[un] = entry
    end
    rate_heap_push(job.tracked_heap, entry)
    if get_rate_per_min(entry) > 0 then job.rate_ready = job.rate_ready + 1 end
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
  local ok_inv, module_inv = pcall(function() return entity.get_module_inventory() end)
  if ok_inv and module_inv and #module_inv > 0 then return true end
  -- Also include buildings that can receive a quality upgrade (e.g. agricultural tower)
  if amu_can_quality_upgrade_entity(entity) and get_next_building_quality(entity) then
    return true
  end
  return false
end

local function new_candidate_registry()
  return {entries = {}, index_by_key = {}, count = 0}
end

function amu_get_candidate_registry(surface_name, create)
  local registry = storage.amu_candidate_registry[surface_name]
  if registry and registry.entries and registry.index_by_key then return registry end

  if registry then
    -- One-time compatibility conversion. Configuration changes normally clear
    -- the old registry before this path is reached.
    local converted = new_candidate_registry()
    for key, entity in pairs(registry) do
      if entity and entity.valid then
        local index = #converted.entries + 1
        converted.entries[index] = {key = key, entity = entity}
        converted.index_by_key[key] = index
        converted.count = converted.count + 1
      end
    end
    storage.amu_candidate_registry[surface_name] = converted
    return converted
  end

  if not create then return nil end
  registry = new_candidate_registry()
  storage.amu_candidate_registry[surface_name] = registry
  return registry
end

function amu_count_registered_entities(surface_name)
  local registry = amu_get_candidate_registry(surface_name, false)
  return registry and registry.count or 0
end

function amu_register_candidate_entity(entity, known_candidate)
  if not entity or not entity.valid or (not known_candidate and not is_upgrade_candidate(entity)) then return false end
  if not known_candidate then ensure_storage() end
  local surface_name = entity.surface.name
  local registry = amu_get_candidate_registry(surface_name, true)
  local key = amu_entity_key(entity)
  if not key then return false end
  local index = registry.index_by_key[key]
  if index then
    registry.entries[index].entity = entity
    return true
  end
  index = #registry.entries + 1
  registry.entries[index] = {key = key, entity = entity}
  registry.index_by_key[key] = index
  registry.count = registry.count + 1
  return true
end

function amu_unregister_candidate_entity(entity)
  -- Destruction events normally expose a valid entity. If another mod raises a
  -- late destroy event, leave the stale reference for the next registry sweep.
  if not entity or not entity.valid then return end
  ensure_storage()
  local surface_name = entity.surface.name
  local key = entity.unit_number and tostring(entity.unit_number) or amu_entity_key(entity)
  local registry = surface_name and amu_get_candidate_registry(surface_name, false)
  local index = registry and key and registry.index_by_key[key]
  if index then
    registry.entries[index].entity = false
    registry.index_by_key[key] = nil
    registry.count = math.max(0, registry.count - 1)
  end
  if entity.unit_number then building_tracker[entity.unit_number] = nil end
  if key then storage.amu_excluded_entities[key] = nil end
end

local function enqueue_scan(surface_name)
  ensure_storage()
  if storage.amu_surface_paused[surface_name] then return false end
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
  ensure_storage()
  if storage.amu_surface_paused[surface_name] then return false end
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
  local surface = get_platform_surface(platform)
  if not surface then return false end
  return enqueue_platform_scan(surface.name)
end

function enqueue_all_scans()
  ensure_storage()
  local added = 0
  for _, surface_name in ipairs(get_scan_surface_names()) do
    local surface = game.surfaces[surface_name]
    local platform = surface and get_surface_platform(surface)
    local queued = platform and enqueue_platform_scan(surface_name) or enqueue_scan(surface_name)
    if queued then
      added = added + 1
    end
  end
  return added
end

function amu_enqueue_full_discovery_scans()
  ensure_storage()
  local added = 0
  for _, surface_name in ipairs(get_scan_surface_names()) do
    if amu_enqueue_surface_scan(surface_name, true) then
      added = added + 1
    end
  end
  return added
end

function amu_enqueue_surface_scan(surface_name, force_full_scan)
  ensure_storage()
  local surface = game.surfaces[surface_name]
  if not surface or storage.amu_surface_paused[surface_name] then return false end
  if force_full_scan then
    storage.amu_registry_ready[surface_name] = nil
    -- Keep known candidates usable while the deliberately incremental full
    -- discovery pass validates and extends the registry.
    amu_get_candidate_registry(surface_name, true)
  end
  if get_surface_platform(surface) then return enqueue_platform_scan(surface_name) end
  return enqueue_scan(surface_name)
end

local function finish_scan_job(job)
  if DEBUG then
    if job.mode == "rate" then
      local mode = job.rate_ready > 0 and "[RATE]" or "[TOTAL]"
      game.print("[AutoModuleUpgrade] [QUEUE] Tracked=" .. job.scanned .. " (rate-ready=" .. job.rate_ready .. "), queued=" .. job.queued .. " " .. mode)
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
    scanned = job.scanned,
    skipped_proxy = job.skipped_proxy or 0,
    skipped_low_pf = job.skipped_low_pf or 0,
    skipped_no_work = job.skipped_no_work or 0,
    skipped_excluded = job.skipped_excluded or 0,
    registry_only = job.registry_only == true
  }
  storage.amu_diagnostics[job.surface_name] = {
    tick = game.tick,
    candidates = job.candidates_seen or 0,
    queued = job.queued or 0,
    skipped_proxy = job.skipped_proxy or 0,
    skipped_low_pf = job.skipped_low_pf or 0,
    skipped_no_work = job.skipped_no_work or 0,
    skipped_excluded = job.skipped_excluded or 0,
    registry_only = job.registry_only == true
  }
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
      reserve_items(reservations, task.upgrade_item_name or task.entity_name, task.target_quality, 1)
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
    if not force_name then return nil end

    local supply_network = make_platform_hub_pool(platform)
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

  local registry_only = storage.amu_registry_ready[surface_name] == true
  local registry = registry_only and amu_get_candidate_registry(surface_name, false) or nil
  local force_name_set = {}
  for _, force_name in ipairs(context.force_names) do force_name_set[force_name] = true end
  local force_filter = #context.force_names == 1 and context.force_names[1] or context.force_names

  local job = {
    surface_name = surface_name,
    surface = context.surface,
    chunk_iterator = registry_only and nil or context.surface.get_chunks(),
    force_names = context.force_names,
    force_filter = force_filter,
    force_name_set = force_name_set,
    logistic_network = context.logistic_network,
    is_space_platform = context.is_space_platform,
    supply_planet_name = context.supply_planet_name,
    phase = "collect",
    mode = USE_ABSOLUTE_PF and "absolute" or (USE_RATE_PRIORITY and "rate" or "direct"),
    all_entities = {},
    pending_entities = nil,
    pending_index = 1,
    registry = registry,
    registry_index = 1,
    registry_limit = registry and #registry.entries or 0,
    seen_candidate_keys = {},
    candidates_seen = 0,
    index = 1,
    queued = 0,
    reservations = reservations,
    current_tick = game.tick,
    scanned = 0,
    tracked_heap = {},
    rate_ready = 0,
    skipped_proxy = 0,
    skipped_low_pf = 0,
    skipped_no_work = 0,
    skipped_excluded = 0,
    sq = sq,
    registry_only = registry_only
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
      if active_scan_job then return end
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
      if active_platform_scan_job then return end
    end
  end
end

local function collect_candidate(job, entity)
  if not entity or not entity.valid or not is_upgrade_candidate(entity) then return end
  if not entity.force or not job.force_name_set[entity.force.name] then return end

  local key = amu_entity_key(entity)
  if key and job.seen_candidate_keys[key] then return end
  if key then job.seen_candidate_keys[key] = true end

  amu_register_candidate_entity(entity, true)
  job.candidates_seen = job.candidates_seen + 1
  if amu_entity_is_excluded(entity) then
    job.skipped_excluded = job.skipped_excluded + 1
  elseif job.mode == "rate" then
    update_rate_candidate(job, entity)
  else
    table.insert(job.all_entities, entity)
  end
end

local function complete_scan_collection(job)
  if job.mode == "rate" then
    if #job.tracked_heap == 0 then
      finish_scan_job(job)
      return
    end
    job.phase = "queue_tracked"
  else
    if #job.all_entities == 0 then
      finish_scan_job(job)
      return
    end
    job.phase = "evaluate"
    job.index = 1
  end

  if DEBUG then
    local first_entry = job.tracked_heap[1]
    local first_entity = first_entry and first_entry.entity or job.all_entities[1]
    local top_rate = first_entity and format_pf_rate(first_entity) or "n/a"
    game.print("[AutoModuleUpgrade] [SCAN] Collected " .. job.candidates_seen .. " candidates for " .. job.surface_name .. " top_pf_rate=" .. top_rate)
  end
end

local function step_registry_collect(job, max_entities)
  local registry = job.registry
  if not registry then
    finish_scan_job(job)
    return
  end

  local processed = 0
  while processed < max_entities and job.registry_index <= job.registry_limit do
    local index = job.registry_index
    local record = registry.entries[index]
    job.registry_index = index + 1
    processed = processed + 1

    local entity = record and record.entity
    if entity and entity.valid then
      collect_candidate(job, entity)
    elseif record and record.entity then
      record.entity = false
      if registry.index_by_key[record.key] == index then
        registry.index_by_key[record.key] = nil
        registry.count = math.max(0, registry.count - 1)
      end
      local unit_number = tonumber(record.key)
      if unit_number then building_tracker[unit_number] = nil end
    end
  end

  if job.registry_index > job.registry_limit then
    complete_scan_collection(job)
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

  if job.registry_only then
    step_registry_collect(job, max_entities)
    return
  end

  while entities_processed < max_entities do
    if job.pending_entities and job.pending_index <= #job.pending_entities then
      local entity = job.pending_entities[job.pending_index]
      job.pending_index = job.pending_index + 1
      entities_processed = entities_processed + 1

      collect_candidate(job, entity)
    else
      job.pending_entities = nil
      job.pending_index = 1

      if chunks_scanned >= max_chunks then
        break
      end

      local ok, chunk = pcall(job.chunk_iterator)
      if not ok or not chunk then
        storage.amu_registry_ready[job.surface_name] = true
        complete_scan_collection(job)
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
  if storage.amu_surface_paused[job.surface_name] or amu_entity_is_excluded(entity) then return end
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    job.skipped_proxy = job.skipped_proxy + 1
    return
  end
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
  else
    job.skipped_no_work = job.skipped_no_work + 1
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

    if entity.valid then
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
  if job.phase == "queue_tracked" then
    local processed = 0
    local max_entities = amu_scan_entities_per_step()
    local max_queue = amu_queue_size_per_surface()
    while processed < max_entities and #job.tracked_heap > 0 do
      if job.queued >= max_queue then
        finish_scan_job(job)
        return
      end

      local entry = rate_heap_pop(job.tracked_heap)
      processed = processed + 1

      if entry.entity and entry.entity.valid then
        queue_entity_from_scan(job, entry.entity)
      end
    end

    if #job.tracked_heap == 0 then
      finish_scan_job(job)
    end
  end
  local st = scan_status[job.surface_name]
  if st then st.queued = job.queued; st.phase = job.phase end
end

local function step_scan_job(job)
  if not job then return end

  if storage.amu_surface_paused[job.surface_name] then
    finish_scan_job(job)
    return
  end

  if not job.surface or not job.surface.valid or not game.surfaces[job.surface_name] then
    finish_scan_job(job)
    return
  end

  if job.is_space_platform and (not amu_scan_space_platforms_enabled() or not get_surface_platform(job.surface)) then
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
  if not entity.valid then return false, "invalid" end
  local has_modules = modules_plan and next(modules_plan)
  local has_removals = removal_plan and next(removal_plan)
  if not has_modules and not has_removals then return false, "empty-plan" end

  local valid_plan, invalid_reason = amu_validate_module_plan(entity, modules_plan, removal_plan)
  if not valid_plan then return false, invalid_reason end

  local proxy = entity.surface.create_entity{
    name = "item-request-proxy",
    target = entity,
    position = entity.position,
    force = entity.force,
    modules = modules_plan,
    removal_plan = removal_plan
  }
  if not proxy then return false, "proxy-creation-failed" end

  -- Track stats
  local surface_name = entity.surface.name
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

  amu_record_changed_building(entity)
  if DEBUG then
    game.print("[AutoModuleUpgrade] [APPLY] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " pf_rate=" .. format_pf_rate(entity) .. " — " .. (info or ""))
  end
  return true, nil
end

local function process_pending_replacement(index)
  local task = pending_replacements[index]
  if not task then return false end
  if task.next_check_tick and game.tick < task.next_check_tick then return false end
  task.next_check_tick = game.tick + DEFERRED_REPLACEMENT_CHECK_INTERVAL

  if game.tick - task.tick_queued > DEFERRED_MAX_AGE then
    table.remove(pending_replacements, index)
    return true
  end

  local surface = game.get_surface(task.surface_name)
  if not surface then
    table.remove(pending_replacements, index)
    return true
  end

  local area = {
    {task.position.x - 0.5, task.position.y - 0.5},
    {task.position.x + 0.5, task.position.y + 0.5}
  }
  local entities = surface.find_entities_filtered{area = area, name = task.entity_name}
  for _, e in ipairs(entities) do
    if e.valid and e.quality and e.quality.name == task.target_quality then
      -- Verify this is the new entity, not the original waiting for upgrade.
      if task.original_unit_number then
        local same_ok, same_entity = pcall(function() return e.unit_number == task.original_unit_number end)
        if same_ok and same_entity then goto skip_entity end
      end

      local pf_ok = true
      if task.saved_pf_supported ~= false then
        pf_ok = pcall(function() e.products_finished = task.saved_pf end)
      end
      local needs_followup_supply = (task.modules_plan and next(task.modules_plan)) or (task.removal_plan and next(task.removal_plan))
      if task.platform_supply_required and needs_followup_supply and not platform_supply_available(e.surface, e.force, task.supply_planet_name) then
        goto skip_entity
      end

      if needs_followup_supply then
        local applied_followup, followup_reason = apply_building_plan(e, task.modules_plan, task.removal_plan, task.info)
        -- An existing proxy is transient bot work, so retain the deferred task.
        -- Any other rejection means the saved plan became stale after replacement;
        -- finish the building upgrade and let a fresh scan calculate a valid plan.
        if not applied_followup and followup_reason == "existing-proxy" then goto skip_entity end
        if not applied_followup then
          amu_record_changed_building(e)
          amu_enqueue_surface_scan(task.surface_name, false)
        end
      else
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

      storage.surface_buildings_upgraded[task.surface_name] = (storage.surface_buildings_upgraded[task.surface_name] or 0) + 1
      if not storage.surface_building_upgrades[task.surface_name] then storage.surface_building_upgrades[task.surface_name] = {} end
      local b_key = task.entity_name .. "|" .. task.original_quality .. "|" .. task.target_quality
      storage.surface_building_upgrades[task.surface_name][b_key] = (storage.surface_building_upgrades[task.surface_name][b_key] or 0) + 1
      if DEBUG or storage.LOG_OVERRIDE then
        game.print("[AutoModuleUpgrade] [UPGRADED] " .. e.name .. " at " .. e.position.x .. "," .. e.position.y .. " quality=" .. task.target_quality .. " pf_rate=" .. format_pf_rate(e) .. (pf_ok and "" or " (PF write failed)"))
      end
      table.remove(pending_replacements, index)
      return true
    end
    ::skip_entity::
  end
  return false
end

local function step_pending_replacements()
  local count = #pending_replacements
  if count == 0 then
    pending_replacement_cursor = 1
    return
  end

  local scheduler_steps_per_check = math.max(1, math.ceil(DEFERRED_REPLACEMENT_CHECK_INTERVAL / SCAN_SCHEDULER_INTERVAL))
  local budget = math.max(1, math.ceil(count / scheduler_steps_per_check))
  local processed = 0
  while processed < budget and #pending_replacements > 0 do
    if pending_replacement_cursor > #pending_replacements then pending_replacement_cursor = 1 end
    local removed = process_pending_replacement(pending_replacement_cursor)
    if not removed then pending_replacement_cursor = pending_replacement_cursor + 1 end
    processed = processed + 1
  end
end

-- ============================================================
-- Tick Processing (main loop)
-- ============================================================

-- Process one building from each surface queue every tick
function on_tick_handler()
  local runtime_profile_sample = begin_runtime_profile_sample()
  for surface_name, sq in pairs(processing_queues) do
    if LOG_TICKS and #sq.queue > 0 then
      game.print("[AutoModuleUpgrade] [TICK] " .. surface_name .. " queue=" .. #sq.queue)
    end
    if #sq.queue > 0 and not storage.amu_surface_paused[surface_name] then
      local entry = table.remove(sq.queue, 1)
      local entity = entry.entity
      if entity.valid and not amu_entity_is_excluded(entity) then
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
        local applied = apply_building_plan(entity, entry.modules_plan, entry.removal_plan, entry.info)
        if not applied then goto skip_apply end
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

  step_pending_replacements()

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
  finish_runtime_profile_sample(runtime_profile_sample)
end
