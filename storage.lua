-- ============================================================
-- Helper: ensure storage tables exist (call before accessing storage)
-- ============================================================
function ensure_storage()
  if not storage.surface_buildings_upgraded then storage.surface_buildings_upgraded = {} end
  if not storage.surface_modules_placed then storage.surface_modules_placed = {} end
  if not storage.surface_building_upgrades then storage.surface_building_upgrades = {} end
  if not storage.surface_module_upgrades then storage.surface_module_upgrades = {} end
  if not storage.surface_last_upgraded then storage.surface_last_upgraded = {} end
  if not storage.surface_changed_buildings then storage.surface_changed_buildings = {} end
  if not storage.amu_change_highlight_objects then storage.amu_change_highlight_objects = {} end
  if not storage.surface_camera_follow then storage.surface_camera_follow = {} end
  if storage.LOG_OVERRIDE == nil then storage.LOG_OVERRIDE = false end
  if not storage.amu_gui_locations then storage.amu_gui_locations = {} end
  if not storage.last_scanned_planet_index then storage.last_scanned_planet_index = 0 end
  if not storage.last_auto_scan_tick then storage.last_auto_scan_tick = 0 end
  if not storage.pending_replacements then storage.pending_replacements = {} end
  if not storage.amu_surface_paused then storage.amu_surface_paused = {} end
  if not storage.amu_excluded_entities then storage.amu_excluded_entities = {} end
  if not storage.amu_candidate_registry then storage.amu_candidate_registry = {} end
  if not storage.amu_registry_ready then storage.amu_registry_ready = {} end
  if not storage.amu_diagnostics then storage.amu_diagnostics = {} end
  pending_replacements = storage.pending_replacements
end

function amu_entity_key(entity)
  if not entity or not entity.valid then return nil end
  if entity.unit_number then return tostring(entity.unit_number) end
  return entity.surface.name .. "|" .. entity.name .. "|" .. string.format("%.2f", entity.position.x) .. "|" .. string.format("%.2f", entity.position.y)
end

function amu_entity_is_excluded(entity)
  local key = amu_entity_key(entity)
  return key and storage.amu_excluded_entities[key] == true or false
end

local function get_entity_change_key(entity)
  if entity.unit_number then
    return entity.unit_number
  end
  return entity.name .. "|" .. string.format("%.2f", entity.position.x) .. "|" .. string.format("%.2f", entity.position.y)
end

function amu_record_changed_building(entity)
  if not entity or not entity.valid then return end
  ensure_storage()

  local surface_name = entity.surface.name
  if not storage.surface_changed_buildings[surface_name] then
    storage.surface_changed_buildings[surface_name] = {}
  end

  storage.surface_changed_buildings[surface_name][get_entity_change_key(entity)] = {
    entity = entity,
    name = entity.name,
    position = {x = entity.position.x, y = entity.position.y},
    tick = game.tick
  }
  storage.surface_last_upgraded[surface_name] = {
    x = entity.position.x,
    y = entity.position.y,
    tick = game.tick
  }
end

local function get_point(point)
  if not point then return nil end
  return {
    x = point.x or point[1],
    y = point.y or point[2]
  }
end

local function get_entity_highlight_box(entity)
  local ok, box = pcall(function() return entity.selection_box end)
  if not ok or not box then
    ok, box = pcall(function() return entity.bounding_box end)
  end
  if not ok or not box then return nil end

  local left_top = get_point(box.left_top or box[1])
  local right_bottom = get_point(box.right_bottom or box[2])
  if not left_top or not right_bottom or left_top.x == nil or left_top.y == nil or right_bottom.x == nil or right_bottom.y == nil then
    return nil
  end

  local padding = AMU_CHANGE_HIGHLIGHT_PADDING or 0
  return {
    left_top = {x = left_top.x - padding, y = left_top.y - padding},
    right_bottom = {x = right_bottom.x + padding, y = right_bottom.y + padding}
  }
end

local function clear_change_highlights(player_index)
  if not storage.amu_change_highlight_objects then return end

  local objects = storage.amu_change_highlight_objects[player_index]
  if not objects then return end

  for _, object in ipairs(objects) do
    if object and object.valid then
      object.destroy()
    end
  end
  storage.amu_change_highlight_objects[player_index] = nil
end

function amu_draw_change_highlights(player, surface_name)
  if not player or not player.valid or not surface_name then return 0 end
  ensure_storage()
  clear_change_highlights(player.index)

  local surface = game.get_surface(surface_name)
  local changed_buildings = storage.surface_changed_buildings[surface_name]
  if not surface or not surface.valid or not changed_buildings then return 0 end

  local objects = {}
  local stale_keys = {}
  local count = 0

  for key, record in pairs(changed_buildings) do
    local entity = record.entity
    if entity and entity.valid and entity.surface.name == surface_name then
      local box = get_entity_highlight_box(entity)
      if box then
        local object = rendering.draw_rectangle{
          surface = surface,
          left_top = box.left_top,
          right_bottom = box.right_bottom,
          color = {r = 1, g = 0.9, b = 0, a = 1},
          width = 4,
          filled = false,
          players = {player.index},
          time_to_live = AMU_CHANGE_HIGHLIGHT_TICKS,
          draw_on_ground = false
        }
        table.insert(objects, object)
        count = count + 1
      end
    else
      table.insert(stale_keys, key)
    end
  end

  for _, key in ipairs(stale_keys) do
    changed_buildings[key] = nil
  end
  storage.amu_change_highlight_objects[player.index] = objects
  return count
end
