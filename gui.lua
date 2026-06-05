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
function create_scan_window(player)
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
