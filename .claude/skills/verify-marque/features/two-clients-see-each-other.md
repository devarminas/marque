# Two clients see each other walk

The M0 milestone: two players in one world, and when one walks, the other watches it
happen — in both directions. Each client renders the other's movement purely from
the paths the server broadcast.

## Sub-features

- `see-walk-a` — client b watches player a's whole walk.
- `see-walk-b` — client a watches player b's, in the other phase.
- `see-still-control` — the watcher's camera is provably still, so what changed on
  its screen can only be the other body.
- `see-distinct-walks` — the two walks end far enough apart that neither can be
  mistaken for the other.
- `see-server-moved` — the server's tick loop actually advanced each walker to the
  end of the path it assigned, and its event log records where.
- `see-layers-agree` — the point the server says the phase-1 walker stopped at is
  the point both clients drew it at.

The last two are not decoration. Every client-side sub-feature above it is satisfied
by a server that assigns paths and then never moves anybody, because each client
interpolates the polyline it was handed. That sabotage was run against this exact
scenario and the demo passed it, with displacements byte-identical to a healthy run,
until `see-server-moved` existed.

## How to get to it (user POV)

- Two people launch clients against one server; one clicks the ground while the
  other stands still, then they swap.

## Driving it with scripts/two_client_demo.ps1

Preconditions:

- `DOCTOR OK`; a desktop session; nothing else running against the same checkout's
  `client/.godot`.

- **Run the canonical scenario.** `powershell -ExecutionPolicy Bypass -File
  scripts/two_client_demo.ps1`. Marker: `TWO CLIENT DEMO OK`, and it must be the
  last line — read the tail, do not grep. Its assertions are baked in.

  Client layer: per-direction displacement over 2.0 units, destinations over 3.0
  units apart, the watcher's frame-pair difference inside [0.2%, 10%], the watcher's
  top-quarter sky band byte-identical, the walker's not, and the walker's diff at
  least 8x the watcher's.

  Server layer, per player id resolved from that client's `DEMO joined` line: a
  `client_connected`; for a client that was given a click, a `move_to`, a
  `path_assigned` spanning at least 2.0 units, and an `arrived` **after** that
  path's `start_tick` whose coordinates match its endpoint. Then the two layers
  tied together: the phase-1 walker's `arrived` point is within 0.05 units of where
  both clients drew that body in shot 4.

  **The arrival's tick is checked too, not just its coordinates.** A tick loop that
  crossed the whole polyline in one step emits an arrival at the right place and was
  passing this demo until M1j. Crossing that span takes `ceil(span / (walk_speed *
  tick_ms))` ticks, within two, measured against the `walk_speed` and `tick_ms` the
  run's own `server_started` reports rather than against constants in the script.
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

- **Known flake:** the still-camera control asserts byte-exactness over the top
  quarter of a GPU-rendered frame, and one flip was observed on a fully static frame
  across eighteen measured windows — render nondeterminism. It fails safe, never a
  false pass. If the demo fails on **only** "the background is not a control" with a
  still fraction near zero, rerun before investigating.
- **A starved desktop fails every client-side assertion at once, and the failure
  looks like a frozen server.** Each capture waits 15 rendered frames. Measured on
  this machine under load, one capture took about 4.4 seconds, which is longer than
  the 2.07-second walk it is supposed to bracket, so both frames of a phase showed
  the walker already arrived and every displacement read exactly 0. The symptom is
  all six of "moved only 0 units" and "did not visibly move" together, with a
  healthy GAMELOG underneath.

  Diagnose it from the server's own clock rather than guessing: the two `move_to`
  events should be about 3.4 seconds — 23 ticks — apart, and they were 81 to 83
  ticks apart. Cross-check with a single client, which should boot and capture in
  a couple of seconds: `godot --path client -- --screenshot` took 8.2s.

  This is an environment condition, not a defect in either binary. Free the display
  and rerun. The occlusion story is untested; the frame rate is what was measured.
- The phases exist so exactly one player moves per capture window; simultaneous
  walks have no still-camera control and prove much less.
- The moving-camera diff fraction is checker-phase dependent (measured 24%–52% for
  near-identical walks); assert the ratio against the still figure, not an absolute.
- Each client holds its connection ~2s after its last capture so the other's final
  frame still contains two bodies; a variant that quits early despawns a body out of
  the other's proof.
