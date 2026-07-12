-- ============================================================
-- Scan Status GUI
-- ============================================================

local amu_dump_translation_requests = {}

-- Helper: format tick delta as mm:ss
local function format_time(ticks)
  if not ticks or ticks < 0 then return "0:00" end
  local total_seconds = math.floor(ticks / 60)
  local minutes = math.floor(total_seconds / 60)
  local seconds = total_seconds % 60
  return string.format("%d:%02d", minutes, seconds)
end

local function is_platform_surface(surface_name)
  local surface = game.surfaces[surface_name]
  if not surface or not surface.valid then return false end
  local ok, platform = pcall(function() return surface.platform end)
  return ok and platform ~= nil
end

-- Helper: get valid surface sprite path
local function get_surface_sprite(surface_name)
  if is_platform_surface(surface_name) then
    if helpers.is_valid_sprite_path("entity/space-platform-hub") then
      return "entity/space-platform-hub"
    end
    if helpers.is_valid_sprite_path("item/space-platform-foundation") then
      return "item/space-platform-foundation"
    end
  end
  local path = "amu_planet_" .. surface_name
  if helpers.is_valid_sprite_path(path) then
    return path
  end
  return "amu_planet_nauvis"
end

local function get_surface_tooltip(surface_name)
  local surface = game.surfaces[surface_name]
  if not surface or not surface.valid then
    return surface_name
  end

  local ok, platform = pcall(function() return surface.platform end)
  if ok and platform and platform.valid then
    return platform.name
  end

  return surface_name
end

local function count_valid_registered_entities(surface_name)
  return amu_count_registered_entities(surface_name)
end

local function total_registered_entities()
  ensure_storage()
  local total = 0
  for surface_name, _ in pairs(storage.amu_candidate_registry or {}) do
    total = total + count_valid_registered_entities(surface_name)
  end
  return total
end

local function total_queued_plans()
  local total = 0
  for _, sq in pairs(processing_queues or {}) do
    total = total + #(sq.queue or {})
  end
  return total
end

local function total_tracker_entities()
  local total = 0
  for _, entry in pairs(building_tracker or {}) do
    if entry and entry.entity and entry.entity.valid then total = total + 1 end
  end
  return total
end

local function count_pending_scan_surfaces()
  return #(scan_queue or {})
end

local function count_pending_platform_scan_surfaces()
  return #(platform_scan_queue or {})
end

local function performance_dump_scan_complete()
  return count_pending_scan_surfaces() == 0
    and count_pending_platform_scan_surfaces() == 0
    and active_scan_job == nil
    and active_platform_scan_job == nil
end

local function safe_surface_setting(surface_name, map)
  return map and map[surface_name] == true and "true" or "false"
end

local function dump_setting(name, fallback)
  if settings and settings.global and settings.global[name] then
    return tostring(settings.global[name].value)
  end
  return tostring(fallback)
end

local function dump_surface_line(index, surface_name)
  local st = scan_status[surface_name] or {}
  local diagnostics = storage.amu_diagnostics[surface_name] or {}
  local sq = processing_queues[surface_name]
  local queue_size = sq and #sq.queue or 0
  local last_scan_age = st.last_scan_tick and (game.tick - st.last_scan_tick) or -1
  local current_scan_age = st.current_scan_start_tick and (game.tick - st.current_scan_start_tick) or -1
  return string.format(
    "%02d. %s | queued=%d | candidates=%d | scanned=%d | registered=%d | paused=%s | camera=%s | last_phase=%s | last_scan_age_ticks=%d | current_scan_age_ticks=%d | diag_proxy=%d | diag_low_pf=%d | diag_no_work=%d | diag_excluded=%d | registry_only=%s",
    index,
    surface_name,
    queue_size,
    st.candidates or 0,
    st.scanned or 0,
    count_valid_registered_entities(surface_name),
    safe_surface_setting(surface_name, storage.amu_surface_paused),
    safe_surface_setting(surface_name, storage.surface_camera_follow),
    tostring(st.phase or "idle"),
    last_scan_age,
    current_scan_age,
    diagnostics.skipped_proxy or 0,
    diagnostics.skipped_low_pf or 0,
    diagnostics.skipped_no_work or 0,
    diagnostics.skipped_excluded or 0,
    diagnostics.registry_only and "true" or "false"
  )
