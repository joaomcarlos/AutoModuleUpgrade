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

-- Planet configuration
PLANETS = {"nauvis", "vulcanus", "gleba", "fulgora", "aquilo"}
NO_PF_ENTITIES = {["agricultural-tower"] = true, ["beacon"] = true, ["cargo-bay"] = true} -- Buildings that don't track products_finished; skip PF checks
AMU_WINDOW_NAME = "amu_scan_window"
AMU_CHANGE_HIGHLIGHT_TICKS = 15 * UPS
AMU_CHANGE_HIGHLIGHT_PADDING = 0.15

-- Entity types that can receive quality upgrades but have no module slots
QUALITY_UPGRADEABLE_TYPES = {
  ["agricultural-tower"] = true,
  ["cargo-bay"] = true,
}

-- Module-level lookup tables (rebuilt on load, not stored in storage)
module_tiers = {}
module_categories = {}
module_candidates = {}
scan_candidate_entity_names = {}
scan_module_entity_name_set = {}
scan_quality_entity_name_set = {}
quality_order = {"normal", "uncommon", "rare", "epic", "legendary"}
quality_index = {normal = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5}
GUI_UPDATE_INTERVAL = UPS
DEFERRED_REPLACEMENT_CHECK_INTERVAL = UPS
