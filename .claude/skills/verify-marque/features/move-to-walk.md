# Move-to walk — RETIRED (ARM-239)

Player polyline locomotion is retired. Players move only via wish samples + server
pose. There is no production `move_to` → player `path` → `polyline_walker` pipeline.

**Do not drive this recipe.** Graduated action-movement e2e lives under
[polish/](./polish/README.md) (ARM-241): per-ADR recipes and
[props/player-character.md](./polish/props/player-character.md) for mock
presentation.

See also: [wasd-move](./wasd-move.md) for the live wish+pose movement model, and
ADR 0001 / 0003 for the retirement and NPC path exception.
