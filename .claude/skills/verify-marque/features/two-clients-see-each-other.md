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

## How to get to it (user POV)

- Two people launch clients against one server; one clicks the ground while the
  other stands still, then they swap.

## Driving it with scripts/two_client_demo.ps1

Preconditions:

- `DOCTOR OK`; a desktop session; nothing else running against the same checkout's
  `client/.godot`.

- **Run the canonical scenario.** `powershell -ExecutionPolicy Bypass -File
  scripts/two_client_demo.ps1`. Marker: `TWO CLIENT DEMO OK`. Its assertions are
  baked in: per-direction displacement over 2.0 units, destinations over 3.0 units
  apart, the watcher's frame-pair difference inside [0.2%, 10%], the watcher's
  top-quarter sky band byte-identical, the walker's not, and the walker's diff at
  least 8x the watcher's.
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
- The phases exist so exactly one player moves per capture window; simultaneous
  walks have no still-camera control and prove much less.
- The moving-camera diff fraction is checker-phase dependent (measured 24%–52% for
  near-identical walks); assert the ratio against the still figure, not an absolute.
- Each client holds its connection ~2s after its last capture so the other's final
  frame still contains two bodies; a variant that quits early despawns a body out of
  the other's proof.
