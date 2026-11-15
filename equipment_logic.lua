-- ============================================================
-- Equipment Grid Evaluation & Swap Logic
-- ============================================================
-- Construction bots cannot insert into equipment grids, so unlike module
-- upgrades (item-request-proxy) equipment upgrades are applied by script:
-- the replacement item is removed from the logistic network, the old
-- equipment is taken and its item returned to the network, and the new
-- equipment is put at the same position. Net item accounting matches what
-- a bot swap would do; energy and shield charge are preserved.

-- Group equipment prototypes into families by naming convention so tier
-- upgrades (mk1 -> mk2) work without hardcoding names:
--   "battery-mk2-equipment" -> family "battery", tier 2
--   "personal-roboport-equipment" -> family "personal-roboport", tier 1
function build_equipment_lookups()
  equipment_families = {}
  equipment_family_of = {}
  equipment_tiers = {}
  equipment_item_names = {}
  for name, proto in pairs(prototypes.equipment) do
    if not proto.hidden then
      local take_result = proto.take_result
      local item_name = take_result and take_result.name or nil
      if not item_name and prototypes.item[name] then item_name = name end
      if item_name then
        equipment_item_names[name] = item_name
        local base = name:gsub("%-equipment$", "")
        local tier = 1
        local family, mk = base:match("^(.+)%-mk(%d+)$")
        if family then
          base = family
          tier = tonumber(mk) or 1
        end
        equipment_family_of[name] = base
        equipment_tiers[name] = tier
        local fam = equipment_families[base]
        if not fam then
          fam = {}
          equipment_families[base] = fam
        end
        table.insert(fam, {name = name, item_name = item_name, tier = tier, shape = proto.shape})
      end
    end
  end
  for _, fam in pairs(equipment_families) do
    table.sort(fam, function(a, b) return a.tier < b.tier end)
  end
end

