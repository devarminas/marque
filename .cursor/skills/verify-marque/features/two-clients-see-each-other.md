# Two clients see each other walk

The M0 milestone: two players in one world, and when one walks, the other watches it
happen — in both directions. Each client renders the other's movement from the server's
`pose` stream. Players steer with wish `move` samples; player `path` / `move_to` are
retired.

## Sub-features

- `see-walk-a` — client b watches player a's whole walk.
- `see-walk-b` — client a watches player b's, in the other phase.
- `see-still-control` — the watcher's camera is provably still, so what changed on
  its screen can only be the other body.
- `see-distinct-walks` — the two walks end far enough apart that neither can be
  mistaken for the other.
- `see-server-moved` — each walker logged non-zero GAMELOG `move` wishes, and the
  watcher's `DEMO pos` for that walker displaced (remotes follow server pose only).
- `see-layers-agree` — both clients' shot-4 `DEMO pos` for the phase-1 walker agree
  within 0.05 (server pose on both sides).
- `see-ground-click-ignored` — bare-ground left click does not start locomotion
  (`DEMO groundclick_ignored`).

The watcher-displacement check is load-bearing. A local predictor can move the walking
client's own avatar without the server; the other client only moves that body when it
receives server poses. Player `path_assigned` / `arrived` are not the proof channel.

Minimum evidence:

| Claim | GAMELOG | DEMO | Pixel |
|---|---|---|---|
| Walker moved | non-zero `move` wish; **no** player `path_assigned` / `move_to` | walker `DEMO pos` displacement ≥2.0; `DEMO walkto` / `DEMO move_displacement` | walker top-quarter fails quiet band |
| Watcher saw it | (same `move`) | watcher `DEMO pos` for walker id | watcher frame-pair diff in [0.2%, 10%] |
| Camera still | n/a | n/a | watcher top quarter quiet (<0.5% px, Δ≤2) |
| Layers agree | n/a (pose is wire, not GAMELOG) | both clients' shot-4 `DEMO pos` within 0.05 | optional |

## How to get to it (user POV)

- Two people launch clients against one server; one holds a direction while the
  other stands still, then they swap. Left-click on bare ground does nothing.

## Driving it with scripts/two_client_demo.ps1

Default driver rung: **live windowed demo** (pixels + two-client phases). Go
proves wish integration and pose broadcast; it cannot prove the still-camera band.

Preconditions:

- `DOCTOR OK`; a desktop session; nothing else running against the same checkout's
  `client/.godot`.

- **Run the canonical scenario.** `powershell -ExecutionPolicy Bypass -File
  scripts/two_client_demo.ps1`. Marker: `TWO CLIENT DEMO OK`, and it must be the
  last line — read the tail, do not grep. Its assertions are baked in.

  Client layer: per-direction displacement over 2.0 units, destinations over 3.0
  units apart, the watcher's frame-pair difference inside [0.2%, 10%], the watcher's
  top quarter quiet (under 0.5% of its pixels differing, none by more than 2 of 255),
  the walker's top quarter failing that same test, and the walker's diff at least 8x
  the watcher's.

  Server layer, per player id resolved from that client's `DEMO joined` line: a
  `client_connected`; for a client that was given a phase walk, at least one
  non-zero GAMELOG `move` wish, `DEMO groundclick_ignored`, `DEMO walkto`, and
  `DEMO move_displacement`. Zero player `path_assigned` and zero `move_to` for the
  whole run. Layer agree: both clients' shot-4 poses for the phase-1 walker within
  0.05.

- **The evidence survives the run.** Everything lands in `-OutDir`, default
  `$env:TEMP\marque-two-client`: the eight PNGs, `client-a.stdout.log` and
  `client-b.stdout.log` with their stderr companions, and `server.stdout.ndjson`,
  which is the GAMELOG the server-layer assertions read. The directory is emptied
  at the start of each run and refused outright if something else wrote it.
- **Variant scenarios.** For any other choreography (different clicks, a
  never-walking watcher), use `run.ps1 -ClickA .. -ClickB ..` and re-state the
  applicable assertions yourself against its evidence directory; the demo's
  thresholds above are the calibrated reference. The still-camera window exists
  only in the phase a client does not click in.

## Gotchas

- **Both layers or it is half-proven.** Own-avatar `DEMO pos` can include prediction;
  the watcher's `DEMO pos` for the walker is server pose. Movement claims need both
  plus GAMELOG `move`.
- **Reviewer evidence:** screenshot (or 1–2 PNGs copied from `-OutDir` before the
  next run empties it). Named-pixel still-camera remains the only pixel *proof*.
  Attach with `review-evidence.sh`; presence is not `TWO CLIENT DEMO OK`.
- **System.Drawing / GDI+ is Windows-centric.** `Compare-Frames` needs that stack.
  On Linux, `Add-Type System.Drawing` can succeed while `Bitmap.FromFile` still
  native-aborts and kills the harness before DEMO/GAMELOG asserts. The harness
  therefore skips the entire pixel path off Windows (and still catches Drawing
  failures on Windows), then asserts DEMO/GAMELOG wish+pose (fail-closed on
  player `path_assigned` / `move_to`).
- **The sky-band flake waiver is retired (ARM-183).** The still-camera control no
  longer demands byte-exactness, so the GPU noise that used to trip it is inside the
  tolerance. A top-quarter failure is a finding, not something to rerun away. See
  *The still-camera control* in `../SKILL.md` for the measured margin.
- **A starved desktop fails every client-side assertion at once, and the failure
  looks like a frozen server.** Each capture waits 15 rendered frames. Measured on
  this machine under load, one capture took about 4.4 seconds, which is longer than
  the walk window it is supposed to bracket, so both frames of a phase showed
  the walker already far along and every displacement read wrong. The symptom is
  all six of "moved only 0 units" and "did not visibly move" together, with a
  healthy GAMELOG underneath.

  Diagnose it from the server's own clock rather than guessing: the two walkers'
  first non-zero `move` wishes should be about one phase gap apart. Cross-check with
  a single client, which should boot and capture in a couple of seconds:
  `godot --path client -- --screenshot`.

  This is an environment condition, not a defect in either binary. Free the display
  and rerun. The occlusion story is untested; the frame rate is what was measured.
- The phases exist so exactly one player moves per capture window; simultaneous
  walks have no still-camera control and prove much less.
- The moving-camera diff fraction is ground-texture dependent (measured 24%–52% for
  near-identical walks on the old checker; re-check the ratio on `world_map` grass if
  the still/moving control fails); assert the ratio against the still figure, not an
  absolute.
- Each client holds its connection ~2s after its last capture so the other's final
  frame still contains two bodies; a variant that quits early despawns a body out of
  the other's proof.
