# Cast effect on target (M6h)

A successful cast plays a placeholder flash on the **target** entity. The cue is
the server's mana spend restatement (and refuse clears the pending cast with no
flash). Optimistic local VFX is forbidden.

## Sub-features

- `target-flash` — heal/fireball success parents `CastHitFx` under the target
  dummy (or avatar), not the caster unless self-targeted.
- `server-tied` — flash only after own `mana` drops while a cast is pending.
- `refuse-silent` — `error` with `re:"cast"` drops the pending cast; no flash.

## How to get to it (user POV)

- Select the green dummy, press hotbar 1 (heal): green flash on the dummy.
- Select the red dummy, press hotbar 2 (fireball): red flash on the dummy.
- A refused cast (out of range, wrong target, empty mana) shows no success flash.

## Driving it with verify-marque

Preconditions:

- `DOCTOR OK` or a local Godot that can run headless suites and the live demo.
- Headless: `cast effect` scene suite in `client/tests/run_tests.gd` (mana confirm
  on target id; refuse silent).
- Live: `powershell -ExecutionPolicy Bypass -File scripts/dummy_cast_demo.ps1`.
  Marker: `DUMMY CAST DEMO OK` on the last line; exit 0. Requires `DEMO castfx`
  lines for heal and fireball plus GAMELOG `cast_effect`.

Evidence lands in `-OutDir` (default `$env:TEMP\marque-dummy-cast`): client
stdout/stderr and `server.stdout.ndjson`.

## Gotchas

- **Mana, not HP.** Heal on a full-HP dummy still flashes because mana spent;
  binding only to `hp` would miss that case and would also flash on melee hits.
- **Flash is short-lived.** Assert `CastHitFx` as soon as `cast_effect_played`
  fires; waiting on later HP restatements can outlive the tween.
