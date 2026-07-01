-- ============================================================
-- Building Evaluation & Proxy Management
-- ============================================================

local function get_entity_supply_network(entity, context)
  if context and context.logistic_network ~= nil then
    return context.logistic_network
  end
  if amu_get_surface_platform_supply_network then
    local platform_network = amu_get_surface_platform_supply_network(entity.surface, entity.force)
    if platform_network then
      return platform_network
    end
  end
  return entity.surface.find_logistic_network_by_position(entity.position, entity.force)
end

-- Get the next higher quality level for a building (e.g. epic -> legendary)
function get_next_building_quality(entity)
  if not entity.quality then return nil end
  local next_quality = entity.quality.next
  return next_quality and next_quality.name or nil
end

function amu_get_entity_upgrade_item_name(entity)
  if not entity or not entity.valid or not entity.prototype then return nil end
  local items = entity.prototype.items_to_place_this
  if items and items[1] and items[1].name then return items[1].name end
  if prototypes.item[entity.name] then return entity.name end
  return nil
end

function amu_validate_module_plan(entity, modules_plan, removal_plan)
  if not entity or not entity.valid or entity.to_be_deconstructed() or entity.to_be_upgraded() then
    return false, "entity-busy"
  end
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    return false, "existing-proxy"
  end
  local ok, module_inv = pcall(function() return entity.get_module_inventory() end)
  if not ok or not module_inv then return false, "no-module-inventory" end

  local removals_by_stack = {}
  for _, request in ipairs(removal_plan or {}) do
    local location = request.items and request.items.in_inventory and request.items.in_inventory[1]
    if location then
      local slot = location.stack + 1
      removals_by_stack[slot] = true
      local stack = module_inv[slot]
      local quality = stack and stack.valid_for_read and stack.quality and stack.quality.name or nil
      if not stack or not stack.valid_for_read or stack.name ~= request.id.name or quality ~= (request.id.quality or "normal") then
        return false, "stale-removal-plan"
      end
    end
  end

  for _, request in ipairs(modules_plan or {}) do
    local location = request.items and request.items.in_inventory and request.items.in_inventory[1]
    if location then
      local slot = location.stack + 1
      local stack = module_inv[slot]
      if not removals_by_stack[slot] and stack and stack.valid_for_read then
        return false, "stale-insert-plan"
      end
    end
  end
  return true
end

