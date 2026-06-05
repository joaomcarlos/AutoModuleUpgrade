-- ============================================================
-- Module Lookup System
-- ============================================================

-- Build lookup tables from item prototypes
-- Uses LuaItemPrototype.category and LuaItemPrototype.tier (official API)
function build_module_lookups()
  module_tiers = {}
  module_categories = {}
  for name, proto in pairs(prototypes.item) do
    if proto.module_effects and proto.category and proto.tier then
      module_tiers[name] = proto.tier
      module_categories[name] = proto.category
    end
  end
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
  local current_tier = module_tiers[module_name]
  if not current_tier then return nil, nil end

  local proto = prototypes.item[module_name]
  if not proto then return nil, nil end

  -- Extract quality bonus from module_effects table: {quality = 0.01}
  local base_effect = 0
  if proto.module_effects and proto.module_effects.quality then
    base_effect = proto.module_effects.quality
  end

  local current_q = prototypes.quality[module_quality]
  local current_score = base_effect * (current_q and current_q.default_multiplier or 1)

  -- Collect all better quality-module variants
  local candidates = {}
  for name, tier in pairs(module_tiers) do
    if module_categories[name] == "quality" then
      local p = prototypes.item[name]
      if p and p.module_effects and p.module_effects.quality then
        local be = p.module_effects.quality
        for qname, qproto in pairs(prototypes.quality) do
          local score = be * qproto.default_multiplier
          if score > current_score then
            table.insert(candidates, {
              name = name,
              quality = qname,
              score = score
            })
          end
        end
      end
    end
  end

  -- Sort by score descending (best first)
  table.sort(candidates, function(a, b) return a.score > b.score end)

  -- Return first available in network
  for _, cand in ipairs(candidates) do
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
  local best = nil

  if category == "quality" then
    -- Power-score based for quality modules
    local best_score = -1
    for name, tier in pairs(module_tiers) do
      if module_categories[name] == "quality" then
        local p = prototypes.item[name]
        if p and p.module_effects and p.module_effects.quality then
          local be = p.module_effects.quality
          for qname, qproto in pairs(prototypes.quality) do
            if network_has_items(logistic_network, name, qname, needed_count, reservations) then
              local score = be * qproto.default_multiplier
              if score > best_score then
                best = {name = name, quality = qname}
                best_score = score
              end
            end
          end
        end
      end
    end
  else
    -- Tier-first for speed/efficiency/productivity
    local best_tier = 0
    local best_qidx = 0
    for name, tier in pairs(module_tiers) do
      if module_categories[name] == category then
        for qname, qproto in pairs(prototypes.quality) do
          if network_has_items(logistic_network, name, qname, needed_count, reservations) then
            local qidx = quality_index[qname] or 0
            if tier > best_tier or (tier == best_tier and qidx > best_qidx) then
              best_tier = tier
              best_qidx = qidx
              best = {name = name, quality = qname}
            end
          end
        end
      end
    end
  end

  return best
end
