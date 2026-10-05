# 0019. Client reactions to confirmed actions

## Status

Proposed on 2026-10-02. This records the distinction requested during Net core v1 and recommends reacting to confirmed actions. It does not claim that the current client implements these reactions.

## Context

[ADR 0018](0018-wire-format-and-transport.md) allows ordered inventory and quest events to publish before related world visuals catch up. A successful pickup can update the bag while the cached ground item remains visible. Waiting for the ground update adds delay after the server has already approved the action.

Two client reactions have different failure cases.

| Reaction | When the sword disappears | If the server refuses |
| --- | --- | --- |
| React to confirmation | After the core publishes the server's successful pickup event | The sword has not disappeared because of this request |
| Predict success | Immediately when the player clicks | Restore the sword and explain the refusal |

Predicting success removes the wait for a server response. Contested loot, range checks and full bags can then make an item vanish and return. Crowded MMO areas make those refusals ordinary gameplay.

## Proposed decision

Use reactions to server-confirmed actions for pickup. Clicking can show a pending indicator. Hide the sword when the core publishes a successful pickup confirmation, even if the ground-state update has not arrived. A refusal clears the pending indicator and shows the reason.

The confirmation must identify the exact ground item by its full handle, including generation. It must correlate with the pickup intent and carry the producing tick and reliable event identity. An inventory change alone cannot identify the sword. The inventory might have changed because of crafting, a quest reward or another pickup.

The core publishes the confirmation with the ordered owner-event prefix under ADR 0018. The visual reaction starts from that published event. Raw packet receipt does not bypass atomic publication or update the bag independently.

The visual layer hides the confirmed item and disables its interaction target. It leaves the server-owned world table unchanged. The server still decides whether every action succeeds. The visual contract carries the confirmed item handle so game logic never reaches into the visual tree.

Keep the hidden-item record until authoritative state removes that handle, replaces its generation or supplies a completed current full-state reset. A reset replaces the record according to current server state. A later server fact can change the scene without undoing the successful pickup transaction. Hiding one generation must never hide a new item that reuses its index.

Duplicate confirmations have no extra effect. Network reconnect preserves confirmed reactions until replay and a completed reset resolve them. Bound retained records and use explicit reset or connection recovery when the bound is exhausted. A timer must not bring back an item solely because its ground update is late.

Other players keep following their own server updates. An owner's pickup confirmation does not give that client authority to change another client's view.

## Consequences

The player sees the bag change and the sword disappear together after confirmation. The ground update may arrive later. This avoids a rollback for a refused pickup, but still waits for the server response.

Predicting success before confirmation remains a separate product decision. It needs refusal rollback, contested-loot tests and a policy for lost replies. Movement prediction remains governed by ADR 0001.

The current pickup handler sends an inventory restatement and a ground removal. It does not send a correlated successful pickup event with a full item handle. Implementing this ADR therefore needs an explicit confirmation event, a core-to-visual reaction and bounded retained records. An inventory delta must not stand in for the missing confirmation.

## Verification requirements

- Successful pickup confirmation hides only the named item generation before the delayed ground removal arrives.
- Refused pickup clears pending feedback without a hide-and-restore cycle.
- An unrelated inventory update does not hide a clicked item.
- Duplicate delivery and reconnect replay do not repeat the reaction.
- Handle reuse remains visible, and completed reset resolves retained records from current server state.
- The visual reaction never writes the authoritative world table or grants an item to the bag.
- Crowded-area tests cover two players clicking the same item, full bags and an out-of-range request.

## Non-goals

This ADR does not approve hide-on-click pickup prediction, speculative inventory changes or a client-owned loot transaction. It does not change ADR 0018's publication policy or the server's authority.
