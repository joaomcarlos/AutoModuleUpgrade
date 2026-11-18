# AGENTS.md

Guidance for AI agents working on this Factorio mod.

## Project Context

This is a Factorio 2.1 runtime mod. Treat gameplay logic as API-sensitive: many bugs come from using a plausible Lua shape that is not the shape Factorio actually accepts.

Core files:

- `control.lua`: entry point and require order.
- `config.lua`: constants and feature flags.
- `storage.lua`: persistent storage initialization helpers.
- `module_lookups.lua`: prototype/module/quality lookup helpers.
- `building_logic.lua`: building evaluation, module proxy plans, building quality upgrade deferral.
- `scan_system.lua`: scan scheduler, rate tracking, queue processing, deferred replacement handoff.
- `commands_events.lua`: lifecycle hooks, commands, GUI/event registration.
- `gui.lua`: scan status window.
- `data.lua`: shortcut/custom input prototypes.

## Factorio API Rules

Before changing API-facing behavior, verify the current Factorio docs instead of relying on memory. Use official docs first:

- Runtime docs: `https://lua-api.factorio.com/latest/`
- `LuaEntity`: `https://lua-api.factorio.com/latest/classes/LuaEntity.html`
- Storage/data lifecycle: `https://lua-api.factorio.com/latest/auxiliary/storage.html` and `https://lua-api.factorio.com/latest/auxiliary/data-lifecycle.html`
- Concepts such as item/entity IDs with quality: `https://lua-api.factorio.com/latest/concepts/`

Important API facts for this mod:

- Factorio mods use a modified Lua 5.2. Local `luac` may be Lua 5.1 and can reject valid Factorio code such as `goto`.
- `LuaEntity::order_upgrade{...}` returns a boolean. A successful `pcall` only means the call did not throw; it does not mean the entity was marked.
- `LuaEntity::to_be_upgraded()` and `LuaEntity::to_be_deconstructed()` should be checked before queuing new work for an entity.
- `storage` persists through save/load; ordinary globals do not.
- `storage` is not restored during top-level `control.lua` load. Recreate local references to storage tables in `script.on_load`, and do not write to `storage` in `on_load`.
- References to Factorio LuaObjects can be stored in `storage`, but always check `.valid` before using them after time has passed.
- Quality-aware IDs usually require explicit `{name = ..., quality = ...}` tables. Confirm the exact concept type before changing request, upgrade, or logistic calls.

## Mod Logic Invariants

Keep these behavior constraints intact unless the user explicitly asks to change them:

- `/amu-hover` is an applying command, not a pure check.
- Scan dry-runs are intentional. They compute a plan and reserve item availability without immediately creating proxies or upgrade orders.
- Queued work must not consume more logistic-network items than the reservation ledger believes are available.
- A building with an existing item-request-proxy should normally be skipped by scanners to avoid fighting bot work already in progress.
- A building already marked for upgrade should not receive new module proxy work.
- Deferred building quality upgrades must preserve their follow-up module plan across save/load.
- Rate-priority tracking may be global by `unit_number`, but queueing and reservations must stay surface-local.
- Do not destroy or replace an entity directly for quality upgrades unless intentionally changing the design. The current approach uses `order_upgrade` so bots do the replacement.

## Storage And Lifecycle

When adding persistent state:

1. Initialize it in `script.on_init`.
2. Preserve or migrate it in `script.on_configuration_changed`.
3. Add it to `ensure_storage()` if event handlers may need it.
4. If a local global points at a storage table, recreate that reference in `script.on_load`.
5. Do not mutate `storage` inside `script.on_load`.

When adding non-persistent runtime state, document why it is safe to lose on save/load.

## Validation Checklist

For every logic change:

- Read the surrounding code first and preserve existing patterns.
- Check official Factorio docs for any changed API call, event, prototype field, or concept type.
- Run `luac -p` on changed files when possible, but remember local Lua 5.1 cannot validate all Factorio Lua 5.2 syntax.
- If `scan_system.lua` contains `goto`, a Lua 5.1 parse failure near a label is not necessarily a Factorio syntax error.
- Review `git diff` before finishing.
- If you cannot run Factorio, say so and clearly distinguish static validation from in-game validation.

## Coding Style

- Keep changes small and local to the request.
- Prefer explicit helper functions over duplicating reservation/storage/proxy logic.
- Use ASCII unless an existing file already requires non-ASCII.
- Avoid broad refactors while fixing gameplay bugs.
- Do not change feature semantics such as `amu-hover` applying behavior unless requested.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. When the answer is under a Markdown heading, `graphify section "<heading>"` prints that section's text, so the .md need not be opened. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