-- Check a single building for upgrades/fills
-- Returns: "upgrade", "fill", "none", or "skip" (plus optional info string)
function check_building(entity, context)
  if not entity.valid then return "skip", "invalid" end
  if entity.type == "entity-ghost" or entity.type == "tile-ghost" or entity.to_be_deconstructed() or entity.to_be_upgraded() then return "skip", "ghost/decon/upgrade" end
  if entity.item_request_proxy and entity.item_request_proxy.valid then return "skip", "existing proxy" end
  local logistic_network = get_entity_supply_network(entity, context)
  if not logistic_network then return "none", "no logistic network" end

  local reservations = context and context.reservations or nil

  local ok_inv, module_inv = pcall(function() return entity.get_module_inventory() end)
  if not ok_inv then module_inv = nil end
  local recipe = nil
  local recipe_proto = nil
  if entity.get_recipe then
    local ok_recipe, value = pcall(function() return entity.get_recipe() end)
    if ok_recipe and value then recipe = value; recipe_proto = value.prototype end
  end

  local filled_slots = {}
  local empty_slots = {}
  local category_counts = {}
  local module_count = 0

  if module_inv then
    module_count = #module_inv
    -- Scan all slots
    for slot = 1, module_count do
      local stack = module_inv[slot]
      if stack and stack.valid_for_read then
        table.insert(filled_slots, {slot = slot, name = stack.name, quality = stack.quality.name})
        local cat = module_categories[stack.name]
        if cat then
          category_counts[cat] = (category_counts[cat] or 0) + 1
        end
      else
        table.insert(empty_slots, slot)
      end
    end
  end

  -- Helper: abbreviate module name for logs
  local function abbr(name, quality)
    local cat = module_categories[name] or name:match("^(.-)-module") or name
    local tier = module_tiers[name] or ""
    local q = (quality or ""):sub(1, 3)
    return cat:sub(1, 4) .. tier .. q
  end

  local modules_plan = {}
  local removal_plan = {}
  local upgrade_counts = {} -- key -> count for grouping
  local module_upgrade_details = {} -- {old_name, old_quality, new_name, new_quality}
  local fill_details = {}
  local optimisation_details = {}
  local did_anything = false
  local handled_slots = {}
  local recommendation = amu_get_machine_recommendation and amu_get_machine_recommendation(entity) or nil

  -- Replace only productivity that is provably above the recipe cap. This is
  -- conservative: quality/efficiency/speed layouts remain player-owned intent.
  local optimise_productivity = not settings.global[AMU_OPTIMIZE_PRODUCTIVITY_SETTING]
    or settings.global[AMU_OPTIMIZE_PRODUCTIVITY_SETTING].value == true
  if optimise_productivity and recommendation and recommendation.objective == "productivity" and recommendation.productivity_cap then
    local remaining_productivity = recommendation.module_productivity or 0
    local baseline = recommendation.baseline_productivity or 0
    local cap = recommendation.productivity_cap
    for _, slot_info in ipairs(filled_slots) do
      if module_categories[slot_info.name] == "productivity" then
        local effects = amu_get_module_effects(slot_info.name, slot_info.quality)
        local slot_productivity = effects and effects.productivity or 0
        if amu_productivity_slot_is_redundant(baseline, remaining_productivity, slot_productivity, cap) then
          local speed = find_best_available("speed", logistic_network, reservations, 1, entity, recipe_proto)
          if speed then
            handled_slots[slot_info.slot] = true
            local stack_0based = slot_info.slot - 1
            table.insert(modules_plan, {
              id = {name = speed.name, quality = speed.quality},
              items = {in_inventory = {{inventory = module_inv.index, stack = stack_0based}}}
            })
            table.insert(removal_plan, {
              id = {name = slot_info.name, quality = slot_info.quality},
              items = {in_inventory = {{inventory = module_inv.index, stack = stack_0based}}}
            })
            table.insert(module_upgrade_details, {
              old_name = slot_info.name,
              old_quality = slot_info.quality,
              new_name = speed.name,
              new_quality = speed.quality
            })
            reserve_items(reservations, speed.name, speed.quality, 1)
            remaining_productivity = remaining_productivity - slot_productivity
            table.insert(optimisation_details, "prod cap -> speed")
            did_anything = true
          end
        end
      end
    end
  end

  -- Phase A: Upgrade existing modules
  for _, slot_info in ipairs(filled_slots) do
    local new_name, new_quality = nil, nil
    if not handled_slots[slot_info.slot] then
      new_name, new_quality = find_upgrade(slot_info.name, slot_info.quality, logistic_network, reservations)
    end
    if new_name and new_quality and amu_module_allowed(entity, recipe_proto, new_name) then
      local stack_0based = slot_info.slot - 1
      table.insert(modules_plan, {
        id = {name = new_name, quality = new_quality},
        items = {in_inventory = {{inventory = module_inv.index, stack = stack_0based}}}
      })
      table.insert(removal_plan, {
        id = {name = slot_info.name, quality = slot_info.quality},
        items = {in_inventory = {{inventory = module_inv.index, stack = stack_0based}}}
      })
      local key = abbr(slot_info.name, slot_info.quality) .. "->" .. abbr(new_name, new_quality)
      upgrade_counts[key] = (upgrade_counts[key] or 0) + 1
      table.insert(module_upgrade_details, {
        old_name = slot_info.name,
        old_quality = slot_info.quality,
        new_name = new_name,
        new_quality = new_quality
      })
      if reservations then
        reserve_items(reservations, new_name, new_quality, 1)
      end
      did_anything = true
    end
  end

  -- Phase B: Fill empty slots
  if #empty_slots > 0 then
    local objective = recommendation and recommendation.objective or "speed"
    local projected_productivity = recommendation
      and ((recommendation.baseline_productivity or 0) + (recommendation.module_productivity or 0)) or 0
    local cap = recommendation and recommendation.productivity_cap or nil
    local fill_counts = {}
    for _, slot in ipairs(empty_slots) do
      local target_category = objective
      if optimise_productivity and objective == "productivity" and cap and projected_productivity >= cap - AMU_PRODUCTIVITY_EPSILON then
        target_category = "speed"
      end
      local best = find_best_available(target_category, logistic_network, reservations, 1, entity, recipe_proto)
      if best then
        table.insert(modules_plan, {
          id = {name = best.name, quality = best.quality},
          items = {in_inventory = {{inventory = module_inv.index, stack = slot - 1}}}
        })
        reserve_items(reservations, best.name, best.quality, 1)
        local key = best.name .. "|" .. best.quality
        fill_counts[key] = (fill_counts[key] or 0) + 1
        local effects = amu_get_module_effects(best.name, best.quality)
        projected_productivity = projected_productivity + (effects and effects.productivity or 0)
        did_anything = true
      end
    end
    for key, count in pairs(fill_counts) do
      local name, quality = key:match("(.+)|(.+)")
      table.insert(fill_details, abbr(name, quality) .. " x" .. count)
    end
  end

  if not did_anything then
    -- No module work; check if the building itself can receive a quality upgrade
    local target_quality = get_next_building_quality(entity)
    local upgrade_item_name = amu_get_entity_upgrade_item_name(entity)
    if target_quality and upgrade_item_name and network_has_items(logistic_network, upgrade_item_name, target_quality, 1, reservations) then
      local info_str = "quality -> " .. target_quality
      if not (context and context.dry_run) then
        if try_defer_quality_upgrade(entity, entity.surface.name, modules_plan, removal_plan, info_str, reservations, nil, logistic_network) then
          return "upgrade", info_str, modules_plan, removal_plan
        end
      end
      -- dry_run path for scan: still report as upgrade so it gets queued
      return "upgrade", info_str, modules_plan, removal_plan
    end
  end

  if did_anything then
    local parts = {}
    if next(upgrade_counts) then
      local upg_parts = {}
      for key, count in pairs(upgrade_counts) do
        table.insert(upg_parts, count .. "x" .. key)
      end
      table.insert(parts, "upg: " .. table.concat(upg_parts, ", "))
    end
    if #fill_details > 0 then table.insert(parts, "fill: " .. table.concat(fill_details, ", ")) end
    if #optimisation_details > 0 then table.insert(parts, "optimise: " .. table.concat(optimisation_details, ", ")) end
    local info_str = table.concat(parts, "; ")

    -- Create combined proxy if anything was done (skipped in dry_run mode)
    if not (context and context.dry_run) then
      local valid_plan = amu_validate_module_plan(entity, modules_plan, removal_plan)
      if not valid_plan then return "skip", "plan changed before apply" end
      local proxy = entity.surface.create_entity{
        name = "item-request-proxy",
        target = entity,
        position = entity.position,
        force = entity.force,
        modules = modules_plan,
        removal_plan = removal_plan
      }
      if not proxy then return "skip", "proxy creation failed" end
      if amu_record_changed_building then
        amu_record_changed_building(entity)
      end
      local surf_name = entity.surface.name
      local do_camera = storage.global_camera_follow
      if do_camera == nil then
        do_camera = storage.surface_camera_follow[surf_name] == true
      end
      if do_camera then
        for _, player in pairs(game.connected_players) do
          if player.force == entity.force then
            player.centered_on = entity
            break
          end
        end
      end
      if DEBUG or storage.LOG_OVERRIDE then
        game.print("[AutoModuleUpgrade] [APPLY] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " — " .. info_str)
      end
    end

    return "upgrade", info_str, modules_plan, removal_plan, module_upgrade_details, recommendation
  end

  return "none", "no upgrade or fill available", nil, nil, nil
end

-- Attempt to defer a building for quality upgrade; returns true if deferred
-- Uses order_upgrade so the building stays functional until bots replace it
function try_defer_quality_upgrade(entity, surface_name, modules_plan, removal_plan, info, reservations, modules_already_reserved, supply_network, supply_planet_name)
  local target_quality = get_next_building_quality(entity)
  if not target_quality then return false end
  if entity.to_be_upgraded() then return false end
  local logistic_network = supply_network or get_entity_supply_network(entity)
  local upgrade_item_name = amu_get_entity_upgrade_item_name(entity)
  if not upgrade_item_name or not network_has_items(logistic_network, upgrade_item_name, target_quality, 1, reservations) then
    return false end
  local platform_supply_required = false
  if type(logistic_network) == "table" and logistic_network.amu_is_platform_supply_pool then
    platform_supply_required = true
    supply_planet_name = supply_planet_name or logistic_network.amu_supply_planet_name
  end
  local saved_pf, saved_pf_supported = get_products_finished(entity)
  local upgrade_ok, marked = pcall(function()
    return entity.order_upgrade{
      force = entity.force,
      target = {name = entity.name, quality = target_quality}
    }
  end)
  if upgrade_ok and marked then
    reserve_items(reservations, upgrade_item_name, target_quality, 1)
    if not modules_already_reserved then
      reserve_module_plan_items(reservations, modules_plan)
    end
    local original_quality = entity.quality and entity.quality.name or "normal"
    table.insert(pending_replacements, {
      surface_name = surface_name,
      position = entity.position,
      entity_name = entity.name,
      upgrade_item_name = upgrade_item_name,
      original_quality = original_quality,
      target_quality = target_quality,
      saved_pf = saved_pf,
      saved_pf_supported = saved_pf_supported,
      modules_plan = modules_plan,
      removal_plan = removal_plan,
      info = info,
      tick_queued = game.tick,
      next_check_tick = game.tick + DEFERRED_REPLACEMENT_CHECK_INTERVAL,
      original_unit_number = entity.unit_number,
      platform_supply_required = platform_supply_required,
      supply_planet_name = supply_planet_name
    })
    if DEBUG then
      game.print("[AutoModuleUpgrade] [DEFER] " .. entity.name .. " at " .. entity.position.x .. "," .. entity.position.y .. " -> " .. target_quality .. " (pf_rate=" .. format_pf_rate(entity) .. ")")
    end
    return true
  end
  return false
end
