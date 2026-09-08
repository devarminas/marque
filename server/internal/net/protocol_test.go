package net_test

import (
	"encoding/json"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestEncodeProducesKeyAsTagEnvelope(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		msg  mnet.ServerMessage
		want string
	}{
		{
			name: "welcome",
			msg: mnet.Welcome{
				You:     1,
				Session: "9f2c1ab7d0e4485fa6c3b81d27e05934",
				LastSeq: 7,
				TickMS:  150,
				Tick:    142,
				Players: []mnet.PlayerState{
					{ID: 1, X: 0, Z: 0, HP: 100, MaxHP: 100, Mana: 100, MaxMana: 100},
					{ID: 2, X: 5, Z: 5, HP: 70, MaxHP: 100, Mana: 40, MaxMana: 100},
				},
				Items: []mnet.ItemState{{ID: 7, Kind: "acorn", X: 3, Z: -2}},
				Nodes: []mnet.NodeState{},
				Npcs:  []mnet.NpcState{},
			},
			want: `{"welcome":{"you":1,"session":"9f2c1ab7d0e4485fa6c3b81d27e05934","last_seq":7,"tick_ms":150,"tick":142,"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100,"mana":100,"max_mana":100},{"id":2,"x":5,"z":5,"hp":70,"max_hp":100,"mana":40,"max_mana":100}],"items":[{"id":7,"kind":"acorn","x":3,"z":-2}],"nodes":[],"npcs":[]}}`,
		},
		{
			name: "welcome with an empty world",
			msg: mnet.Welcome{
				You:     1,
				Session: "0123456789abcdef0123456789abcdef",
				TickMS:  150,
				Tick:    0,
				Players: []mnet.PlayerState{},
				Items:   []mnet.ItemState{},
				Nodes:   []mnet.NodeState{},
				Npcs:    []mnet.NpcState{},
			},
			want: `{"welcome":{"you":1,"session":"0123456789abcdef0123456789abcdef","last_seq":0,"tick_ms":150,"tick":0,"players":[],"items":[],"nodes":[],"npcs":[]}}`,
		},
		{
			name: "node_state",
			msg:  mnet.NodeUpdate{ID: 1, Kind: "tree", X: 5, Z: 0, State: mnet.NodeDepleted},
			want: `{"node_state":{"id":1,"kind":"tree","x":5,"z":0,"state":"depleted"}}`,
		},
		{
			name: "item_spawn",
			msg:  mnet.ItemSpawn{ID: 7, Kind: "acorn", X: 3, Z: -2},
			want: `{"item_spawn":{"id":7,"kind":"acorn","x":3,"z":-2}}`,
		},
		{
			name: "item_despawn",
			msg:  mnet.ItemDespawn{ID: 7},
			want: `{"item_despawn":{"id":7}}`,
		},
		{
			name: "inventory",
			msg:  mnet.Inventory{Size: 28, Slots: []mnet.InventorySlot{{Slot: 1, Kind: "acorn"}}},
			want: `{"inventory":{"size":28,"slots":[{"slot":1,"kind":"acorn"}]}}`,
		},
		{
			name: "empty inventory",
			msg:  mnet.Inventory{Size: 28, Slots: []mnet.InventorySlot{}},
			want: `{"inventory":{"size":28,"slots":[]}}`,
		},
		{
			name: "equipment",
			msg: mnet.Equipment{
				Worn:  []mnet.EquipSlot{"helmet", "left hand", "chest", "right hand", "feet", "trousers"},
				Slots: []mnet.EquipmentSlot{{Slot: "right hand", Kind: "sword"}},
			},
			want: `{"equipment":{"worn":["helmet","left hand","chest","right hand","feet","trousers"],"slots":[{"slot":"right hand","kind":"sword"}]}}`,
		},
		{
			name: "empty equipment",
			msg: mnet.Equipment{
				Worn:  []mnet.EquipSlot{"helmet", "left hand", "chest", "right hand", "feet", "trousers"},
				Slots: []mnet.EquipmentSlot{},
			},
			want: `{"equipment":{"worn":["helmet","left hand","chest","right hand","feet","trousers"],"slots":[]}}`,
		},
		{
			name: "spawn",
			msg:  mnet.Spawn{ID: 2, X: 0, Z: 0, HP: 100, MaxHP: 100, Mana: 100, MaxMana: 100},
			want: `{"spawn":{"id":2,"x":0,"z":0,"hp":100,"max_hp":100,"mana":100,"max_mana":100}}`,
		},
		{
			name: "hp",
			msg:  mnet.HP{ID: 2, HP: 90, MaxHP: 100},
			want: `{"hp":{"id":2,"hp":90,"max_hp":100}}`,
		},
		{
			name: "mana",
			msg:  mnet.Mana{ID: 2, Mana: 55, MaxMana: 100},
			want: `{"mana":{"id":2,"mana":55,"max_mana":100}}`,
		},
		{
			name: "despawn",
			msg:  mnet.Despawn{ID: 2},
			want: `{"despawn":{"id":2}}`,
		},
		{
			name: "path",
			msg: mnet.Path{
				ID:        1,
				StartTick: 142,
				Points:    []mnet.Point{mnet.Pt(10, 4), mnet.Pt(42.3, 17.8)},
				Speed:     3,
			},
			want: `{"path":{"id":1,"start_tick":142,"points":[[10,4],[42.3,17.8]],"speed":3}}`,
		},
		{
			name: "error",
			msg:  mnet.Error{Re: "move_to", Msg: "out of bounds"},
			want: `{"error":{"re":"move_to","msg":"out of bounds"}}`,
		},
		{
			name: "dialog",
			msg: mnet.Dialog{
				NPC:   1000003,
				Lines: []string{"Will you accept Bring a Stick?"},
				Options: []mnet.DialogOption{
					{ID: mnet.OptionAcceptQuest},
					{ID: mnet.OptionStopTalking},
				},
			},
			want: `{"dialog":{"npc":1000003,"lines":["Will you accept Bring a Stick?"],"options":[{"id":"accept_quest"},{"id":"stop_talking"}]}}`,
		},
		{
			name: "dialog closed",
			msg:  mnet.Dialog{NPC: 1000003, Lines: []string{}, Options: []mnet.DialogOption{}},
			want: `{"dialog":{"npc":1000003,"lines":[],"options":[]}}`,
		},
		{
			name: "quest_log",
			msg: mnet.QuestLog{
				Quests: []mnet.QuestLogEntry{{
					ID:        "bring_a_stick",
					Title:     "Bring a Stick",
					Objective: "Deliver 1 stick",
					Status:    "active",
				}},
			},
			want: `{"quest_log":{"quests":[{"id":"bring_a_stick","title":"Bring a Stick","objective":"Deliver 1 stick","status":"active"}]}}`,
		},
		{
			name: "empty quest_log",
			msg:  mnet.QuestLog{Quests: []mnet.QuestLogEntry{}},
			want: `{"quest_log":{"quests":[]}}`,
		},
		{
			name: "error with nothing to attribute it to",
			msg:  mnet.Error{Msg: "text frames only"},
			want: `{"error":{"msg":"text frames only"}}`,
		},
		{
			name: "tick",
			msg:  mnet.Tick{T: 10},
			want: `{"tick":{"t":10}}`,
		},
		{
			name: "welcome naming the heartbeat period",
			msg: mnet.Welcome{
				You:            1,
				Session:        "0123456789abcdef0123456789abcdef",
				TickMS:         150,
				Tick:           0,
				HeartbeatTicks: 10,
				Players:        []mnet.PlayerState{},
				Items:          []mnet.ItemState{},
				Nodes:          []mnet.NodeState{},
				Npcs:           []mnet.NpcState{},
			},
			want: `{"welcome":{"you":1,"session":"0123456789abcdef0123456789abcdef","last_seq":0,"tick_ms":150,"tick":0,"heartbeat_ticks":10,"players":[],"items":[],"nodes":[],"npcs":[]}}`,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := mnet.Encode(tc.msg)
			if err != nil {
				t.Fatalf("Encode(%T) failed: %v", tc.msg, err)
			}
			if string(got) != tc.want {
				t.Fatalf("Encode(%T)\n got: %s\nwant: %s", tc.msg, got, tc.want)
			}
			assertExactlyOneKey(t, got)
		})
	}
}

