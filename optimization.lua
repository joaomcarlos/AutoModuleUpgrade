-- ============================================================
-- Machine objective detection and productivity-cap optimisation
-- ============================================================

local EFFECT_KEYS = {"consumption", "speed", "productivity", "pollution", "quality"}

function amu_get_module_effects(module_name, quality_name)
  local proto = prototypes.item[module_name]
  if not proto then return nil end

  local ok, effects = pcall(function()
    return proto.get_module_effects(quality_name)
  end)
  if ok and effects then return effects end
  return proto.module_effects
end

local function effect_value(effects, key)
  if not effects then return 0 end
  return effects[key] or 0
end

function amu_module_allowed(entity, recipe_proto, module_name)
  local module_proto = prototypes.item[module_name]
  if not module_proto or not module_proto.category then return false end

  local entity_proto = entity and entity.prototype
  local entity_categories = entity_proto and entity_proto.allowed_module_categories
  if entity_categories and not entity_categories[module_proto.category] then return false end

  local recipe_categories = recipe_proto and recipe_proto.allowed_module_categories
  if recipe_categories and not recipe_categories[module_proto.category] then return false end

  local effects = module_proto.module_effects
  local entity_effects = entity_proto and entity_proto.allowed_effects
  local recipe_effects = recipe_proto and recipe_proto.allowed_effects
  for _, key in ipairs(EFFECT_KEYS) do
    if effect_value(effects, key) ~= 0 then
      if entity_effects and entity_effects[key] ~= true then return false end
      if recipe_effects and recipe_effects[key] ~= true then return false end
    end
  end
  return true
end

local function get_recipe(entity)
  if not entity or not entity.valid or not entity.get_recipe then return nil, nil end
  local ok, recipe = pcall(function() return entity.get_recipe() end)
  if not ok or not recipe then return nil, nil end
  return recipe, recipe.prototype
end

local function module_category_counts(module_inv)
  local counts = {}
  if not module_inv then return counts end
  for i = 1, #module_inv do
    local stack = module_inv[i]
    if stack and stack.valid_for_read then
      local category = module_categories[stack.name]
      if category then counts[category] = (counts[category] or 0) + 1 end
    end
  end
  return counts
end

function amu_detect_machine_objective(entity, module_inv)
  local counts = module_category_counts(module_inv)
  if (counts.quality or 0) > 0 then return "quality", counts end

  local productivity_count = counts.productivity or 0
  local speed_count = counts.speed or 0
  local efficiency_count = counts.efficiency or 0

  -- A clear speed or efficiency majority is treated as player intent. Ties
  -- fall through to the recipe objective so prototype iteration order cannot
  -- change the recommendation between sessions.
  if speed_count > productivity_count and speed_count > efficiency_count then
    return "speed", counts
  end
  if efficiency_count > productivity_count and efficiency_count > speed_count then
    return "efficiency", counts
  end

  local _, recipe_proto = get_recipe(entity)
  if amu_module_allowed(entity, recipe_proto, "productivity-module") then
    return "productivity", counts
  end
  if productivity_count > 0 then return "productivity", counts end
  if speed_count > 0 then return "speed", counts end
  if efficiency_count > 0 then return "efficiency", counts end
  return "speed", counts
end

local function installed_module_productivity(module_inv)
  local total = 0
  if not module_inv then return total end
  for i = 1, #module_inv do
    local stack = module_inv[i]
    if stack and stack.valid_for_read then
      total = total + effect_value(amu_get_module_effects(stack.name, stack.quality.name), "productivity")
    end
  end
  return total
end

local function prototype_base_productivity(entity)
  local receiver = entity and entity.prototype and entity.prototype.effect_receiver
  local base_effect = receiver and receiver.base_effect
  return effect_value(base_effect, "productivity")
end

function amu_productivity_slot_is_redundant(baseline, installed_productivity, slot_productivity, cap, epsilon)
  epsilon = epsilon or AMU_PRODUCTIVITY_EPSILON or 0.0001
  return baseline + installed_productivity - slot_productivity >= cap - epsilon
end

function amu_get_machine_recommendation(entity)
  if not entity or not entity.valid then return nil end
  local ok_inv, module_inv = pcall(function() return entity.get_module_inventory() end)
  if not ok_inv then module_inv = nil end
  local objective, counts = amu_detect_machine_objective(entity, module_inv)
  local recipe, recipe_proto = get_recipe(entity)

  local recommendation = {
    objective = objective,
    category_counts = counts,
    recipe_name = recipe and (recipe.localised_name or recipe.name) or nil,
    reason = "preserve-player-intent"
  }

  if objective == "quality" then
    recommendation.reason = "quality-modules-present"
    return recommendation
  end
  if objective ~= "productivity" or not recipe or not recipe_proto then
    recommendation.reason = objective .. "-layout"
    return recommendation
  end

  local installed_prod = installed_module_productivity(module_inv)
  local force_prod = recipe.productivity_bonus or 0
  local baseline = force_prod + prototype_base_productivity(entity)
  local ok_current, current_prod = pcall(function() return entity.productivity_bonus end)
  if ok_current and current_prod then
    baseline = math.max(baseline, current_prod - installed_prod)
  end

  local cap = recipe_proto.maximum_productivity or 3
  recommendation.productivity_cap = cap
  recommendation.baseline_productivity = baseline
  recommendation.module_productivity = installed_prod
  recommendation.current_productivity = math.min(cap, baseline + installed_prod)
  recommendation.redundant_productivity = math.max(0, baseline + installed_prod - cap)
  recommendation.reason = recommendation.redundant_productivity > AMU_PRODUCTIVITY_EPSILON
    and "productivity-cap-reached"
    or "productivity-below-cap"
  return recommendation
end

function amu_format_recommendation(recommendation)
  if not recommendation then return {"amu-recommendation.unavailable"} end
  local na = {"amu-recommendation.not-applicable"}
  local productivity = recommendation.current_productivity
    and string.format("%.1f%%", recommendation.current_productivity * 100) or na
  local cap = recommendation.productivity_cap
    and string.format("%.1f%%", recommendation.productivity_cap * 100) or na
  local redundant = recommendation.redundant_productivity
    and string.format("%.1f%%", recommendation.redundant_productivity * 100) or na
  return {
    "amu-recommendation.summary",
    {"amu-recommendation.objective-" .. tostring(recommendation.objective)},
    recommendation.recipe_name or na,
    productivity,
    cap,
    redundant,
    {"amu-recommendation.reason-" .. tostring(recommendation.reason)}
  }
end
