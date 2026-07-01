# Productivity Optimization Research

This document records the research and reasoning behind Auto Module Upgrade's
machine objective detection and productivity-cap optimization. It is
documentation for developers and maintainers. It is not intended for in-game
display.

## Scope

The goal is to decide, per machine, when installed productivity modules should
be preserved and when some of them should be replaced with speed modules to
maximize real output without changing the machine's purpose.

The design had to satisfy three constraints:

- Respect explicit player intent, especially quality-focused machines.
- Follow Factorio's productivity rules and recipe caps, not approximate them.
- Avoid replacing productivity with speed unless that productivity is provably
  redundant for the current machine and recipe.

## Why this optimization exists

In late-game Space Age factories, some recipes can reach their maximum allowed
productivity through a combination of:

- productivity research,
- machine-intrinsic productivity bonuses,
- high-tier or high-quality productivity modules.

Once a machine has already reached the recipe's `maximum_productivity`, adding
more productivity modules no longer increases output. At that point, replacing
redundant productivity with speed increases throughput while keeping the same
effective productivity result.

This is especially relevant for recipes such as processing units / blue chips,
where research and machine bonuses can push the machine to the cap before every
module slot actually needs to be filled with productivity modules.

## Source basis

The implementation was based on official documentation first, then cross-checked
against community practice.

Official sources:

