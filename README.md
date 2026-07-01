# Auto Module Upgrade

Auto Module Upgrade manages machine modules and entity quality through construction requests. It discovers surfaces, qualities, module tiers, recipes, and modded entities at runtime.

Developer-facing research for the productivity-cap optimizer is documented in
[PRODUCTIVITY_OPTIMIZATION_RESEARCH.md](/C:/Users/silent/AppData/Roaming/Factorio/mods/AutoModuleUpgrade_1.0.0/PRODUCTIVITY_OPTIMIZATION_RESEARCH.md).

## Objective detection

- Any machine containing quality modules is treated as a quality machine. Those modules are never replaced by speed, productivity, or efficiency modules.
- Explicit speed and efficiency layouts are preserved as player intent.
- Empty machines whose entity and recipe rules accept productivity default to a productivity objective; recipe-less drills and labs retain the compatible productivity default.
- Productivity layouts keep enough module productivity to reach `recipe.maximum_productivity`. Only productivity that can be removed while keeping the cap is replaced with the best available speed module.
- Module and recipe restrictions are checked before a request is created.

The productivity calculation includes force recipe productivity, the machine's built-in productivity, its installed modules, and the recipe-specific cap. The algorithm is conservative when other mods add effects it cannot separate safely.

The longer design rationale, source links, and case analysis for this behavior
are in `PRODUCTIVITY_OPTIMIZATION_RESEARCH.md`.

## Entity quality upgrades

- Auto quality upgrades also cover selected non-module entities, including accumulators, radars, roboports, steam turbines, heating towers, nuclear reactors, heat exchangers, solar panels, cargo bays, pumpjacks, pumps, offshore pumps, substations, medium electric poles, storage chests, and rocket silos.
- Inserters keep their current inserter type and only upgrade quality, so a fast inserter stays a fast inserter and upgrades toward its legendary version.
- Recyclers and beacons are also eligible for building quality upgrades in addition to their module logic.

## Controls

- `Shift + U`: toggle the scan window.
- `Alt + U`: get the area management tool.
- Area tool left-drag: include and schedule machines.
- `Shift` + left-drag: exclude machines.
- Right-drag: preview detected objectives and productivity caps.
- `Shift` + right-drag: include excluded machines again.
- Scan window search button: left-click inspects changes; right-click rescans the surface.
- Scan window camera button: left-click toggles camera follow; right-click pauses or resumes the surface.

## Commands

- `/amu-scans`: toggle the scan window.
- `/amu-tool`: get the area tool.
- `/amu-preview`: explain the selected machine's detected objective.
- `/amu-stats`: show registry, queue, and pending-upgrade counts.
- `/amu-test`: schedule an immediate scan.
- `/amu-hover`: immediately apply a valid recommendation to the selected machine.

## Performance and compatibility

The first scan indexes existing machines incrementally. Later scans use a persistent entity registry maintained by build and removal events. Research completion, cargo deliveries, runtime setting changes, and player-requested rescans trigger targeted re-evaluation.

Existing item-request proxies are never destroyed. Plans are validated against current module slots immediately before application, so manual or third-party changes win.
