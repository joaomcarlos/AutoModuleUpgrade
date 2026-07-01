-- ============================================================
-- Module Lookup System
-- ============================================================

local function build_scan_candidate_entity_lookups()
  scan_candidate_entity_names = {}
  scan_module_entity_name_set = {}
  scan_quality_entity_name_set = {}

  for name, proto in pairs(prototypes.entity) do
    local has_module_slots = (proto.module_inventory_size and proto.module_inventory_size > 0)
      or proto.quality_affects_module_slots == true
    local can_quality_upgrade = amu_can_quality_upgrade_prototype(proto)
    if has_module_slots or can_quality_upgrade then
      table.insert(scan_candidate_entity_names, name)
      if has_module_slots then
        scan_module_entity_name_set[name] = true
      end
      if can_quality_upgrade then
        scan_quality_entity_name_set[name] = true
      end
    end
  end

  table.sort(scan_candidate_entity_names)
end

local function build_quality_lookups()
  quality_order = {}
  quality_index = {}
  local qualities = {}
  for name, proto in pairs(prototypes.quality) do
    table.insert(qualities, {name = name, level = proto.level or 0, order = proto.order or name})
  end
  table.sort(qualities, function(a, b)
    if a.level ~= b.level then return a.level < b.level end
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  for index, quality in ipairs(qualities) do
    quality_order[index] = quality.name
    quality_index[quality.name] = index
  end
end

local function add_module_candidate(category, name, quality, tier, score)
  if not module_candidates[category] then
    module_candidates[category] = {}
  end
  table.insert(module_candidates[category], {
    name = name,
    quality = quality,
    tier = tier,
    qidx = quality_index[quality] or 0,
    score = score or 0
  })
end

local function module_objective_score(category, effects, tier, qidx)
  if category == "speed" then return effects and effects.speed or 0 end
  if category == "productivity" then return effects and effects.productivity or 0 end
  if category == "quality" then return effects and effects.quality or 0 end
  if category == "efficiency" then return -(effects and effects.consumption or 0) end
  -- Unknown modded categories retain deterministic tier/quality ordering.
  return (tier or 0) * 1000 + (qidx or 0)
end

local function sort_module_candidates()
  for _, candidates in pairs(module_candidates) do
    table.sort(candidates, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      if a.tier ~= b.tier then return a.tier > b.tier end
      if a.qidx ~= b.qidx then return a.qidx > b.qidx end
      return a.name < b.name
    end)
  end
end

-- Build lookup tables from prototypes
-- Uses LuaItemPrototype.category and LuaItemPrototype.tier (official API)
function build_module_lookups()
  build_quality_lookups()
  module_tiers = {}
  module_categories = {}
  module_candidates = {}
  for name, proto in pairs(prototypes.item) do
    if not proto.hidden and proto.module_effects and proto.category and proto.tier then
      local category = proto.category
      local tier = proto.tier
      module_tiers[name] = proto.tier
      module_categories[name] = category

      for qname, _ in pairs(prototypes.quality) do
        local effects = amu_get_module_effects and amu_get_module_effects(name, qname) or proto.module_effects
        local score = module_objective_score(category, effects, tier, quality_index[qname])
        add_module_candidate(category, name, qname, tier, score)
      end
    end
  end
  sort_module_candidates()
  build_scan_candidate_entity_lookups()
end

-- Helpers for tracking network reservations during a scan
function network_has_items(logistic_network, name, quality, count, reservations)
  if not logistic_network then return false end
  if not prototypes.item[name] then return false end
  local available = logistic_network.get_item_count({name = name, quality = quality})
  if available < count then return false end
  if not reservations then return true end
  local key = name .. ":" .. quality
  local reserved = reservations[key] or 0
  return available - reserved >= count
end

function reserve_items(reservations, name, quality, count)
  if not reservations then return end
  local key = name .. ":" .. quality
  reservations[key] = (reservations[key] or 0) + count
end

function reserve_module_plan_items(reservations, modules_plan)
  if not reservations or not modules_plan then return end
  for _, request in ipairs(modules_plan) do
    if request.id and request.id.name then
      reserve_items(reservations, request.id.name, request.id.quality or "normal", 1)
    end
  end
end

local function find_scored_module_upgrade(module_name, module_quality, category, logistic_network, reservations)
  local proto = prototypes.item[module_name]
  if not proto then return nil, nil end

  local current_effects = amu_get_module_effects and amu_get_module_effects(module_name, module_quality) or proto.module_effects
  local current_score = module_objective_score(category, current_effects, module_tiers[module_name], quality_index[module_quality])

  for _, cand in ipairs(module_candidates[category] or {}) do
    if cand.score <= current_score + AMU_PRODUCTIVITY_EPSILON then
      return nil, nil
    end
    if network_has_items(logistic_network, cand.name, cand.quality, 1, reservations) then
      return cand.name, cand.quality
    end
  end

  return nil, nil
end

-- Get the next upgrade candidate for a module
-- Returns: upgrade_name, upgrade_quality or nil, nil
function find_upgrade(module_name, module_quality, logistic_network, reservations)
  if not module_name or not module_quality then return nil, nil end

  local category = module_categories[module_name]
  local tier = module_tiers[module_name]
  if not category or not tier then
    if DEBUG then game.print("[AutoModuleUpgrade] [UPG DEBUG] No category/tier for " .. tostring(module_name)) end
    return nil, nil
  end

  return find_scored_module_upgrade(module_name, module_quality, category, logistic_network, reservations)
end

-- Find best available module of a given category for empty slots
-- Candidates are ranked by their exact quality-aware objective effect.
-- needed_count: how many items are required (defaults to 1)
function find_best_available(category, logistic_network, reservations, needed_count, entity, recipe_proto)
  needed_count = needed_count or 1
  for _, cand in ipairs(module_candidates[category] or {}) do
    local allowed = not entity or not amu_module_allowed or amu_module_allowed(entity, recipe_proto, cand.name)
    if allowed and network_has_items(logistic_network, cand.name, cand.quality, needed_count, reservations) then
      return {name = cand.name, quality = cand.quality}
    end
  end

  return nil
end