- Factorio Wiki, Productivity:
  [https://wiki.factorio.com/Productivity](https://wiki.factorio.com/Productivity)
- Factorio Wiki, Processing unit productivity research:
  [https://wiki.factorio.com/Processing_unit_productivity_%28research%29](https://wiki.factorio.com/Processing_unit_productivity_%28research%29)
- Factorio runtime API, `LuaRecipePrototype.maximum_productivity`:
  [https://lua-api.factorio.com/latest/classes/LuaRecipePrototype.html](https://lua-api.factorio.com/latest/classes/LuaRecipePrototype.html)
- Factorio runtime API, `LuaEntity`:
  [https://lua-api.factorio.com/latest/classes/LuaEntity.html](https://lua-api.factorio.com/latest/classes/LuaEntity.html)

Community evidence used to validate practical usage:

- Reddit discussion on practical productivity research caps:
  [https://www.reddit.com/r/factorio/comments/1sslzg5/what_is_practical_productivity_research_cap/](https://www.reddit.com/r/factorio/comments/1sslzg5/what_is_practical_productivity_research_cap/)

## Observed game rules that matter

### 1. Productivity is capped per recipe

Factorio recipes expose `maximum_productivity`, and the wiki states productivity
is limited to a maximum bonus. For the mod's optimization logic, the important
fact is not the global headline value by itself, but that the cap is a recipe
property and should be read from the actual recipe prototype used by the
machine.

Implication:

- the mod must use the current recipe's cap,
- not a hardcoded guess based on the machine type,
- and not a one-size-fits-all threshold.

### 2. More productivity above the cap is wasted

If the machine's baseline productivity plus installed module productivity
already meets the recipe cap, any extra productivity does not improve effective
output.

Implication:

- the right comparison is "current effective productivity versus recipe cap",
- not simply "is the machine using productivity modules".

### 3. Speed remains valuable after the cap is reached

Once productivity is capped, additional speed can still improve items per
second. In practical factory design, this is the point where players often swap
excess productivity modules for speed modules.

Implication:

- replacing redundant productivity with speed is a throughput optimization,
- but only after the machine still remains capped without that productivity.

### 4. Machine purpose must be preserved

A quality machine is not equivalent to a general throughput machine. If the
player inserted quality modules, that machine has a distinct purpose and should
not be repurposed by an auto-optimizer.

Implication:

- quality layouts are hard-locked and never converted away from quality,
- clear speed and efficiency layouts are also treated as intentional.

## Heuristics chosen for the addon

The mod uses a conservative intent-preserving heuristic rather than aggressively
rewriting every module layout.

### Quality objective

If any installed module is a quality module, the machine objective is `quality`.

Reason:

- quality is a distinct production goal,
- removing quality modules would change the purpose of the machine,
- the user explicitly requested that quality machines must not be altered in
  this way.

### Speed and efficiency objectives

If speed or efficiency modules are the clear majority in the machine, that
layout is treated as player intent and preserved.

Reason:

- players often use mixed layouts temporarily,
- majority-based detection avoids overreacting to one leftover module,
- ties fall through to recipe-based logic so the result is deterministic.

### Productivity objective

If the entity and recipe support productivity modules, the default objective is
`productivity`, especially for empty or productivity-oriented machines.

Reason:

- this matches the common late-game use case for assemblers and similar
  production entities,
- it allows the addon to optimize around the recipe cap where that optimization
  actually matters.

## Exact calculation used by the addon

For productivity-cap optimization, the addon calculates:

`baseline_productivity = force recipe productivity + machine built-in productivity`

Then it adds installed module productivity:

`total_productivity = baseline_productivity + installed module productivity`

The recipe cap is read from:

`recipe.prototype.maximum_productivity`

The current effective productivity is:

`min(total_productivity, recipe_cap)`

Redundant productivity is:

`max(0, total_productivity - recipe_cap)`

The implementation also cross-checks against `entity.productivity_bonus` when
available, and uses the safer baseline if mods or special machines expose
effects in a way that could otherwise be undercounted.

## Replacement rule

The addon does not replace all productivity above the cap in one broad step.
Instead, it checks each productivity-bearing slot conservatively.

A productivity module can be replaced by speed only if removing that module's
productivity still leaves the machine at or above the recipe cap.

Conceptually:

`baseline + installed_productivity - slot_productivity >= cap`

This matters because:

- multiple productivity modules may each contribute part of the amount required
  to stay capped,
- replacing too many at once would drop the machine below maximum productivity,
- quality tiers and legendary modules make slot values non-uniform.

## Why the algorithm is conservative

The addon is intentionally biased toward false negatives rather than false
positives.

That means it is preferable to leave a productivity module in place if the
calculation is uncertain, instead of replacing it and accidentally lowering the
machine's effective productivity.

This conservative approach was chosen because:

- the mod acts automatically,
- Factorio entities can have modded effects and restrictions,
- preserving production correctness is more important than squeezing every
  possible speed gain from ambiguous cases.

## Cases the optimization is meant to handle

### Case 1: Blue chip / processing unit production at endgame

A machine producing processing units may receive:

- productivity research,
- base productivity from an advanced machine,
- legendary productivity modules.

If the combined bonus already reaches the recipe cap, one or more productivity
modules become redundant. Replacing those redundant slots with legendary speed
modules improves throughput while preserving capped productivity.

### Case 2: Standard productivity machine below cap

If the machine is still below the recipe cap after all current bonuses are
added, no productivity module is considered redundant.

Result:

- productivity modules stay in place,
- no speed replacement is recommended.

### Case 3: Quality machine

If a machine contains quality modules, the machine objective is quality.

Result:

- the optimizer does not replace quality modules,
- the machine is not converted into a speed/productivity layout.

### Case 4: Explicit speed or efficiency machine

If the machine clearly uses speed or efficiency as its layout objective, the mod
preserves that objective.

Result:

- the optimizer does not force the machine into productivity logic merely
  because the recipe could accept productivity.

## Practical limitations

The optimizer can only make a safe recommendation from the information available
at runtime.

Important limits:

- It does not redefine the machine's purpose from external factory context.
- It does not try to infer a player's broader logistics plan.
- It respects entity and recipe module restrictions before issuing requests.
- In ambiguous mixed layouts, it favors preserving intent and avoiding harmful
  rewrites.

## Implementation notes

The current implementation is centered in:

- [optimization.lua](/C:/Users/silent/AppData/Roaming/Factorio/mods/AutoModuleUpgrade_1.0.0/optimization.lua)
- [building_logic.lua](/C:/Users/silent/AppData/Roaming/Factorio/mods/AutoModuleUpgrade_1.0.0/building_logic.lua)
- [module_lookups.lua](/C:/Users/silent/AppData/Roaming/Factorio/mods/AutoModuleUpgrade_1.0.0/module_lookups.lua)

Key behavioral guarantees:

- quality modules lock the machine to a quality objective,
- productivity is optimized only when the recipe and entity allow it,
- only redundant productivity is exchanged for speed,
- existing machine intent is preserved wherever the layout is clear.

## Summary

The addon's productivity-cap optimization exists to solve a specific late-game
problem: machines can hit the recipe productivity cap before all installed
productivity modules are actually needed. When that happens, keeping every
productivity module is suboptimal, and replacing only the redundant ones with
speed improves throughput.

The implementation follows official Factorio API and wiki rules, and preserves
quality and other explicit machine purposes instead of applying a generic
"highest number wins" module swap.