func assertExactlyOneKey(t *testing.T, frame []byte) {
	t.Helper()
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(frame, &keys); err != nil {
		t.Fatalf("frame is not a JSON object: %s: %v", frame, err)
	}
	if len(keys) != 1 {
		t.Fatalf("frame has %d keys, want exactly 1: %s", len(keys), frame)
	}
}

func TestDecodeMoveTo(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name    string
		frame   string
		wantSeq mnet.Seq
	}{
		{"plain", `{"move_to":{"x":42.3,"z":17.8}}`, 0},
		{"with a seq", `{"move_to":{"x":42.3,"z":17.8,"seq":9}}`, 9},
		{"with the largest seq an int64 holds", `{"move_to":{"x":42.3,"z":17.8,"seq":9223372036854775807}}`, 9223372036854775807},
		{"with an explicitly null seq", `{"move_to":{"x":42.3,"z":17.8,"seq":null}}`, 0},
		{"with a field nobody has invented yet", `{"move_to":{"x":42.3,"z":17.8,"whatever":true}}`, 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, seq, err := mnet.Decode([]byte(tc.frame))
			if err != nil {
				t.Fatalf("Decode(%s) failed: %v", tc.frame, err)
			}
			got, ok := msg.(mnet.MoveTo)
			if !ok {
				t.Fatalf("Decode returned %T, want MoveTo", msg)
			}
			if got.X != 42.3 || got.Z != 17.8 {
				t.Fatalf("Decode gave %+v, want {X:42.3 Z:17.8}", got)
			}
			if seq != tc.wantSeq {
				t.Fatalf("Decode(%s) gave seq %d, want %d", tc.frame, seq, tc.wantSeq)
			}
		})
	}
}

