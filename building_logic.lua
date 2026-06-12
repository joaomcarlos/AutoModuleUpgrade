-- ============================================================
-- Building Evaluation & Proxy Management
-- ============================================================

-- Create or update item-request-proxy
local function create_module_proxy(entity, slot_index, old_module, old_quality, new_module, new_quality)
  local surface = entity.surface
  local module_inv = entity.get_module_inventory()
  if not module_inv then return end

  local inv_index = module_inv.index
  local stack_0based = slot_index - 1

  -- Remove existing proxy if any
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    entity.item_request_proxy.destroy()
  end

  -- Create new proxy with insert + removal plan
  local modules_plan = {
    {
      id = {name = new_module, quality = new_quality},
      items = {in_inventory = {{inventory = inv_index, stack = stack_0based}}}
    }
  }

  local removal_plan = {
    {
      id = {name = old_module, quality = old_quality},
      items = {in_inventory = {{inventory = inv_index, stack = stack_0based}}}
    }
  }

  surface.create_entity{
    name = "item-request-proxy",
    target = entity,
    position = entity.position,
    force = entity.force,
    modules = modules_plan,
    removal_plan = removal_plan
  }
end

-- Create insert-only proxy for empty slots
local function create_insert_proxy(entity, requests)
  local surface = entity.surface

  -- Remove existing proxy if any
  if entity.item_request_proxy and entity.item_request_proxy.valid then
    entity.item_request_proxy.destroy()
  end

  local modules_plan = {}
  for _, req in ipairs(requests) do
    table.insert(modules_plan, {
      id = {name = req.name, quality = req.quality},
      items = {in_inventory = {{inventory = req.inventory, stack = req.stack}}}
    })
  end

  surface.create_entity{
    name = "item-request-proxy",
    target = entity,
    position = entity.position,
    force = entity.force,
    modules = modules_plan
  }
end

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
  local current_name = entity.quality.name
  local idx = quality_index[current_name]
  if not idx or idx >= #quality_order then return nil end
  return quality_order[idx + 1]
end

-- Check a single building for upgrades/fills
-- Returns: "upgrade", "fill", "none", or "skip" (plus optional info string)
function check_building(entity, context)
  if not entity.valid then return "skip", "invalid" end
  if entity.type == "entity-ghost" or entity.type == "tile-ghost" or entity.to_be_deconstructed() or entity.to_be_upgraded() then return "skip", "ghost/decon/upgrade" end
  local logistic_network = get_entity_supply_network(entity, context)
  if not logistic_network then return "none", "no logistic network" end

  local reservations = context and context.reservations or nil

  local has_modules = entity.prototype and entity.prototype.module_inventory_size and entity.prototype.module_inventory_size > 0
  local module_inv = has_modules and entity.get_module_inventory() or nil

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
  local did_anything = false

  -- Phase A: Upgrade existing modules
  for _, slot_info in ipairs(filled_slots) do
    local new_name, new_quality = find_upgrade(slot_info.name, slot_info.quality, logistic_network, reservations)
    if new_name and new_quality then
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
    local best = nil
    if #filled_slots > 0 then
      -- Match category of the first existing module in this building
      local target_category = module_categories[filled_slots[1].name] or "productivity"
      best = find_best_available(target_category, logistic_network, reservations, #empty_slots)
      if not best then
        best = find_best_available("speed", logistic_network, reservations, #empty_slots)
      end
    else
      -- Empty machine: prefer productivity if allowed, else speed
      local proto = entity.prototype
      local productivity_allowed = proto.allowed_effects and proto.allowed_effects.productivity == true
      if productivity_allowed then
        local recipe = entity.get_recipe and entity:get_recipe()
        if recipe and recipe.prototype and recipe.prototype.allowed_effects then
          if recipe.prototype.allowed_effects.productivity ~= true then
            productivity_allowed = false
          end
        end
      end
      if productivity_allowed then
        best = find_best_available("productivity", logistic_network, reservations, #empty_slots)
      end
      if not best then
        best = find_best_available("speed", logistic_network, reservations, #empty_slots)
      end
    end
    if best then
      for _, slot in ipairs(empty_slots) do
        table.insert(modules_plan, {
          id = {name = best.name, quality = best.quality},
          items = {in_inventory = {{inventory = module_inv.index, stack = slot - 1}}}
        })
      end
      table.insert(fill_details, abbr(best.name, best.quality) .. " x" .. #empty_slots)
      if reservations then
        reserve_items(reservations, best.name, best.quality, #empty_slots)
      end
      did_anything = true
    end
  end

  if not did_anything then
    -- No module work; check if the building itself can receive a quality upgrade
    local target_quality = get_next_building_quality(entity)
    if target_quality and network_has_items(logistic_network, entity.name, target_quality, 1, reservations) then
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
    local info_str = table.concat(parts, "; ")

    -- Create combined proxy if anything was done (skipped in dry_run mode)
    if not (context and context.dry_run) then
      if entity.item_request_proxy and entity.item_request_proxy.valid then
        entity.item_request_proxy.destroy()
      end
      entity.surface.create_entity{
        name = "item-request-proxy",
        target = entity,
        position = entity.position,
        force = entity.force,
        modules = modules_plan,
        removal_plan = removal_plan
      }
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

    return "upgrade", info_str, modules_plan, removal_plan, module_upgrade_details
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
  if not network_has_items(logistic_network, entity.name, target_quality, 1, reservations) then
    return false end
  local platform_supply_required = false
  if type(logistic_network) == "table" and logistic_network.amu_is_platform_supply_pool then
    platform_supply_required = true
    supply_planet_name = supply_planet_name or logistic_network.amu_supply_planet_name
  end
  local saved_pf = get_products_finished(entity)
  local upgrade_ok, marked = pcall(function()
    return entity.order_upgrade{
      force = entity.force,
      target = {name = entity.name, quality = target_quality}
    }
  end)
  if upgrade_ok and marked then
    reserve_items(reservations, entity.name, target_quality, 1)
    if not modules_already_reserved then
      reserve_module_plan_items(reservations, modules_plan)
    end
    local original_quality = entity.quality and entity.quality.name or "normal"
    table.insert(pending_replacements, {
      surface_name = surface_name,
      position = entity.position,
      entity_name = entity.name,
      original_quality = original_quality,
      target_quality = target_quality,
      saved_pf = saved_pf,
      modules_plan = modules_plan,
      removal_plan = removal_plan,
      info = info,
      tick_queued = game.tick,
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
