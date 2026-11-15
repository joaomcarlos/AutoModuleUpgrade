-- ============================================================
-- Event Handlers & Lifecycle
-- ============================================================

-- Build runtime prototype lookups whenever the mod configuration changes.
script.on_configuration_changed(function()
  game.print("[AutoModuleUpgrade] Mod loaded, rebuilding module lookups...")
  build_module_lookups()
  amu_refresh_candidate_event_filters()
  -- Ensure persistent storage tables exist
  storage.surface_buildings_upgraded = storage.surface_buildings_upgraded or {}
  storage.surface_modules_placed = storage.surface_modules_placed or {}
  storage.surface_building_upgrades = storage.surface_building_upgrades or {}
  storage.surface_module_upgrades = storage.surface_module_upgrades or {}
  storage.surface_equipment_upgrades = storage.surface_equipment_upgrades or {}
  storage.surface_last_upgraded = storage.surface_last_upgraded or {}
  storage.surface_changed_buildings = storage.surface_changed_buildings or {}
  storage.amu_change_highlight_objects = storage.amu_change_highlight_objects or {}
  storage.surface_camera_follow = storage.surface_camera_follow or {}
  storage.pending_replacements = storage.pending_replacements or {}
  storage.amu_surface_paused = storage.amu_surface_paused or {}
  storage.amu_excluded_entities = storage.amu_excluded_entities or {}
  storage.amu_candidate_registry = {}
  storage.amu_registry_ready = {}
  storage.amu_diagnostics = storage.amu_diagnostics or {}
  pending_replacements = storage.pending_replacements
  if storage.global_camera_follow == nil then storage.global_camera_follow = nil end
  if storage.LOG_OVERRIDE == nil then storage.LOG_OVERRIDE = false end
  storage.amu_gui_locations = storage.amu_gui_locations or {}
  storage.last_auto_scan_tick = storage.last_auto_scan_tick or 0
  -- Destroy any stale windows so they get recreated with new layout
  for _, player in pairs(game.players) do
    if player.gui.screen[AMU_WINDOW_NAME] then
      player.gui.screen[AMU_WINDOW_NAME].destroy()
    end
  end
  amu_gui_players = {}
  amu_enqueue_full_discovery_scans()
end)

script.on_init(function()
  game.print("[AutoModuleUpgrade] Mod initialized.")
  build_module_lookups()
  amu_refresh_candidate_event_filters()
  -- Initialize persistent storage tables
  storage.surface_buildings_upgraded = {}
  storage.surface_modules_placed = {}
  storage.surface_building_upgrades = {}
  storage.surface_module_upgrades = {}
  storage.surface_equipment_upgrades = {}
  storage.surface_last_upgraded = {}
  storage.surface_changed_buildings = {}
  storage.amu_change_highlight_objects = {}
  storage.surface_camera_follow = {}
  storage.global_camera_follow = nil
  storage.LOG_OVERRIDE = false
  storage.amu_gui_locations = {}
  storage.pending_replacements = {}
  storage.amu_surface_paused = {}
  storage.amu_excluded_entities = {}
  storage.amu_candidate_registry = {}
  storage.amu_registry_ready = {}
  storage.amu_diagnostics = {}
  storage.last_auto_scan_tick = 0
  pending_replacements = storage.pending_replacements
  amu_enqueue_full_discovery_scans()
end)

script.on_load(function()
  -- Rebuild only ordinary Lua globals; storage must not be mutated in on_load.
  build_module_lookups()
  amu_refresh_candidate_event_filters()
  pending_replacements = storage.pending_replacements or {}
end)

-- ============================================================
-- Commands
-- ============================================================

-- Manual test command: type /amu-test in console
commands.add_command("amu-test", "Manually trigger AutoModuleUpgrade queue refill for all enabled scan targets", function()
  local added = enqueue_all_scans()
  game.print("[AutoModuleUpgrade] Manual test scheduled " .. added .. " incremental scan(s).")
end)

-- Manual hover command: type /amu-hover while looking at a building
commands.add_command("amu-hover", "Check module upgrades for currently selected entity", function(event)
  local player = game.players[event.player_index]
  local entity = player.selected
  if not entity or not entity.valid then
    player.print({"amu-message.no-selected-entity"})
    return
  end
  local ok_inv, module_inv = pcall(function() return entity.get_module_inventory() end)
  local has_module_slots = ok_inv and module_inv and #module_inv > 0
  local can_quality_upgrade = amu_can_quality_upgrade_entity(entity) and get_next_building_quality(entity)
  local has_grid = entity_has_grid(entity)
  if not has_module_slots and not can_quality_upgrade and not has_grid then
    player.print({"amu-message.no-module-slots", entity.localised_name})
    return
  end
  if not next(module_tiers) then
    build_module_lookups()
  end
  local result, info = check_building(entity, {move_camera = false})
  if result == "upgrade" then
    player.print({"amu-message.hover-result", entity.localised_name, info})
  elseif result == "fill" then
    player.print({"amu-message.hover-result", entity.localised_name, info})
  elseif result == "none" then
    player.print({"amu-message.hover-result", entity.localised_name, info})
  else
    player.print({"amu-message.hover-skipped", entity.localised_name, tostring(info)})
  end
end)

