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

local function find_child(parent, name)
  if not parent or not parent.valid then return nil end
  local child = parent[name]
  if child then return child end
  for _, nested in pairs(parent.children) do
    child = find_child(nested, name)
    if child then return child end
  end
  return nil
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

function get_scan_window_surface_rows()
  local rows = {}
  local active_platforms = {}
  local idle_platforms = get_idle_platform_surface_names()

  for _, surface_name in ipairs(get_scan_surface_names()) do
    if not is_platform_surface(surface_name) then
      table.insert(rows, surface_name)
    elseif is_scanning_surface(surface_name) then
      table.insert(active_platforms, surface_name)
    end
  end

  sort_platform_surfaces_by_changes(active_platforms)

  for _, surface_name in ipairs(active_platforms) do
    table.insert(rows, surface_name)
  end

  for _, surface_name in ipairs(idle_platforms) do
    table.insert(rows, surface_name)
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
    tooltip = "Inspect changed buildings",
    mouse_button_filter = {"left"}
  }
  row.add{
    type = "sprite-button",
    name = AMU_WINDOW_NAME .. "-cell-" .. row_index .. "-cam",
    style = "amu_scan_row_button",
    sprite = "amu_row_close_button",
    hovered_sprite = "amu_row_close_button",
    clicked_sprite = "amu_row_close_button",
    tooltip = "Toggle auto camera follow",
    mouse_button_filter = {"left"}
  }
end

local function sync_scan_rows(rows_flow, target_count)
  local existing_count = #rows_flow.children - 1
  while existing_count > target_count do
    local last = rows_flow.children[#rows_flow.children]
    if last and last.valid then
      last.destroy()
    end
    existing_count = existing_count - 1
  end

  for row_index = existing_count + 1, target_count do
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
    caption = "AutoModuleUpgrade Scans",
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
  add_planet_cell(header_row, nil, "amu_planet_header", "Surface")
  add_header_label(header_row, "Queued", "queued")
  add_header_label(header_row, "Cand", "cand")
  add_header_label(header_row, "Upgraded", "upgraded")
  add_header_label(header_row, "Mods", "mods")
  local clock_header = header_row.add{type = "sprite", sprite = "amu_clock_header", tooltip = "Scan time / age"}
  clock_header.style.size = {23, 23}
  clock_header.style.minimal_width = column_widths.time
  add_header_label(header_row, "Status", "status")
  add_header_label(header_row, "Jump", "jump")
  add_header_label(header_row, "Cam", "cam")

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
  ensure_storage()
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
        eye_btn.sprite = "amu_title_plus_button"
        eye_btn.hovered_sprite = "amu_title_plus_button"
        eye_btn.clicked_sprite = "amu_title_plus_button"
        eye_btn.tooltip = "Global camera follow ON (click to use per-surface)"
        eye_btn.toggled = true
      else
        eye_btn.sprite = "amu_title_plus_button"
        eye_btn.hovered_sprite = "amu_title_plus_button"
        eye_btn.clicked_sprite = "amu_title_plus_button"
        eye_btn.tooltip = "Global camera follow OFF — per-surface (click to force ON)"
        eye_btn.toggled = false
      end
    end
    local log_btn = titlebar[AMU_WINDOW_NAME .. "-log"]
    if log_btn and log_btn.valid then
      if storage.LOG_OVERRIDE then
        log_btn.sprite = "amu_title_log_button"
        log_btn.hovered_sprite = "amu_title_log_button"
        log_btn.clicked_sprite = "amu_title_log_button"
        log_btn.tooltip = "Logging ON (click to disable)"
        log_btn.toggled = true
      else
        log_btn.sprite = "amu_title_log_button"
        log_btn.hovered_sprite = "amu_title_log_button"
        log_btn.clicked_sprite = "amu_title_log_button"
        log_btn.tooltip = "Logging OFF (click to enable)"
        log_btn.toggled = false
      end
    end
  end

  local rows_flow = window[AMU_WINDOW_NAME .. "-content"][AMU_WINDOW_NAME .. "-scroll"][AMU_WINDOW_NAME .. "-rows"]
  if not rows_flow then return end

  local target_surfaces = get_scan_window_surface_rows()
  sync_scan_rows(rows_flow, #target_surfaces)

  -- Populate rows
  for i, surface_name in ipairs(target_surfaces) do
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
    local planet_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-planet")
    if planet_cell and planet_cell.valid then
      planet_cell.sprite = get_surface_sprite(surface_name)
      planet_cell.tooltip = get_surface_tooltip(surface_name)
    end

    -- Queued
    local queued_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-queued")
    if queued_cell and queued_cell.valid then
      local sq = processing_queues[surface_name]
      local queue_size = sq and #sq.queue or 0
      queued_cell.caption = tostring(queue_size)
      queued_cell.tooltip = "Queued: " .. queue_size
    end

    -- Candidates
    local cand_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-cand")
    if cand_cell and cand_cell.valid then
      cand_cell.caption = tostring(st.candidates or 0)
      cand_cell.tooltip = surface_available and "Candidates collected" or "Surface does not exist yet"
    end

    -- Upgraded (buildings)
    local upgraded_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-upgraded")
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
        upgraded_cell.tooltip = "No buildings upgraded yet"
      end
    end

    -- Modules placed (grouped by category: quality / prod / speed; efficiency ignored)
    local mods_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-mods")
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
        mods_cell.tooltip = "No modules placed yet"
      end
    end

    -- Time / watch (green when scanning, white when idle)
    local time_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-time")
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
    local status_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-status")
    if status_cell and status_cell.valid then
      if not surface_available then
        status_cell.caption = "no surface"
        status_cell.tooltip = surface_name .. " is not available yet, so scans are skipped"
      elseif is_scanning then
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

    -- Jump button: center camera on last upgraded building and highlight changed buildings
    local jump_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-jump")
    if jump_cell and jump_cell.valid then
      local last = storage.surface_last_upgraded[surface_name]
      if last and last.tick then
        jump_cell.enabled = true
        jump_cell.sprite = "amu_row_search_button"
        jump_cell.hovered_sprite = "amu_row_search_button"
        jump_cell.clicked_sprite = "amu_row_search_button"
        jump_cell.tooltip = "Inspect changed buildings"
      else
        jump_cell.enabled = false
        jump_cell.sprite = "amu_row_search_disabled_button"
        jump_cell.hovered_sprite = "amu_row_search_disabled_button"
        jump_cell.clicked_sprite = "amu_row_search_disabled_button"
        jump_cell.tooltip = "No changed buildings yet"
      end
    end

    -- Camera toggle button: shows check when enabled, close when disabled
    local cam_cell = find_child(rows_flow, AMU_WINDOW_NAME .. "-cell-" .. i .. "-cam")
    if cam_cell and cam_cell.valid then
      local enabled = storage.surface_camera_follow[surface_name] == true
      cam_cell.sprite = "amu_row_close_button"
      cam_cell.hovered_sprite = "amu_row_close_button"
      cam_cell.clicked_sprite = "amu_row_close_button"
      cam_cell.tooltip = enabled and "Auto camera follow ON (click to disable)" or "Auto camera follow OFF (click to enable)"
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