local function shape_cells(shape)
  if not shape then return nil end
  if shape.width and shape.height then
    local cells = {}
    for dx = 0, shape.width - 1 do
      for dy = 0, shape.height - 1 do
        cells[#cells + 1] = {x = dx, y = dy}
      end
    end
    return cells
  end
  if shape.points then
    local cells = {}
    for _, p in ipairs(shape.points) do
      cells[#cells + 1] = {x = p.x or p[1] or 0, y = p.y or p[2] or 0}
    end
    return cells
  end
  return nil
end

-- Occupied-cell map for every grid entry except `except_eq` (ghosts included).
local function build_occupied_map(grid, except_eq)
  local occupied = {}
  for _, eq in ipairs(grid.equipment) do
    if eq ~= except_eq and eq.position then
      local cells = shape_cells(eq.shape)
      if cells then
        for _, c in ipairs(cells) do
          occupied[(eq.position.x + c.x) .. "," .. (eq.position.y + c.y)] = true
        end
      else
        occupied[eq.position.x .. "," .. eq.position.y] = true
      end
    end
  end
  return occupied
end

local function candidate_fits(grid, occupied, shape, position)
  local cells = shape_cells(shape)
  if not cells then return true end -- unknown shape; apply-time put is the arbiter
  for _, c in ipairs(cells) do
    local x = position.x + c.x
    local y = position.y + c.y
    if x < 0 or y < 0 or x >= grid.width or y >= grid.height then return false end
    if occupied[x .. "," .. y] then return false end
  end
  return true
end

local function equipment_is_ghost(eq)
  local ok, ghost_name = pcall(function() return eq.ghost_name end)
  return ok and ghost_name ~= nil
end

-- Best upgrade for one equipment entry: highest family tier available in the
-- network (never downgrading quality), else same equipment at higher quality.
local function find_equipment_upgrade(eq, grid, network, reservations)
  local family_name = equipment_family_of[eq.name]
  local fam = family_name and equipment_families[family_name]
  if not fam then return nil end

  local cur_tier = equipment_tiers[eq.name] or 1
  local cur_quality = eq.quality and eq.quality.name or "normal"
  local cur_qidx = quality_index[cur_quality] or 1
  local occupied = build_occupied_map(grid, eq)

  for i = #fam, 1, -1 do
    local cand = fam[i]
    if cand.tier < cur_tier then break end
    local tier_upgrade = cand.tier > cur_tier
    if tier_upgrade or cand.name == eq.name then
      for qidx = #quality_order, 1, -1 do
        local qname = quality_order[qidx]
        if (tier_upgrade and qidx >= cur_qidx) or (not tier_upgrade and qidx > cur_qidx) then
          if network_has_items(network, cand.item_name, qname, 1, reservations)
            and candidate_fits(grid, occupied, cand.shape, eq.position) then
            return cand, qname
          end
        end
      end
    end
  end
  return nil
end

-- Evaluate a grid for equipment upgrades. Returns a plan array plus a short
-- info string, or nil when nothing can be upgraded. Plan entries are plain
-- data: {position={x,y}, old_name, old_quality, new_name, new_quality, new_item}
function amu_evaluate_equipment_grid(grid, network, reservations)
  if not grid or not grid.valid or not network then return nil end
  local plan = {}
  local counts = {}
  for _, eq in ipairs(grid.equipment) do
    if eq.valid and eq.position and not equipment_is_ghost(eq) then
      local removed_ok, removed = pcall(function() return eq.to_be_removed end)
      if not (removed_ok and removed) and equipment_item_names[eq.name] then
        local cand, qname = find_equipment_upgrade(eq, grid, network, reservations)
        if cand then
          table.insert(plan, {
            position = {x = eq.position.x, y = eq.position.y},
            old_name = eq.name,
            old_quality = eq.quality and eq.quality.name or "normal",
            old_item = equipment_item_names[eq.name],
            new_name = cand.name,
            new_quality = qname,
            new_item = cand.item_name
          })
          reserve_items(reservations, cand.item_name, qname, 1)
          local key = cand.name .. "|" .. qname
          counts[key] = (counts[key] or 0) + 1
        end
      end
    end
  end
  if #plan == 0 then return nil end
  local parts = {}
  for key, count in pairs(counts) do
    local name, qname = key:match("(.+)|(.+)")
    local short = name:gsub("%-equipment$", "")
    table.insert(parts, count .. "x" .. short .. " " .. qname)
  end
  return plan, "equip: " .. table.concat(parts, ", ")
end

local function equipment_at_position(grid, x, y)
  for _, eq in ipairs(grid.equipment) do
    if eq.valid and eq.position and eq.position.x == x and eq.position.y == y then
      return eq
    end
  end
  return nil
end

-- Apply an equipment plan: swap each entry against the real logistic network.
-- Only a LuaLogisticNetwork can source/return items (platform hub pools are
-- read-only tables, so equipment work is skipped on space platforms).
function amu_apply_equipment_plan(entity, grid, plan, network)
  if not entity or not entity.valid or not grid or not grid.valid then return 0, nil end
  if type(network) == "table" or not network then return 0, nil end
  local applied = 0
  local details = {}
  for _, p in ipairs(plan or {}) do
    local eq = equipment_at_position(grid, p.position.x, p.position.y)
    if eq and eq.valid and eq.name == p.old_name
      and (eq.quality and eq.quality.name or "normal") == p.old_quality then
      local removed = network.remove_item{name = p.new_item, count = 1, quality = p.new_quality}
      if (removed or 0) >= 1 then
        local ok_energy, saved_energy = pcall(function() return eq.energy end)
        local ok_shield, saved_shield = pcall(function() return eq.shield end)
        local taken = grid.take{equipment = eq}
        if taken then
          local new_eq = grid.put{name = p.new_name, quality = p.new_quality, position = p.position}
          if new_eq then
            pcall(function()
              if ok_energy and saved_energy and new_eq.max_energy and new_eq.max_energy > 0 then
                new_eq.energy = math.min(saved_energy, new_eq.max_energy)
              end
              if ok_shield and saved_shield and new_eq.max_shield and new_eq.max_shield > 0 then
                new_eq.shield = math.min(saved_shield, new_eq.max_shield)
              end
            end)
            local old_count = taken.count or 1
            local inserted = network.insert{name = taken.name, count = old_count, quality = taken.quality or p.old_quality} or 0
            if inserted < old_count then
              pcall(function()
                entity.surface.spill_item_stack{
                  position = entity.position,
                  stack = {name = taken.name, count = old_count - inserted, quality = taken.quality or p.old_quality}
                }
              end)
            end
            applied = applied + 1
            table.insert(details, p)
          else
            -- Put did not fit after all: restore the old equipment and refund.
            grid.put{name = p.old_name, quality = p.old_quality, position = p.position}
            network.insert{name = p.new_item, count = 1, quality = p.new_quality}
          end
        else
          network.insert{name = p.new_item, count = 1, quality = p.new_quality}
        end
      end
    end
  end
  return applied, details
end

function entity_has_grid(entity)
  if not entity or not entity.valid then return false end
  local ok, grid = pcall(function() return entity.grid end)
  return ok and grid ~= nil
end

-- Record upgrade transitions for the scan-window tooltip.
function amu_record_equipment_upgrades(surface_name, details)
  if not surface_name or not details then return end
  ensure_storage()
  if not storage.surface_equipment_upgrades[surface_name] then
    storage.surface_equipment_upgrades[surface_name] = {}
  end
  for _, p in ipairs(details) do
    local key = p.old_name .. "|" .. p.old_quality .. "|" .. p.new_name .. "|" .. p.new_quality
    storage.surface_equipment_upgrades[surface_name][key] = (storage.surface_equipment_upgrades[surface_name][key] or 0) + 1
  end
end

-- Periodic sweep of connected players' armor grids. Armor equipment upgrades
-- use the logistic network the character is standing in; players outside
-- coverage are skipped. This is intentionally not queued: each player's grid
-- is tiny and the swap is instant.
function amu_process_player_equipment()
  if not amu_scan_equipment_enabled or not amu_scan_equipment_enabled() then return end
  for _, player in pairs(game.connected_players) do
    local character = player.character
    if character and character.valid and player.force then
      local ok_inv, armor_inv = pcall(function() return character.get_inventory(defines.inventory.character_armor) end)
      local stack = ok_inv and armor_inv and armor_inv[1]
      if stack and stack.valid_for_read then
        local grid = stack.grid
        if grid and grid.valid then
          local network = character.surface.find_logistic_network_by_position(character.position, character.force)
          if network then
            local plan = amu_evaluate_equipment_grid(grid, network, nil)
            if plan then
              local applied, details = amu_apply_equipment_plan(character, grid, plan, network)
              if applied > 0 then
                amu_record_equipment_upgrades(character.surface.name, details)
                if DEBUG or storage.LOG_OVERRIDE then
                  game.print("[AutoModuleUpgrade] [EQUIP] " .. player.name .. " armor: " .. applied .. " equipment upgrade(s)")
                end
              end
            end
          end
        end
      end
    end
  end
end