commands.add_command("amu-preview", "Preview AutoModuleUpgrade objective for the selected machine", function(event)
  local player = game.get_player(event.player_index)
  local entity = player and player.selected
  if not entity or not entity.valid then
    if player then player.print({"amu-message.no-selected-entity"}) end
    return
  end
  if not next(module_tiers) then build_module_lookups() end
  player.print({"amu-message.preview", entity.localised_name, amu_format_recommendation(amu_get_machine_recommendation(entity))})
end)

commands.add_command("amu-tool", "Put the AutoModuleUpgrade area tool in the cursor", function(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then
    player.clear_cursor()
    player.cursor_stack.set_stack{name = AMU_SELECTION_TOOL_NAME, count = 1}
  end
end)

commands.add_command("amu-stats", "Show AutoModuleUpgrade registry and queue diagnostics", function(event)
  ensure_storage()
  local player = event.player_index and game.get_player(event.player_index) or nil
  local destination = player or game
  local registered = 0
  for surface_name in pairs(storage.amu_candidate_registry) do
    registered = registered + amu_count_registered_entities(surface_name)
  end
  local queued = 0
  for _, sq in pairs(processing_queues) do queued = queued + #sq.queue end
  destination.print({"amu-message.stats", registered, queued, #pending_replacements})
end)

local function selection_entities(event)
  if event.item ~= AMU_SELECTION_TOOL_NAME then return nil, nil end
  local player = game.get_player(event.player_index)
  if not player or not player.valid then return nil, nil end
  if not next(module_tiers) then build_module_lookups() end
  return player, event.entities or {}
end

script.on_event(defines.events.on_player_selected_area, function(event)
  local player, entities = selection_entities(event)
  if not player then return end
  local surfaces = {}
  local count = 0
  for _, entity in ipairs(entities) do
    if amu_register_candidate_entity(entity) then
      local key = amu_entity_key(entity)
      storage.amu_excluded_entities[key] = nil
      surfaces[entity.surface.name] = true
      count = count + 1
    end
  end
  for surface_name in pairs(surfaces) do amu_enqueue_surface_scan(surface_name, false) end
  player.print({"amu-message.selection-scheduled", count})
end)

script.on_event(defines.events.on_player_alt_selected_area, function(event)
  local player, entities = selection_entities(event)
  if not player then return end
  local count = 0
  for _, entity in ipairs(entities) do
    if amu_register_candidate_entity(entity) then
      storage.amu_excluded_entities[amu_entity_key(entity)] = true
      count = count + 1
    end
  end
  player.print({"amu-message.selection-excluded", count})
end)

script.on_event(defines.events.on_player_reverse_selected_area, function(event)
  local player, entities = selection_entities(event)
  if not player then return end
  local shown = 0
  for _, entity in ipairs(entities) do
    if amu_register_candidate_entity(entity) and shown < 10 then
      player.print({"amu-message.preview", entity.localised_name, amu_format_recommendation(amu_get_machine_recommendation(entity))})
      shown = shown + 1
    end
  end
  if #entities > shown then player.print({"amu-message.preview-truncated", shown, #entities}) end
end)

script.on_event(defines.events.on_player_alt_reverse_selected_area, function(event)
  local player, entities = selection_entities(event)
  if not player then return end
  local count = 0
  for _, entity in ipairs(entities) do
    local key = amu_entity_key(entity)
    if key and storage.amu_excluded_entities[key] then
      storage.amu_excluded_entities[key] = nil
      count = count + 1
    end
  end
  player.print({"amu-message.selection-included", count})
end)

local function register_event_entity(event)
  local entity = event.entity or event.created_entity or event.destination
  if entity and entity.valid then amu_register_candidate_entity(entity) end
end

local function unregister_event_entity(event)
  local entity = event.entity
  if entity then amu_unregister_candidate_entity(entity) end
end

local candidate_registration_events = {
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
  defines.events.on_entity_cloned,
  defines.events.on_space_platform_built_entity
}

local candidate_removal_events = {
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.on_entity_died,
  defines.events.script_raised_destroy,
  defines.events.on_space_platform_mined_entity
}

script.on_event(candidate_registration_events, register_event_entity)
script.on_event(candidate_removal_events, unregister_event_entity)

function amu_refresh_candidate_event_filters()
  local filters = {}
  for _, entity_name in ipairs(scan_candidate_entity_names or {}) do
    filters[#filters + 1] = {filter = "name", name = entity_name}
  end
  for _, event_id in ipairs(candidate_registration_events) do
    script.set_event_filter(event_id, filters)
  end
  for _, event_id in ipairs(candidate_removal_events) do
    script.set_event_filter(event_id, filters)
  end
end

script.on_event(defines.events.on_research_finished, function()
  enqueue_all_scans()
end)

script.on_event(defines.events.on_cargo_pod_delivered_cargo, function(event)
  local pod = event.cargo_pod
  if pod and pod.valid and pod.surface then
    amu_enqueue_surface_scan(pod.surface.name, false)
  end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function()
  enqueue_all_scans()
end)

script.on_event(defines.events.on_string_translated, function(event)
  amu_handle_dump_translation(event)
end)

script.on_event(defines.events.on_pre_surface_deleted, function(event)
  ensure_storage()
  local surface = game.surfaces[event.surface_index]
  local surface_name = surface and surface.name
  if not surface_name then return end
  storage.amu_candidate_registry[surface_name] = nil
  storage.amu_registry_ready[surface_name] = nil
  storage.amu_surface_paused[surface_name] = nil
  storage.amu_diagnostics[surface_name] = nil
  processing_queues[surface_name] = nil
  for i = #pending_replacements, 1, -1 do
    if pending_replacements[i].surface_name == surface_name then
      table.remove(pending_replacements, i)
    end
  end
end)

script.on_event(defines.events.on_surface_created, function(event)
  local surface = game.surfaces[event.surface_index]
  if surface then amu_enqueue_surface_scan(surface.name, true) end
end)

script.on_event(defines.events.on_surface_renamed, function(event)
  ensure_storage()
  storage.amu_candidate_registry[event.new_name] = storage.amu_candidate_registry[event.old_name]
  storage.amu_candidate_registry[event.old_name] = nil
  storage.amu_registry_ready[event.new_name] = storage.amu_registry_ready[event.old_name]
  storage.amu_registry_ready[event.old_name] = nil
  storage.amu_surface_paused[event.new_name] = storage.amu_surface_paused[event.old_name]
  storage.amu_surface_paused[event.old_name] = nil
  storage.amu_diagnostics[event.new_name] = storage.amu_diagnostics[event.old_name]
  storage.amu_diagnostics[event.old_name] = nil
  processing_queues[event.old_name] = nil
  for _, task in ipairs(pending_replacements) do
    if task.surface_name == event.old_name then task.surface_name = event.new_name end
  end
  amu_enqueue_surface_scan(event.new_name, false)
end)

script.on_event(defines.events.on_cancelled_upgrade, function(event)
  local entity = event.entity
  if not entity or not entity.valid or not entity.unit_number then return end
  for i = #pending_replacements, 1, -1 do
    if pending_replacements[i].original_unit_number == entity.unit_number then
      table.remove(pending_replacements, i)
    end
  end
end)

-- Process queued work and scan slices at a fixed low-frequency cadence.
script.on_nth_tick(SCAN_SCHEDULER_INTERVAL, on_tick_handler)

-- Poll once per second so runtime scan interval changes apply without reloading.
script.on_nth_tick(UPS, function(event)
  ensure_storage()
  local last_tick = storage.last_auto_scan_tick or 0
  if event.tick - last_tick >= amu_scan_interval_ticks() then
    storage.last_auto_scan_tick = event.tick
    enqueue_all_scans()
  end
  if amu_process_player_equipment then amu_process_player_equipment() end
end)

script.on_event(defines.events.on_space_platform_changed_state, function(event)
  enqueue_platform_scan_for_platform(event.platform)
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

-- Event: GUI click
script.on_event(defines.events.on_gui_click, function(event)
  ensure_storage()
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

  if name == AMU_DUMP_WINDOW_NAME .. "-refresh" then
    amu_refresh_performance_dump_window(player)
    return
  end

  if name == AMU_WINDOW_NAME .. "-dump" then
    amu_open_performance_dump_window(player)
    return
  end

  if name == AMU_DUMP_WINDOW_NAME .. "-close" then
    local window = player.gui.screen[AMU_DUMP_WINDOW_NAME]
    if window and window.valid then window.destroy() end
    return
  end

  -- Jump button: inspect changed buildings for this surface
  if name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-jump$") then
    local row = tonumber(name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-jump$"))
    local surface_name = get_scan_window_surface_rows()[row]
    if not surface_name then return end
    if event.button == defines.mouse_button_type.right then
      local queued = amu_enqueue_surface_scan(surface_name, false)
      player.print(queued and {"amu-message.rescan-scheduled", surface_name} or {"amu-message.rescan-not-scheduled", surface_name})
      update_scan_window(player)
      return
    end
    amu_draw_change_highlights(player, surface_name)
    local last = storage.surface_last_upgraded[surface_name]
    if last then
      player.set_controller{
        type = defines.controllers.remote,
        position = {x = last.x, y = last.y},
        surface = surface_name
      }
      player.zoom = 1
    end
    return
  end

  -- Camera toggle button: enable/disable auto-follow for this surface
  if name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-cam$") then
    local row = tonumber(name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-cam$"))
    local surface_name = get_scan_window_surface_rows()[row]
    if not surface_name then return end
    if event.button == defines.mouse_button_type.right then
      storage.amu_surface_paused[surface_name] = not storage.amu_surface_paused[surface_name]
      if not storage.amu_surface_paused[surface_name] then amu_enqueue_surface_scan(surface_name, false) end
      update_scan_window(player)
      return
    end
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