func TestDecodeMove(t *testing.T) {
	t.Parallel()

	msg, seq, err := mnet.Decode([]byte(`{"move":{"dx":0.5,"dz":-0.5,"seq":3}}`))
	if err != nil {
		t.Fatalf("Decode failed: %v", err)
	}
	got, ok := msg.(mnet.Move)
	if !ok {
		t.Fatalf("Decode returned %T, want Move", msg)
	}
	if got.DX != 0.5 || got.DZ != -0.5 {
		t.Fatalf("Decode gave %+v", got)
	}
	if seq != 3 {
		t.Fatalf("seq=%d, want 3", seq)
	}
}

func TestDecodeNamesEveryMessageAfterItsWireKey(t *testing.T) {
	t.Parallel()

	cases := []struct{ key, frame string }{
		{mnet.MsgMoveTo, `{"move_to":{"x":1,"z":2}}`},
		{mnet.MsgMove, `{"move":{"dx":0,"dz":-1}}`},
		{mnet.MsgPickup, `{"pickup":{"item":7}}`},
		{mnet.MsgDrop, `{"drop":{"slot":3}}`},
		{mnet.MsgEquip, `{"equip":{"slot":3}}`},
		{mnet.MsgUnequip, `{"unequip":{"worn":"right hand"}}`},
		{mnet.MsgGather, `{"gather":{"node":1}}`},
		{mnet.MsgUse, `{"use":{"slot":3,"on":3}}`},
		{mnet.MsgAttack, `{"attack":{"player":2}}`},
		{mnet.MsgRespawn, `{"respawn":{}}`},
		{mnet.MsgCast, `{"cast":{"ability":"heal","player":1}}`},
		{mnet.MsgTalk, `{"talk":{"npc":1000003}}`},
		{mnet.MsgDialogOption, `{"dialog_option":{"npc":1000003,"option":"accept_quest"}}`},
	}

	for _, tc := range cases {
		t.Run(tc.key, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err != nil {
				t.Fatalf("Decode(%s) failed: %v", tc.frame, err)
			}
			if got := msg.Name(); got != tc.key {
				t.Fatalf("Decode(%s) returned a %T naming itself %q, want %q", tc.frame, msg, got, tc.key)
			}
		})
	}
}

func TestABodyRejectionStillReportsItsSequenceNumber(t *testing.T) {
	t.Parallel()

	const frame = `{"move_to":{"x":1,"seq":5}}`

	msg, seq, err := mnet.Decode([]byte(frame))
	if err == nil {
		t.Fatalf("Decode(%s) accepted the frame as %#v, want a missing-field rejection", frame, msg)
	}
	rejection, ok := mnet.Rejection(err)
	if !ok {
		t.Fatalf("Decode(%s) returned %v, which is not a rejection", frame, err)
	}
	if rejection.Reason != mnet.ReasonMissingField {
		t.Fatalf("Decode(%s) rejected with %q, want %q", frame, rejection.Reason, mnet.ReasonMissingField)
	}
	if seq != 5 {
		t.Fatalf("Decode(%s) gave seq %d alongside the refusal, want 5: the envelope accepted that number and the sender has spent it",
			frame, seq)
	}
}

