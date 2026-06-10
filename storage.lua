-- ============================================================
-- Helper: ensure storage tables exist (call before accessing storage)
-- ============================================================
function ensure_storage()
  if not storage.surface_buildings_upgraded then storage.surface_buildings_upgraded = {} end
  if not storage.surface_modules_placed then storage.surface_modules_placed = {} end
  if not storage.surface_building_upgrades then storage.surface_building_upgrades = {} end
  if not storage.surface_module_upgrades then storage.surface_module_upgrades = {} end
  if not storage.surface_last_upgraded then storage.surface_last_upgraded = {} end
  if not storage.surface_camera_follow then storage.surface_camera_follow = {} end
  if storage.LOG_OVERRIDE == nil then storage.LOG_OVERRIDE = false end
  if not storage.amu_gui_locations then storage.amu_gui_locations = {} end
  if not storage.last_scanned_planet_index then storage.last_scanned_planet_index = 0 end
  if not storage.pending_replacements then storage.pending_replacements = {} end
  pending_replacements = storage.pending_replacements
end