end

function amu_build_performance_dump()
  ensure_storage()
  local lines = {}
  local surfaces = get_scan_surface_names(true, true)

  table.insert(lines, "AutoModuleUpgrade performance dump")
  table.insert(lines, "Generated at tick: " .. tostring(game.tick))
  table.insert(lines, "")
  table.insert(lines, "[settings]")
  table.insert(lines, "scan_planets=" .. dump_setting("amu-scan-planets", true))
  table.insert(lines, "scan_space_platforms=" .. dump_setting("amu-scan-space-platforms", true))
  table.insert(lines, "scan_interval_seconds=" .. dump_setting("amu-scan-interval-seconds", SCAN_INTERVAL_SEC))
  table.insert(lines, "scan_chunks_per_step=" .. dump_setting("amu-scan-chunks-per-step", SCAN_CHUNKS_PER_STEP))
  table.insert(lines, "scan_entities_per_step=" .. dump_setting("amu-scan-entities-per-step", SCAN_ENTITIES_PER_STEP))
  table.insert(lines, "queue_size_per_surface=" .. dump_setting("amu-queue-size-per-surface", QUEUE_SIZE_PER_PLANET))
  table.insert(lines, "optimize_productivity_cap=" .. dump_setting(AMU_OPTIMIZE_PRODUCTIVITY_SETTING, true))
  table.insert(lines, "")
  table.insert(lines, "[totals]")
  table.insert(lines, "surfaces=" .. tostring(#surfaces))
  table.insert(lines, "registered_entities=" .. tostring(total_registered_entities()))
  table.insert(lines, "queued_plans=" .. tostring(total_queued_plans()))
  table.insert(lines, "pending_quality_upgrades=" .. tostring(#(pending_replacements or {})))
  table.insert(lines, "tracked_entities=" .. tostring(total_tracker_entities()))
  table.insert(lines, "pending_planet_scan_surfaces=" .. tostring(count_pending_scan_surfaces()))
  table.insert(lines, "pending_platform_scan_surfaces=" .. tostring(count_pending_platform_scan_surfaces()))
  table.insert(lines, "active_planet_scan=" .. tostring(active_scan_job and active_scan_job.surface_name or "none"))
  table.insert(lines, "active_platform_scan=" .. tostring(active_platform_scan_job and active_platform_scan_job.surface_name or "none"))
  table.insert(lines, "scan_complete=" .. tostring(performance_dump_scan_complete()))
  table.insert(lines, "global_camera_follow=" .. tostring(storage.global_camera_follow == true))
  table.insert(lines, "log_override=" .. tostring(storage.LOG_OVERRIDE == true))
  table.insert(lines, "")
  table.insert(lines, "[surfaces]")
  for index, surface_name in ipairs(surfaces) do
    table.insert(lines, dump_surface_line(index, surface_name))
  end
  table.insert(lines, "")
  table.insert(lines, "[notes]")
  table.insert(lines, "diag_proxy = skipped because an item-request-proxy already existed")
  table.insert(lines, "diag_low_pf = skipped by rate-priority threshold")
  table.insert(lines, "diag_no_work = evaluated but no valid work was found")
  table.insert(lines, "diag_excluded = skipped because the entity was explicitly excluded")
  table.insert(lines, "registry_only = scan used the event-maintained registry instead of a full chunk walk")

  return table.concat(lines, "\n")
end

local function profiler_average(total, samples)
  if not total or not total.valid or not samples or samples <= 0 then return nil end
  local average = helpers.create_profiler(true)
  average.add(total)
  average.divide(samples)
  return average
end

local function build_runtime_profile_localised_string(base_dump)
  local profile = amu_get_runtime_profile()
  if not profile then
    return {"", base_dump, "\n\n[runtime_profile]\nstatus=not_started"}
  end

  local session_average = profiler_average(profile.total, profile.samples)
  local window_average = profiler_average(profile.window, profile.window_samples)
  local current = {
    "",
    "\nscope=AutoModuleUpgrade scheduler handler",
    "\nelapsed_ticks=", tostring(game.tick - profile.started_tick),
    "\nsamples=", tostring(profile.samples),
    "\ntotal=", profile.total,
    "\naverage_per_sample=", session_average or "n/a",
    "\ncurrent_window_ticks=", tostring(game.tick - profile.window_started_tick),
    "\ncurrent_window_samples=", tostring(profile.window_samples),
    "\ncurrent_window_total=", profile.window,
    "\ncurrent_window_average=", window_average or "n/a"
  }
  local previous = ""
  if profile.previous_window then
    local previous_average = profiler_average(profile.previous_window, profile.previous_window_samples)
    previous = {
      "",
      "\nprevious_window_ticks=", tostring(profile.previous_window_ticks),
      "\nprevious_window_samples=", tostring(profile.previous_window_samples),
      "\nprevious_window_total=", profile.previous_window,
      "\nprevious_window_average=", previous_average or "n/a"
    }
  end
  return {
    "", base_dump,
    "\n\n[runtime_profile]", current, previous,
    "\nnote=Factorio does not expose raw profiler values to Lua, so min/max cannot be calculated safely."
  }
end

local function request_performance_dump_translation(player, textbox)
  local request_id = player.request_translation(build_runtime_profile_localised_string(amu_build_performance_dump()))
  amu_dump_translation_requests[request_id] = {
    player_index = player.index,
    textbox = textbox
  }
end

function amu_handle_dump_translation(event)
  local pending = amu_dump_translation_requests[event.id]
  if not pending then return end
  amu_dump_translation_requests[event.id] = nil
  if not event.translated then return end
  local player = game.get_player(pending.player_index)
  local textbox = pending.textbox
  if not player or not player.valid or not textbox or not textbox.valid then return end
  textbox.text = event.result
  textbox.select_all()
  player.opened = textbox
end

function amu_open_performance_dump_window(player)
  if not player or not player.valid then return end
  if not amu_get_runtime_profile() then
    amu_start_runtime_profile()
  end
  local screen = player.gui.screen
  local existing = screen[AMU_DUMP_WINDOW_NAME]
  if existing and existing.valid then existing.destroy() end

  local frame = screen.add{
    type = "frame",
    name = AMU_DUMP_WINDOW_NAME,
    direction = "vertical",
    caption = {"amu-gui.dump-window-title"}
  }
  frame.style.width = 900
  frame.style.maximal_height = 700
  frame.auto_center = true

  local controls = frame.add{type = "flow", direction = "horizontal"}
  controls.add{
    type = "button",
    name = AMU_DUMP_WINDOW_NAME .. "-refresh",
    caption = {"amu-gui.dump-refresh"}
  }
  controls.add{
    type = "button",
    name = AMU_DUMP_WINDOW_NAME .. "-close",
    caption = {"amu-gui.dump-close"}
  }

  local help = frame.add{
    type = "label",
    caption = {"amu-gui.dump-help"}
  }
  help.style.single_line = false

  local textbox = frame.add{
    type = "text-box",
    name = AMU_DUMP_WINDOW_NAME .. "-textbox",
    text = amu_build_performance_dump() .. "\n\n[runtime_profile]\nstatus=translating"
  }
  textbox.style.width = 860
  textbox.style.height = 560
  textbox.word_wrap = false
  textbox.select_all()
  player.opened = textbox
  request_performance_dump_translation(player, textbox)
end

function amu_refresh_performance_dump_window(player)
  if not player or not player.valid then return end
  local window = player.gui.screen[AMU_DUMP_WINDOW_NAME]
  if not window or not window.valid then
    amu_open_performance_dump_window(player)
    return
  end
  local textbox = window[AMU_DUMP_WINDOW_NAME .. "-textbox"]
  if textbox and textbox.valid then
    textbox.text = amu_build_performance_dump() .. "\n\n[runtime_profile]\nstatus=translating"
    request_performance_dump_translation(player, textbox)
  end
end

local function find_scan_cell(rows_flow, row_index, cell_name)
  local row = rows_flow[AMU_WINDOW_NAME .. "-row-" .. row_index]
  if not row or not row.valid then return nil end
  local element_name = AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-" .. cell_name
  local direct = row[element_name]
  if direct then return direct end
  local container = row[element_name .. "-container"]
  return container and container[element_name] or nil
end

local function is_scanning_surface(surface_name)
  local st = scan_status[surface_name]
  return st and st.current_scan_start_tick ~= nil
end

local function get_surface_change_count(surface_name)
  ensure_storage()
  local building_changes = storage.surface_buildings_upgraded[surface_name] or 0
  local module_changes = 0
  local mod_stats = storage.surface_modules_placed[surface_name]
  if mod_stats then
    for _, count in pairs(mod_stats) do
      module_changes = module_changes + count
    end
  end
  return building_changes + module_changes
end

local function sort_platform_surfaces_by_changes(surface_names)
  table.sort(surface_names, function(a, b)
    local a_changes = get_surface_change_count(a)
    local b_changes = get_surface_change_count(b)
    if a_changes ~= b_changes then
      return a_changes > b_changes
    end
    local a_tip = get_surface_tooltip(a)
    local b_tip = get_surface_tooltip(b)
    return a_tip < b_tip
  end)
end

local function get_idle_platform_surface_names()
  local idle = {}
  for _, surface_name in ipairs(get_scan_surface_names()) do
    if is_platform_surface(surface_name) and not is_scanning_surface(surface_name) then
      table.insert(idle, surface_name)
    end
  end
  sort_platform_surfaces_by_changes(idle)
  return idle
end

function get_scan_window_row_entries()
  local rows = {}
  local planets = {}
  local active_platforms = {}
  local idle_platforms = get_idle_platform_surface_names()

  for _, surface_name in ipairs(get_scan_surface_names()) do
    if not is_platform_surface(surface_name) then
      table.insert(planets, surface_name)
    elseif is_scanning_surface(surface_name) then
      table.insert(active_platforms, surface_name)
    end
  end

  sort_platform_surfaces_by_changes(active_platforms)

  for _, surface_name in ipairs(planets) do
    table.insert(rows, {kind = "surface", surface_name = surface_name})
  end

  for _, surface_name in ipairs(active_platforms) do
    table.insert(rows, {kind = "surface", surface_name = surface_name})
  end

  for _, surface_name in ipairs(idle_platforms) do
    table.insert(rows, {kind = "surface", surface_name = surface_name})
  end

  return rows
end

function get_scan_window_surface_rows()
  local rows = {}
  for _, entry in ipairs(get_scan_window_row_entries()) do
    if entry.kind == "surface" then
      table.insert(rows, entry.surface_name)
    end
  end
  return rows
end

local window_width = 470
local table_width = 452

local column_widths = {
  planet = 41,
  queued = 50,
  cand = 48,
  upgraded = 60,
  mods = 34,
  time = 34,
  status = 54,
  jump = 34,
  cam = 32
}

local function add_header_label(table_el, caption, width_key)
  local label = table_el.add{type = "label", caption = caption, style = "amu_scan_header_label"}
  local width = column_widths[width_key]
  label.style.width = width
  label.style.minimal_width = width
  return label
end

local function add_metric_cell(table_el, row, name)
  local cell = table_el.add{
    type = "label",
    name = AMU_WINDOW_NAME .. "-cell-" .. row .. "-" .. name,
    caption = "0",
    style = "amu_scan_cell_label"
  }
  local width = column_widths[name]
  cell.style.width = width
  cell.style.minimal_width = width
  return cell
end

local function add_planet_cell(parent, name, sprite, tooltip)
  local cell = parent.add{
    type = "flow",
    name = name and (name .. "-container") or nil,
    style = "amu_scan_planet_cell",
    direction = "horizontal"
  }
  local planet = cell.add{
    type = "sprite",
    name = name,
    sprite = sprite,
    tooltip = tooltip,
    style = "amu_scan_planet_sprite"
  }
  planet.style.size = {26, 26}
  return planet
end

local function add_scan_data_row(rows_flow, row_index)
  local row = rows_flow.add{
    type = "frame",
    name = AMU_WINDOW_NAME .. "-row-" .. row_index,
    style = "amu_scan_data_row_frame",
    direction = "horizontal"
  }
  add_planet_cell(row, AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-planet", "amu_planet_nauvis", "Surface")
  add_metric_cell(row, row_index, "queued")
  add_metric_cell(row, row_index, "cand")
  add_metric_cell(row, row_index, "upgraded")
  add_metric_cell(row, row_index, "mods")
  local time_cell = row.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-time", caption = "", style = "amu_scan_time_label"}
  time_cell.style.width = column_widths.time
  time_cell.style.minimal_width = column_widths.time
  local status_cell = row.add{type = "label", name = AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-status", caption = "", style = "amu_scan_status_label"}
  status_cell.style.width = column_widths.status
  status_cell.style.minimal_width = column_widths.status
  row.add{
    type = "sprite-button",
    name = AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-jump",
    style = "amu_scan_row_button",
    sprite = "amu_row_search_button",
    hovered_sprite = "amu_row_search_button",
    clicked_sprite = "amu_row_search_button",
    tooltip = {"amu-gui.jump-tooltip"},
    mouse_button_filter = {"left", "right"}
  }
  row.add{
    type = "sprite-button",
    name = AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-cam",
    style = "amu_scan_row_button",
    sprite = "amu_row_close_button",
    hovered_sprite = "amu_row_close_button",
    clicked_sprite = "amu_row_close_button",
    tooltip = {"amu-gui.camera-tooltip"},
    mouse_button_filter = {"left", "right"}
  }
end

local function rebuild_scan_rows(rows_flow, entries)
  while #rows_flow.children > 1 do
    local last = rows_flow.children[#rows_flow.children]
    if last and last.valid then
      last.destroy()
    end
  end

  for row_index in ipairs(entries) do
    add_scan_data_row(rows_flow, row_index)
  end
end

-- Create or recreate the scan status window for a player
function create_scan_window(player)
  if not player or not player.valid then return end
  local screen = player.gui.screen
  if screen[AMU_WINDOW_NAME] then
    screen[AMU_WINDOW_NAME].destroy()
  end

  local window = screen.add{
    type = "frame",
    name = AMU_WINDOW_NAME,
    style = "amu_scan_window_frame",
    direction = "vertical"
  }
  window.style.width = window_width
  window.style.minimal_width = window_width

  -- Title bar with drag handle and close button
  local titlebar = window.add{
    type = "flow",
    name = AMU_WINDOW_NAME .. "-titlebar",
    direction = "horizontal"
  }
  titlebar.drag_target = window

  titlebar.add{
    type = "label",
    caption = {"amu-gui.window-title"},
    style = "amu_scan_title_label",
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
    type = "button",
    name = AMU_WINDOW_NAME .. "-dump",
    caption = {"amu-gui.dump-button"},
    tooltip = {"amu-gui.dump-tooltip"},
    style = "tool_button",
    mouse_button_filter = {"left"}
  }

  titlebar.add{
    type = "sprite-button",
    sprite = "amu_title_plus_button",
    hovered_sprite = "amu_title_plus_button",
    clicked_sprite = "amu_title_plus_button",
    style = "amu_scan_title_button",
    name = AMU_WINDOW_NAME .. "-eye",
    mouse_button_filter = {"left"}
  }

  titlebar.add{
    type = "sprite-button",
    sprite = "amu_title_log_button",
    hovered_sprite = "amu_title_log_button",
    clicked_sprite = "amu_title_log_button",
    style = "amu_scan_title_button",
    name = AMU_WINDOW_NAME .. "-log",
    mouse_button_filter = {"left"}
  }

  titlebar.add{
    type = "sprite-button",
    sprite = "amu_title_close_button",
    hovered_sprite = "amu_title_close_button",
    clicked_sprite = "amu_title_close_button",
    style = "amu_scan_title_button",
    name = AMU_WINDOW_NAME .. "-close",
    mouse_button_filter = {"left"}
  }

  -- Content frame
  local content = window.add{
    type = "frame",
    name = AMU_WINDOW_NAME .. "-content",
    style = "amu_scan_content_frame",
    direction = "vertical"
  }
  content.style.width = table_width

  local scroll = content.add{
    type = "scroll-pane",
    name = AMU_WINDOW_NAME .. "-scroll",
    style = "amu_scan_scroll_pane",
    horizontal_scroll_policy = "never"
  }
  scroll.style.width = table_width
  scroll.style.maximal_height = 300

  local rows_flow = scroll.add{
    type = "flow",
    name = AMU_WINDOW_NAME .. "-rows",
    direction = "vertical"
  }
  rows_flow.style.width = table_width
  rows_flow.style.vertical_spacing = 0

  local header_row = rows_flow.add{
    type = "frame",
    name = AMU_WINDOW_NAME .. "-header-row",
    style = "amu_scan_header_row_frame",
    direction = "horizontal"
  }

  -- Headers
  add_planet_cell(header_row, nil, "amu_planet_header", {"amu-gui.surface"})
  add_header_label(header_row, {"amu-gui.queued"}, "queued")
  add_header_label(header_row, {"amu-gui.candidates"}, "cand")
  add_header_label(header_row, {"amu-gui.upgraded"}, "upgraded")
  add_header_label(header_row, {"amu-gui.modules"}, "mods")
  local clock_header = header_row.add{type = "sprite", sprite = "amu_clock_header", tooltip = {"amu-gui.time-tooltip"}}
  clock_header.style.size = {23, 23}
  clock_header.style.minimal_width = column_widths.time
  add_header_label(header_row, {"amu-gui.status"}, "status")
  add_header_label(header_row, {"amu-gui.jump"}, "jump")
  add_header_label(header_row, {"amu-gui.camera"}, "cam")

  -- Store reference
  amu_gui_players[player.index] = {window = window, visible = true, row_signature = nil}

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
  ensure_storage()
  if not player or not player.valid then return end
  local gui_data = amu_gui_players[player.index]
  if not gui_data or not gui_data.visible then return end

  local window = player.gui.screen[AMU_WINDOW_NAME]
  if not window then
    create_scan_window(player)
    window = player.gui.screen[AMU_WINDOW_NAME]
    if not window then return end
    gui_data = amu_gui_players[player.index]
  end

  -- Update title bar button states
  local titlebar = window[AMU_WINDOW_NAME .. "-titlebar"]
  if titlebar then
    local eye_btn = titlebar[AMU_WINDOW_NAME .. "-eye"]
    if eye_btn and eye_btn.valid then
      if storage.global_camera_follow == true then
        eye_btn.sprite = "amu_title_plus_button"
        eye_btn.hovered_sprite = "amu_title_plus_button"
        eye_btn.clicked_sprite = "amu_title_plus_button"
        eye_btn.tooltip = {"amu-gui.global-camera-on"}
        eye_btn.toggled = true
      else
        eye_btn.sprite = "amu_title_plus_button"
        eye_btn.hovered_sprite = "amu_title_plus_button"
        eye_btn.clicked_sprite = "amu_title_plus_button"
        eye_btn.tooltip = {"amu-gui.global-camera-off"}
        eye_btn.toggled = false
      end
    end
    local log_btn = titlebar[AMU_WINDOW_NAME .. "-log"]
    if log_btn and log_btn.valid then
      if storage.LOG_OVERRIDE then
        log_btn.sprite = "amu_title_log_button"
        log_btn.hovered_sprite = "amu_title_log_button"
        log_btn.clicked_sprite = "amu_title_log_button"
        log_btn.tooltip = {"amu-gui.logging-on"}
        log_btn.toggled = true
      else
        log_btn.sprite = "amu_title_log_button"
        log_btn.hovered_sprite = "amu_title_log_button"
        log_btn.clicked_sprite = "amu_title_log_button"
        log_btn.tooltip = {"amu-gui.logging-off"}
        log_btn.toggled = false
      end
    end
  end

  local rows_flow = window[AMU_WINDOW_NAME .. "-content"][AMU_WINDOW_NAME .. "-scroll"][AMU_WINDOW_NAME .. "-rows"]
  if not rows_flow then return end

  local row_entries = get_scan_window_row_entries()
  local signature_parts = {}
  for i, entry in ipairs(row_entries) do
    signature_parts[i] = entry.surface_name
  end
  local row_signature = table.concat(signature_parts, "\n")
  if gui_data.row_signature ~= row_signature then
    rebuild_scan_rows(rows_flow, row_entries)
    gui_data.row_signature = row_signature
  end

  -- Populate rows
  for i, entry in ipairs(row_entries) do
    local surface_name = entry.surface_name
    local st = scan_status[surface_name] or {}
    local surface = game.surfaces[surface_name]
    local surface_available = surface and surface.valid
    local is_scanning = st.current_scan_start_tick ~= nil
    local elapsed = 0
    if is_scanning then
      elapsed = game.tick - st.current_scan_start_tick
    elseif st.last_scan_tick then
      elapsed = game.tick - st.last_scan_tick
    end

    -- Surface icon
    local planet_cell = find_scan_cell(rows_flow, i, "planet")
    if planet_cell and planet_cell.valid then
      planet_cell.sprite = get_surface_sprite(surface_name)
      planet_cell.tooltip = get_surface_tooltip(surface_name)
    end
    -- Queued
    local queued_cell = find_scan_cell(rows_flow, i, "queued")
    if queued_cell and queued_cell.valid then
      local sq = processing_queues[surface_name]
      local queue_size = sq and #sq.queue or 0
      queued_cell.caption = tostring(queue_size)
      queued_cell.tooltip = {"amu-gui.queued-tooltip", queue_size}
    end

    -- Candidates
    local cand_cell = find_scan_cell(rows_flow, i, "cand")
    if cand_cell and cand_cell.valid then
      cand_cell.caption = tostring(st.candidates or 0)
      cand_cell.tooltip = surface_available and "Candidates collected" or "Surface does not exist yet"
    end

    -- Upgraded (buildings)
    local upgraded_cell = find_scan_cell(rows_flow, i, "upgraded")
    if upgraded_cell and upgraded_cell.valid then
      local count = storage.surface_buildings_upgraded[surface_name] or 0
      upgraded_cell.caption = tostring(count)
      local b_upgs = storage.surface_building_upgrades[surface_name]
      if b_upgs and next(b_upgs) then
        local items = {}
        for key, c in pairs(b_upgs) do
          local name, from, to = key:match("(.+)|(.+)|(.+)")
          local pretty = name and (name:gsub("-", " "):gsub("^%l", string.upper)) or key
          table.insert(items, {count = c, text = c .. "x " .. pretty .. " " .. (from or "?") .. "->" .. (to or "?")})
        end
        table.sort(items, function(a, b) return a.count > b.count end)
        local lines = {}
        for _, item in ipairs(items) do table.insert(lines, item.text) end
        upgraded_cell.tooltip = table.concat(lines, "\n")
      else
        upgraded_cell.tooltip = {"amu-gui.no-building-upgrades"}
      end
    end

    -- Modules placed (grouped by category: quality / prod / speed; efficiency ignored)
    local mods_cell = find_scan_cell(rows_flow, i, "mods")
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
      -- Tooltip: show module upgrade breakdown sorted by count desc
      local m_upgs = storage.surface_module_upgrades[surface_name]
      if m_upgs and next(m_upgs) then
        local items = {}
        for key, c in pairs(m_upgs) do
          local old_name, old_q, new_name, new_q = key:match("(.+)|(.+)|(.+)|(.+)")
          local pretty_old = old_name and (old_name:gsub("-", " "):gsub("^%l", string.upper)) or "?"
          local pretty_new = new_name and (new_name:gsub("-", " "):gsub("^%l", string.upper)) or "?"
          table.insert(items, {count = c, text = c .. "x " .. pretty_old .. " " .. (old_q or "?") .. "->" .. pretty_new .. " " .. (new_q or "?")})
        end
        table.sort(items, function(a, b) return a.count > b.count end)
        local lines = {}
        for _, item in ipairs(items) do table.insert(lines, item.text) end
        mods_cell.tooltip = table.concat(lines, "\n")
      elseif next(by_cat) then
        local tooltip_parts = {}
        for cat, count in pairs(by_cat) do
          table.insert(tooltip_parts, cat:sub(1,1):upper() .. cat:sub(2) .. ": " .. count)
        end
        table.sort(tooltip_parts)
        mods_cell.tooltip = table.concat(tooltip_parts, "\n")
      else
        mods_cell.tooltip = {"amu-gui.no-module-requests"}
      end
    end

    -- Time / watch (green when scanning, white when idle)
    local time_cell = find_scan_cell(rows_flow, i, "time")
    if time_cell and time_cell.valid then
      if is_scanning then
        time_cell.caption = format_time(elapsed)
        time_cell.style.font_color = {r = 0.3, g = 1.0, b = 0.3} -- green
        time_cell.tooltip = {"amu-gui.scanning-for", format_time(elapsed)}
      else
        time_cell.caption = st.last_scan_tick and format_time(elapsed) or "—"
        time_cell.style.font_color = {r = 1.0, g = 1.0, b = 1.0} -- white
        time_cell.tooltip = st.last_scan_tick and ("Last scan " .. format_time(elapsed) .. " ago") or "Not scanned yet"
      end
    end

    -- Status
    local status_cell = find_scan_cell(rows_flow, i, "status")
    if status_cell and status_cell.valid then
      local diagnostics = storage.amu_diagnostics[surface_name] or {}
      local diagnostic_tooltip = {
        "amu-gui.diagnostics-tooltip",
        diagnostics.skipped_proxy or 0,
        diagnostics.skipped_low_pf or 0,
        diagnostics.skipped_no_work or 0,
        diagnostics.skipped_excluded or 0,
        diagnostics.registry_only and "registry" or "full"
      }
      if storage.amu_surface_paused[surface_name] then
        status_cell.caption = {"amu-gui.status-paused"}
        status_cell.tooltip = diagnostic_tooltip
      elseif not surface_available then
        status_cell.caption = {"amu-gui.status-no-surface"}
        status_cell.tooltip = surface_name .. " is not available yet, so scans are skipped"
      elseif is_scanning then
        status_cell.caption = st.phase or "scanning"
        status_cell.tooltip = diagnostic_tooltip
      else
        local sq = processing_queues[surface_name]
        local queue_size = sq and #sq.queue or 0
        if queue_size > 0 then
          status_cell.caption = {"amu-gui.status-queueing"}
          status_cell.tooltip = diagnostic_tooltip
        else
          status_cell.caption = {"amu-gui.status-idle"}
          status_cell.tooltip = diagnostic_tooltip
        end
      end
    end

    -- Jump button: center camera on last upgraded building and highlight changed buildings
    local jump_cell = find_scan_cell(rows_flow, i, "jump")
    if jump_cell and jump_cell.valid then
      local last = storage.surface_last_upgraded[surface_name]
      if last and last.tick then
        jump_cell.enabled = true
        jump_cell.sprite = "amu_row_search_button"
        jump_cell.hovered_sprite = "amu_row_search_button"
        jump_cell.clicked_sprite = "amu_row_search_button"
        jump_cell.tooltip = {"amu-gui.jump-tooltip"}
      else
        jump_cell.enabled = surface_available
        jump_cell.sprite = surface_available and "amu_row_search_button" or "amu_row_search_disabled_button"
        jump_cell.hovered_sprite = jump_cell.sprite
        jump_cell.clicked_sprite = jump_cell.sprite
        jump_cell.tooltip = surface_available and {"amu-gui.rescan-only-tooltip"} or {"amu-gui.no-surface-tooltip"}
      end
    end

    -- Camera toggle button: shows check when enabled, close when disabled
    local cam_cell = find_scan_cell(rows_flow, i, "cam")
    if cam_cell and cam_cell.valid then
      local enabled = storage.surface_camera_follow[surface_name] == true
      cam_cell.sprite = "amu_row_close_button"
      cam_cell.hovered_sprite = "amu_row_close_button"
      cam_cell.clicked_sprite = "amu_row_close_button"
      cam_cell.tooltip = enabled and {"amu-gui.camera-on-tooltip"} or {"amu-gui.camera-off-tooltip"}
    end
  end
end

-- Toggle scan window visibility
function toggle_scan_window(player)
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