func TestDecodeRejections(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name       string
		frame      string
		wantReason mnet.RejectReason
		wantWhat   mnet.Disposition
		wantRe     string
	}{
		{"not json", `hello`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		{"not an object", `[1,2,3]`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		{"empty object", `{}`, mnet.ReasonProtocolError, mnet.ReplyErrorAndClose, ""},
		{"two keys", `{"move_to":{"x":1,"z":2},"use":{}}`, mnet.ReasonProtocolError, mnet.ReplyErrorAndClose, ""},
		{"unknown message", `{"teleport":{"x":1,"z":2}}`, mnet.ReasonUnknownMessage, mnet.Ignore, "teleport"},
		{"missing z", `{"move_to":{"x":5}}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"missing x", `{"move_to":{"z":5}}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"null payload", `{"move_to":null}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"wrong type", `{"move_to":{"x":"far","z":2}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"nan literal", `{"move_to":{"x":NaN,"z":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		{"overflowing literal", `{"move_to":{"x":1e400,"z":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"zero seq", `{"move_to":{"x":1,"z":1,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"negative seq", `{"move_to":{"x":1,"z":1,"seq":-1}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"fractional seq", `{"move_to":{"x":1,"z":1,"seq":1.5}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"quoted seq", `{"move_to":{"x":1,"z":1,"seq":"7"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"seq past what an int64 holds", `{"move_to":{"x":1,"z":1,"seq":9223372036854775808}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"a bad seq on a body that is also broken", `{"move_to":{"x":1,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		{"a bad seq on an unknown message", `{"teleport":{"seq":0}}`, mnet.ReasonUnknownMessage, mnet.Ignore, "teleport"},
		{"a bad seq on a pickup", `{"pickup":{"item":7,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "pickup"},
		{"a bad seq on a drop", `{"drop":{"slot":3,"seq":"7"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "drop"},
		{"an equip naming no slot", `{"equip":{}}`, mnet.ReasonMissingField, mnet.ReplyError, "equip"},
		{"an equip whose slot is not a number", `{"equip":{"slot":"right hand"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "equip"},
		{"an equip whose slot is fractional", `{"equip":{"slot":1.5}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "equip"},
		{"an unequip naming no worn slot", `{"unequip":{}}`, mnet.ReasonMissingField, mnet.ReplyError, "unequip"},
		{"an unequip carrying a bag index", `{"unequip":{"slot":0}}`, mnet.ReasonMissingField, mnet.ReplyError, "unequip"},
		{"an unequip whose worn slot is a number", `{"unequip":{"worn":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "unequip"},
		{"a bad seq on an equip", `{"equip":{"slot":0,"seq":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "equip"},
		{"a bad seq on an unequip", `{"unequip":{"worn":"right hand","seq":"7"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "unequip"},
		{"a gather naming no node", `{"gather":{}}`, mnet.ReasonMissingField, mnet.ReplyError, "gather"},
		{"a gather whose node is not a number", `{"gather":{"node":"tree"}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "gather"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err == nil {
				t.Fatalf("Decode(%s) accepted the frame as %#v, want rejection %q", tc.frame, msg, tc.wantReason)
			}
			rejection, ok := mnet.Rejection(err)
			if !ok {
				t.Fatalf("Decode(%s) returned %v, which is not a rejection", tc.frame, err)
			}
			if rejection.Reason != tc.wantReason {
				t.Fatalf("Decode(%s) rejected with %q, want %q (%v)", tc.frame, rejection.Reason, tc.wantReason, err)
			}
			if rejection.Disposition != tc.wantWhat {
				t.Fatalf("Decode(%s) disposition %v, want %v", tc.frame, rejection.Disposition, tc.wantWhat)
			}
			if rejection.Re != tc.wantRe {
				t.Fatalf("Decode(%s) attributed to %q, want %q", tc.frame, rejection.Re, tc.wantRe)
			}
			if rejection.Detail == "" {
				t.Fatalf("Decode(%s) gave no human detail to put in an error message", tc.frame)
			}
		})
	}
}

func TestLargeFiniteCoordinateDecodesCleanly(t *testing.T) {
	t.Parallel()

	msg, _, err := mnet.Decode([]byte(`{"move_to":{"x":1e30,"z":0}}`))
	if err != nil {
		t.Fatalf("Decode rejected a finite coordinate: %v", err)
	}
	if got := msg.(mnet.MoveTo); got.X != 1e30 {
		t.Fatalf("decoded x=%v, want 1e30", got.X)
	}
}
