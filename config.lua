-- ============================================================
-- Constants & Configuration
-- ============================================================

DEBUG = false
LOG_TICKS = false -- If true, print [TICK] and [SKIP] queue logs
MOVE_CAMERA_AFTER_UPGRADE = false -- Center camera on building after applying module upgrades
HOVER_APPLY = false -- If true, auto-apply module upgrades on crosshair select (on_selected_entity_changed)

USE_RATE_PRIORITY = true -- If true, use tracker-based queuing; if false, direct queue from scan
USE_ABSOLUTE_PF = false -- If true and USE_RATE_PRIORITY is true, sort by total products_finished; if false, sort by production rate diff

-- Priority configuration
MIN_READINGS = 2 -- Minimum pf snapshots before rate-based sorting kicks in (only for USE_RATE_PRIORITY)

-- Scan configuration
UPS = 60 -- Game updates per second
SCAN_INTERVAL_SEC = 120 -- Seconds between scans
SCAN_SCHEDULER_INTERVAL = 12 -- Ticks between scan/queue scheduler updates
-- 16 aggressive, 1 conservative
SCAN_CHUNKS_PER_STEP = 1 -- Max chunks scanned per scheduler step
-- 100 aggressive, 8 conservative
SCAN_ENTITIES_PER_STEP = 8 -- Max candidate buildings evaluated per scheduler step

-- Priority configuration
MIN_PF_DIFF = 15 -- Minimum production rate in items per minute to be eligible for rate-priority queuing
QUEUE_SIZE_PER_PLANET = 40 -- Max buildings queued per surface per scan

-- Surface and prioritisation configuration
-- Surfaces and quality chains are discovered dynamically at runtime.
NO_PF_ENTITY_TYPES = {
  ["agricultural-tower"] = true,
  ["beacon"] = true,
  ["cargo-bay"] = true,
  ["lab"] = true,
  ["mining-drill"] = true,
}
AMU_WINDOW_NAME = "amu_scan_window"
AMU_DUMP_WINDOW_NAME = "amu_performance_dump_window"
AMU_CHANGE_HIGHLIGHT_TICKS = 15 * UPS
AMU_CHANGE_HIGHLIGHT_PADDING = 0.15

-- Entity types that can receive quality upgrades but have no module slots
QUALITY_UPGRADEABLE_TYPES = {
  ["agricultural-tower"] = true,
  ["inserter"] = true,
}

QUALITY_UPGRADEABLE_ENTITY_NAMES = {
  ["accumulator"] = true,
  ["beacon"] = true,
  ["cargo-bay"] = true,
  ["heat-exchanger"] = true,
  ["heating-tower"] = true,
  ["medium-electric-pole"] = true,
  ["nuclear-reactor"] = true,
  ["offshore-pump"] = true,
  ["pump"] = true,
  ["pumpjack"] = true,
  ["radar"] = true,
  ["recycler"] = true,
  ["roboport"] = true,
  ["rocket-silo"] = true,
  ["solar-panel"] = true,
  ["steam-turbine"] = true,
  ["storage-chest"] = true,
  ["substation"] = true,
}

function amu_can_quality_upgrade_name(entity_name)
  return entity_name and QUALITY_UPGRADEABLE_ENTITY_NAMES[entity_name] == true or false
end

function amu_can_quality_upgrade_prototype(proto)
  if not proto then return false end
  if QUALITY_UPGRADEABLE_TYPES[proto.type] == true then return true end
  return amu_can_quality_upgrade_name(proto.name)
end

function amu_can_quality_upgrade_entity(entity)
  if not entity or not entity.valid then return false end
  if QUALITY_UPGRADEABLE_TYPES[entity.type] == true then return true end
  return amu_can_quality_upgrade_name(entity.name)
end

-- Module-level lookup tables (rebuilt on load, not stored in storage)
module_tiers = {}
module_categories = {}
module_candidates = {}
scan_candidate_entity_names = {}
scan_module_entity_name_set = {}
scan_quality_entity_name_set = {}
quality_order = {}
quality_index = {}
GUI_UPDATE_INTERVAL = UPS
DEFERRED_REPLACEMENT_CHECK_INTERVAL = UPS
AMU_PRODUCTIVITY_EPSILON = 0.0001
AMU_SELECTION_TOOL_NAME = "amu-selection-tool"
AMU_OPTIMIZE_PRODUCTIVITY_SETTING = "amu-optimize-productivity-cap"
