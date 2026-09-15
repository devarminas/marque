# Admin give class kits

Class-kit wardrobe for playtest and verify harnesses goes through the admin
bus: start marqued with `-admin` (or `-admin-player`), connect, and send
`{"admin":{"line":"/give <kind>"}}` for each sets-derived wearable. Ground
grid seeding via `-seed-class-kits` is retired. `DefaultJoinKit` stays empty.
Windowed demos that need a class wardrobe (craft/cast, mage dummy/tab combat,
enemy quest) start with `-admin` and `/give` via `demo_admin_give.gd` — do not
rebuild `-join-kit` forests. Thin single-kind `-join-kit` remains only where a
demo still uses it (equip sword, quest sticks). The thin shared probe is
`server/internal/wsprobe` (see
[wsprobe-admin-move-to.md](./wsprobe-admin-move-to.md)); `admin_give_kits`
wraps it for the class-kit loop.

## Sub-features

- `admin-give-class-kits-boot` — marqued with `-admin`; `server_started` carries
  `admin: true`, empty `join_kit`, and no `seed_class_kits` /
  `class_kit_seeds` fields.
- `admin-give-class-kits-kinds` — harness `/give`s every unique wearable kind
  from `shared/sets.json` (same source as Wearables); each gets `admin_reply`
  `ok:` and a GAMELOG `admin` event with `cmd=give` `result=ok`.
- `admin-give-class-kits-retired-flag` — `-seed-class-kits` hard-errors and
  points at `-admin` + `/give`.

## How to get to it (user POV)

- Launch marqued with `-admin`. Open the backtick admin console (or any client
  that sends admin intents). `/give plate_helm`, `/give sword`, and the rest of
  a set's kinds. Equip to activate the class. Repeated `-item` ground placement
  remains for map fixtures only; it is not the class-kit wardrobe path.

## Driving it with scripts/admin_give_class_kits_demo.ps1

Preconditions:

- `DOCTOR OK` is not required; this harness is server + websocket only.
- Run `powershell -ExecutionPolicy Bypass -File scripts/admin_give_class_kits_demo.ps1`.
- Marker: `ADMIN GIVE CLASS KITS DEMO OK` on the **last line** of stdout. Exit
  code must also be 0.

The script builds marqued and `admin_give_kits`, asserts `-seed-class-kits`
hard-errors with a `/give` pointer, starts marqued with `-admin` on a free
port, connects the harness over `/ws`, `/give`s every sets-derived wearable
kind, and asserts GAMELOG admin ok lines plus an empty join kit.

Evidence lands in `-OutDir`, default `$env:TEMP\marque-admin-give-class-kits`:
`server.stdout.ndjson`, `server.stderr.log`, `harness.stdout.log`,
`harness.stderr.log`, `retired-flag.stdout.log`, `retired-flag.stderr.log`.

## Gotchas

- **Empty join kit.** Class gear is not bag-seeded at join. Proof uses admin
  `/give`, not a patched `DefaultJoinKit`.
- **Sets are the source.** Kinds come from Wearables (`SetIDs` / slots + tools),
  not from inventing kinds off class Requires alone.
- **ACL.** Without `-admin` / `-admin-player`, `/give` returns `deny:
  unauthorized` and grants nothing.
