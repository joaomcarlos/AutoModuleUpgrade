-- ============================================================
-- Event Handlers & Lifecycle
-- ============================================================

-- Build lookups on configuration changed (prototypes are not available during on_init)
script.on_configuration_changed(function()
  game.print("[AutoModuleUpgrade] Mod loaded, rebuilding module lookups...")
  build_module_lookups()
  -- Ensure persistent storage tables exist
  storage.surface_buildings_upgraded = storage.surface_buildings_upgraded or {}
  storage.surface_modules_placed = storage.surface_modules_placed or {}
  storage.surface_building_upgrades = storage.surface_building_upgrades or {}
  storage.surface_module_upgrades = storage.surface_module_upgrades or {}
  storage.surface_last_upgraded = storage.surface_last_upgraded or {}
  storage.surface_changed_buildings = storage.surface_changed_buildings or {}
  storage.amu_change_highlight_objects = storage.amu_change_highlight_objects or {}
  storage.surface_camera_follow = storage.surface_camera_follow or {}
  storage.pending_replacements = storage.pending_replacements or {}
  pending_replacements = storage.pending_replacements
  if storage.global_camera_follow == nil then storage.global_camera_follow = nil end
  if storage.LOG_OVERRIDE == nil then storage.LOG_OVERRIDE = false end
  storage.amu_gui_locations = storage.amu_gui_locations or {}
  storage.amu_hidden_station_rows_expanded = storage.amu_hidden_station_rows_expanded or {}
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
  storage.surface_building_upgrades = {}
  storage.surface_module_upgrades = {}
  storage.surface_last_upgraded = {}
  storage.surface_changed_buildings = {}
  storage.amu_change_highlight_objects = {}
  storage.surface_camera_follow = {}
  storage.global_camera_follow = nil
  storage.LOG_OVERRIDE = false
  storage.amu_gui_locations = {}
  storage.amu_hidden_station_rows_expanded = {}
  storage.pending_replacements = {}
  pending_replacements = storage.pending_replacements
end)

script.on_load(function()
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
    player.print("[AutoModuleUpgrade] No entity selected. Look at a building and try again.")
    return
  end
  local has_module_slots = entity.prototype and entity.prototype.module_inventory_size and entity.prototype.module_inventory_size > 0
  local can_quality_upgrade = QUALITY_UPGRADEABLE_TYPES[entity.type] and get_next_building_quality(entity)
  if not has_module_slots and not can_quality_upgrade then
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

  if name == AMU_WINDOW_NAME .. "-hidden-toggle" then
    storage.amu_hidden_station_rows_expanded[event.player_index] = not (storage.amu_hidden_station_rows_expanded[event.player_index] == true)
    update_scan_window(player)
    return
  end

  -- Jump button: inspect changed buildings for this surface
  if name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-jump$") then
    local row = tonumber(name:match(AMU_WINDOW_NAME .. "%-cell%-(%d+)%-jump$"))
    local surface_name = get_scan_window_surface_rows(event.player_index)[row]
    if not surface_name then return end
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
    local surface_name = get_scan_window_surface_rows(event.player_index)[row]
    if not surface_name then return end
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
