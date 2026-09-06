# Tab targeting (select, no auto-attack)

M6c: left-click another living player selects them with a yellow ring. Selection
does not send `attack`. Escape clears. Ground click moves and keeps the
selection.

## Sub-features

- `select-on-left-click` — left-click remote living player sets selection chrome;
  no GAMELOG `attack` from that click alone.
- `ground-keeps-selection` — ground click issues `move_to`; selection persists.
- `escape-clears` — Escape (`ui_cancel`) clears selection after use-on cancel.
- `no-self-select` — left-click self does not select and does not attack.
- `right-click-attack` — right-click remote engages `attack` and selects (M6f).

## How to get to it (user POV)

- Left-click another player: yellow ring under their feet, no auto-attack.
- Click the ground: you walk; the ring stays.
- Press Escape: the ring goes away.
- Right-click them to engage basic attack (M6f).

## Driving it with headless tests

Preconditions:

- `DOCTOR OK` or a local Godot that can run `client/tests/run_tests.gd`.
- Run the interaction suite (bundled in the client test runner).

Markers:

- Interaction suite green with select / no-attack / Escape / right-click-attack
  assertions.
- Without the ring, `remote.is_selected()` fails; that is the chrome claim.

## Gotchas

- **Left-click is not attack.** Combat demos must right-click (or call
  `request_attack`) after M6c.
- **HP 0 refuses select.** Feed HP before asserting select-on-corpse refusals.
