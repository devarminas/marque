# 0014. Weapon data and white damage

## Status

Accepted (Combat MVP).

## Context

Melee damage was a flat constant. Combat MVP moved weapon definition to JSON so tuning (period, damage range) does not require a server rebuild.

## Decision

1. **`shared/weapons.json`.** Each weapon entry carries:
   - `id` — catalog key (e.g. `sword`, `imp_claw`).
   - `attack_period_ticks` — minimum ticks between white-damage swings.
   - `damage_min` / `damage_max` — inclusive range before attributes.
2. **White damage roll.** A swing rolls uniformly in `[damage_min, damage_max]`, then adds the attacker's `AP` (`(STR - 10) / 2`), then checks `CritChance` (`max(0, DEX - 10)` percent) to double the pre-armor amount. Finally the target's `Armor` (`max(0, (DEX - 10) / 2)`) is subtracted with a floor of 1.
3. **Fallback.** If a weapon id is missing from the catalog the server falls back to `unarmed` (`attack_period_ticks: 50`, `damage_min: 3`, `damage_max: 5`).
4. **NPC weapons.** Imps receive their weapon id from the archetype JSON (ADR-0017). Dummies and quest givers use `unarmed`.

## Consequences

- `server/internal/weapondef/weapondef.go` parses and validates the file.
- `server/internal/game/combat.go` owns `rollWhiteDamage`.
- Changing a weapon's period or damage no longer touches Go code.

## Non-goals

- Projectile weapons or ranged attack mechanics.
- Weapon stats beyond period and damage range.
- Durability or item scaling.
