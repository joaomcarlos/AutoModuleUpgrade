-- ============================================================
-- Module Lookup System
-- ============================================================

local function build_scan_candidate_entity_lookups()
  scan_candidate_entity_names = {}
  scan_module_entity_name_set = {}
  scan_quality_entity_name_set = {}

  for name, proto in pairs(prototypes.entity) do
    local has_module_slots = proto.module_inventory_size and proto.module_inventory_size > 0
    local can_quality_upgrade = QUALITY_UPGRADEABLE_TYPES[proto.type] == true
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

local function sort_module_candidates()
  for category, candidates in pairs(module_candidates) do
    if category == "quality" then
      table.sort(candidates, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.tier ~= b.tier then return a.tier > b.tier end
        if a.qidx ~= b.qidx then return a.qidx > b.qidx end
        return a.name < b.name
      end)
    else
      table.sort(candidates, function(a, b)
        if a.tier ~= b.tier then return a.tier > b.tier end
        if a.qidx ~= b.qidx then return a.qidx > b.qidx end
        return a.name < b.name
      end)
    end
  end
end

-- Build lookup tables from prototypes
-- Uses LuaItemPrototype.category and LuaItemPrototype.tier (official API)
function build_module_lookups()
  module_tiers = {}
  module_categories = {}
  module_candidates = {}
  for name, proto in pairs(prototypes.item) do
    if proto.module_effects and proto.category and proto.tier then
      local category = proto.category
      local tier = proto.tier
      module_tiers[name] = proto.tier
      module_categories[name] = category

      for qname, qproto in pairs(prototypes.quality) do
        if category == "quality" then
          local quality_effect = proto.module_effects.quality
          if quality_effect then
            add_module_candidate(category, name, qname, tier, quality_effect * qproto.default_multiplier)
          end
        else
          add_module_candidate(category, name, qname, tier)
        end
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

-- Power-score-based search for quality modules
local function find_quality_module_upgrade(module_name, module_quality, logistic_network, reservations)
  local proto = prototypes.item[module_name]
  if not proto then return nil, nil end

  local base_effect = proto.module_effects and proto.module_effects.quality
  if not base_effect then return nil, nil end

  local current_q = prototypes.quality[module_quality]
  local current_score = base_effect * (current_q and current_q.default_multiplier or 1)

  for _, cand in ipairs(module_candidates.quality or {}) do
    if cand.score <= current_score then
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

  -- Is this a quality module? Use power-score-based search
  if category == "quality" then
    return find_quality_module_upgrade(module_name, module_quality, logistic_network, reservations)
  end

  -- Speed, efficiency, productivity: tier-first, then quality
  local current_qidx = quality_index[module_quality] or 1

  -- Step 1: Same tier, better quality (best to worst)
  for qidx = 5, current_qidx + 1, -1 do
    local qname = quality_order[qidx]
    if network_has_items(logistic_network, module_name, qname, 1, reservations) then
      return module_name, qname
    end
  end

  -- Step 2: Next tier, normal quality
  local next_tier = tier + 1
  local next_tier_name = category .. "-module-" .. next_tier
  if prototypes.item[next_tier_name] and network_has_items(logistic_network, next_tier_name, "normal", 1, reservations) then
    return next_tier_name, "normal"
  end

  return nil, nil
end

-- Find best available module of a given category for empty slots
-- For speed/efficiency/productivity: highest tier, then best quality
-- For quality modules: highest power score (quality.bonus * multiplier)
-- needed_count: how many items are required (defaults to 1)
function find_best_available(category, logistic_network, reservations, needed_count)
  needed_count = needed_count or 1
  for _, cand in ipairs(module_candidates[category] or {}) do
    if network_has_items(logistic_network, cand.name, cand.quality, needed_count, reservations) then
      return {name = cand.name, quality = cand.quality}
    end
  end

  return nil
end
