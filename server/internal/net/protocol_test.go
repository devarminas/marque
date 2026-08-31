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
				You:    1,
				TickMS: 150,
				Tick:   142,
				Players: []mnet.PlayerState{
					{ID: 1, X: 0, Z: 0},
					{ID: 2, X: 5, Z: 5},
				},
			},
			want: `{"welcome":{"you":1,"tick_ms":150,"tick":142,"players":[{"id":1,"x":0,"z":0},{"id":2,"x":5,"z":5}]}}`,
		},
		{
			name: "spawn",
			msg:  mnet.Spawn{ID: 2, X: 0, Z: 0},
			want: `{"spawn":{"id":2,"x":0,"z":0}}`,
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
			name: "error with nothing to attribute it to",
			msg:  mnet.Error{Msg: "text frames only"},
			want: `{"error":{"msg":"text frames only"}}`,
		},
	}

	for _, tc := range cases {
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
		name  string
		frame string
	}{
		{"plain", `{"move_to":{"x":42.3,"z":17.8}}`},
		// Compatibility rule 2: senders may add fields. M2's seq is already
		// spoken for, and this server must ignore it rather than break.
		{"with a reserved seq", `{"move_to":{"x":42.3,"z":17.8,"seq":9}}`},
		{"with a field nobody has invented yet", `{"move_to":{"x":42.3,"z":17.8,"whatever":true}}`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, err := mnet.Decode([]byte(tc.frame))
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
		})
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
		// Zero or two keys is a malformed frame, not a compatibility question:
		// there is no message to interpret.
		{"empty object", `{}`, mnet.ReasonProtocolError, mnet.ReplyErrorAndClose, ""},
		{"two keys", `{"move_to":{"x":1,"z":2},"use":{}}`, mnet.ReasonProtocolError, mnet.ReplyErrorAndClose, ""},
		// Compatibility rule 1: one unknown key is logged and ignored, so a
		// client written against a later protocol keeps working.
		{"unknown message", `{"teleport":{"x":1,"z":2}}`, mnet.ReasonUnknownMessage, mnet.Ignore, "teleport"},
		// A field left out is a broken client, not a click on an axis.
		// encoding/json would otherwise fill z with 0 and the server would
		// happily walk the player to it.
		{"missing z", `{"move_to":{"x":5}}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"missing x", `{"move_to":{"z":5}}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"null payload", `{"move_to":null}`, mnet.ReasonMissingField, mnet.ReplyError, "move_to"},
		{"wrong type", `{"move_to":{"x":"far","z":2}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
		// JSON has no literal for NaN or infinity, so a client trying to send
		// one is refused while still text. The finite check in Decode runs on
		// the decoded float and is the backstop for any parser that saturates
		// an overflowing literal instead of failing on it.
		// NaN is invalid JSON anywhere in the document, so the frame fails
		// before the key is read and there is no message to attribute it to.
		{"nan literal", `{"move_to":{"x":NaN,"z":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, ""},
		{"overflowing literal", `{"move_to":{"x":1e400,"z":0}}`, mnet.ReasonMalformedJSON, mnet.ReplyError, "move_to"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, err := mnet.Decode([]byte(tc.frame))
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

// TestLargeFiniteCoordinateDecodesCleanly pins the hazard the protocol calls
// out: 1e30 is not a decoder problem, it is a bounds problem, and the decoder
// must hand it on rather than refuse it.
func TestLargeFiniteCoordinateDecodesCleanly(t *testing.T) {
	t.Parallel()

	msg, err := mnet.Decode([]byte(`{"move_to":{"x":1e30,"z":0}}`))
	if err != nil {
		t.Fatalf("Decode rejected a finite coordinate: %v", err)
	}
	if got := msg.(mnet.MoveTo); got.X != 1e30 {
		t.Fatalf("decoded x=%v, want 1e30", got.X)
	}
}
