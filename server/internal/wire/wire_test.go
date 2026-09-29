package wire_test

import (
	"bufio"
	"encoding/hex"
	"errors"
	"math"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
	"github.com/devarminas/marque/server/internal/wire/probe"
)

func readVectors(t *testing.T, name string) map[string]string {
	t.Helper()
	f, err := os.Open("../../../shared/wire/vectors/" + name)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, hexStr, _ := strings.Cut(line, " ")
		out[name] = hexStr
	}
	return out
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type vector struct {
	name   string
	msg    wire.Message
	text   string
	decode func([]byte) (wire.Message, error)
}

func onState(b []byte) (wire.Message, error)  { return wire.DecodeState(b) }
func onEvents(b []byte) (wire.Message, error) { return wire.DecodeEvents(b) }
func onInput(b []byte) (wire.Message, error)  { return wire.DecodeInput(b) }

var starter = []vector{
	{"input", wire.Input{Dx: 0.5, Dz: -1, Jump: true, Seq: 300},
		"input{dx:0.5 dz:-1 jump:true seq:300}", onInput},
	{"pose", wire.Pose{Id: wire.PlayerId{Index: 7, Gen: 2}, X: 12.34, Y: 0.5, Z: -100.25},
		"pose{id:PlayerId(7/2) x:12.34 y:0.5 z:-100.25}", onState},
	{"hp", wire.Hp{Id: wire.PlayerId{Index: 7, Gen: 2}, Hp: 85, MaxHp: 120},
		"hp{id:PlayerId(7/2) hp:85 max_hp:120}", onState},
	{"refused", wire.Refused{Tick: 1000, Seq: 42, Reason: wire.RefuseReasonCooldown},
		"refused{tick:1000 seq:42 reason:cooldown}", onEvents},
}

func TestStarterVectors(t *testing.T) {
	want := readVectors(t, "starter.vec")
	for _, v := range starter {
		got, err := v.msg.Append(nil)
		if err != nil {
			t.Fatalf("%s: encode: %v", v.name, err)
		}
		if hex.EncodeToString(got) != want[v.name] {
			t.Errorf("%s: encoded %x, vector %s", v.name, got, want[v.name])
		}
		back, err := v.decode(mustHex(t, want[v.name]))
		if err != nil {
			t.Fatalf("%s: decode: %v", v.name, err)
		}
		if !reflect.DeepEqual(back, v.msg) {
			t.Errorf("%s: round trip gave %v, want %v", v.name, back, v.msg)
		}
		if back.String() != v.text {
			t.Errorf("%s: text %q, want %q", v.name, back.String(), v.text)
		}
	}
}

func TestQuantizationSnapsToGrid(t *testing.T) {
	b, err := wire.Input{Dx: 0.123, Dz: -0.456, Seq: 1}.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	m, err := wire.DecodeInput(b)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.(wire.Input); got.Dx != 0.12 || got.Dz != -0.46 {
		t.Fatalf("decoded dx=%v dz=%v, want 0.12 -0.46", got.Dx, got.Dz)
	}
}

var probeValue = probe.Probe{
	Label: "héllo",
	Ratio: 1.5,
	Pairs: []probe.Pair{
		{Who: probe.NpcId{Index: 3, Gen: 0}, Weight: 0.25},
		{Who: probe.NpcId{Index: 200, Gen: 1}, Weight: -2},
	},
	Flag:   true,
	Color:  probe.ColorBlue,
	At:     -2.25,
	Shorts: []uint16{1, 65535},
	AU8:    255,
	AU16:   0x1234,
	AU32:   0xdeadbeef,
	AU64:   0x0102030405060708,
	AI8:    -1,
	AI16:   -2,
	AI32:   -3,
	AI64:   -4,
	Owner:  probe.PlayerId{Index: 16384, Gen: 5},
}

func TestProbeVectors(t *testing.T) {
	want := readVectors(t, "probe.vec")
	cases := []struct {
		name   string
		msg    probe.Message
		decode func([]byte) (probe.Message, error)
	}{
		{"probe", probeValue, func(b []byte) (probe.Message, error) { return probe.DecodeEvents(b) }},
		{"ping", probe.Ping{Nonce: 42}, func(b []byte) (probe.Message, error) { return probe.DecodeIntents(b) }},
	}
	for _, c := range cases {
		got, err := c.msg.Append(nil)
		if err != nil {
			t.Fatalf("%s: encode: %v", c.name, err)
		}
		if hex.EncodeToString(got) != want[c.name] {
			t.Errorf("%s: encoded %x, vector %s", c.name, got, want[c.name])
		}
		back, err := c.decode(mustHex(t, want[c.name]))
		if err != nil {
			t.Fatalf("%s: decode: %v", c.name, err)
		}
		if !reflect.DeepEqual(back, c.msg) {
			t.Errorf("%s: round trip gave %v, want %v", c.name, back, c.msg)
		}
	}
}

func TestDecodeRejects(t *testing.T) {
	cases := []struct {
		name   string
		hex    string
		decode func([]byte) error
		want   error
	}{
		{"empty input", "", stateErr, codec.ErrTruncated},
		{"truncated pose", "020702d244060032400600d71806", stateErr, codec.ErrTruncated},
		{"trailing byte after input", "019600012c01000000", inputErr, codec.ErrTrailing},
		{"trailing byte after hp", "030702550000007800000000", stateErr, codec.ErrTrailing},
		{"unknown message id", "7f", stateErr, codec.ErrUnknownMessage},
		{"pose on the events channel", "020702d244060032400600d7180600", eventsErr, codec.ErrUnknownMessage},
		{"refused on the state channel", "04e80300002a00000006", stateErr, codec.ErrUnknownMessage},
		{"input on the intents channel", "019600012c010000", intentsErr, codec.ErrUnknownMessage},
		{"pose on the input channel", "020702d244060032400600d7180600", inputErr, codec.ErrUnknownMessage},
		{"overlong varint id", "8100", stateErr, codec.ErrBadVarint},
		{"wish above its range", "01c900012c010000", inputErr, codec.ErrOutOfRange},
		{"bool byte 2", "019600022c010000", inputErr, codec.ErrBadBool},
		{"refuse reason 0", "04e80300002a00000000", eventsErr, codec.ErrBadEnum},
		{"string over bound", "0109616161616161616161", probeErr, codec.ErrOverBound},
		{"string not utf-8", "0101ff", probeErr, codec.ErrBadUTF8},
		{"f32 NaN", "01000000c07f", probeErr, codec.ErrNonFinite},
		{"f32 +Inf", "01000000807f", probeErr, codec.ErrNonFinite},
		{"list over bound", "01000000803f04", probeErr, codec.ErrOverBound},
		{"count with no elements behind it", "03ff7f", probeErr, codec.ErrTruncated},
	}
	for _, c := range cases {
		if err := c.decode(mustHex(t, c.hex)); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

func stateErr(b []byte) error   { _, err := wire.DecodeState(b); return err }
func eventsErr(b []byte) error  { _, err := wire.DecodeEvents(b); return err }
func inputErr(b []byte) error   { _, err := wire.DecodeInput(b); return err }
func intentsErr(b []byte) error { _, err := wire.DecodeIntents(b); return err }
func probeErr(b []byte) error   { _, err := probe.DecodeEvents(b); return err }

// Crowd's list bound is 65535 and each Pair is at least 6 bytes, so the 3-byte
// payload 03 ff7f claims 16383 pairs (98298 bytes) with none behind it.
func TestHostileCountFailsBeforeAllocating(t *testing.T) {
	b := mustHex(t, "03ff7f")
	var err error
	allocs := testing.AllocsPerRun(100, func() { _, err = probe.DecodeEvents(b) })
	if !errors.Is(err, codec.ErrTruncated) {
		t.Fatalf("got %v, want %v", err, codec.ErrTruncated)
	}
	if allocs != 0 {
		t.Fatalf("hostile count cost %v allocations, want 0", allocs)
	}
}

func TestDecodeNextReadsPackedMessagesInOrder(t *testing.T) {
	b := mustHex(t, "020702d244060032400600d7180600"+"0307025500000078000000"+"020100881300000000000000000000")
	r := codec.NewReader(b)
	want := []wire.StateMsg{
		wire.Pose{Id: wire.PlayerId{Index: 7, Gen: 2}, X: 12.34, Y: 0.5, Z: -100.25},
		wire.Hp{Id: wire.PlayerId{Index: 7, Gen: 2}, Hp: 85, MaxHp: 120},
		wire.Pose{Id: wire.PlayerId{Index: 1, Gen: 0}, X: -4046, Y: -4096, Z: -4096},
	}
	for i, w := range want {
		got, err := wire.DecodeNextState(r)
		if err != nil {
			t.Fatalf("message %d: %v", i, err)
		}
		if !reflect.DeepEqual(got, w) {
			t.Fatalf("message %d: got %v, want %v", i, got, w)
		}
	}
	if r.Len() != 0 {
		t.Fatalf("%d bytes left after three messages", r.Len())
	}
	if err := r.Finish(); err != nil {
		t.Fatalf("Finish after three messages: %v", err)
	}
}

func TestEncodeRejectsAndLeavesBufferUnchanged(t *testing.T) {
	prefix := []byte{0xaa}
	cases := []struct {
		name string
		msg  interface {
			Append([]byte) ([]byte, error)
		}
		want error
	}{
		{"NaN wish", wire.Input{Dx: math.NaN()}, codec.ErrNonFinite},
		{"wish above range", wire.Input{Dz: 1.01}, codec.ErrOutOfRange},
		{"pose below range", wire.Pose{X: -4096.5}, codec.ErrOutOfRange},
		{"unknown reason", wire.Refused{Reason: 99}, codec.ErrBadEnum},
		{"label over bound", probe.Probe{Label: "123456789", Color: probe.ColorRed}, codec.ErrOverBound},
		{"infinite ratio", probe.Probe{Ratio: float32(math.Inf(-1))}, codec.ErrNonFinite},
		{"four pairs", probe.Probe{Pairs: make([]probe.Pair, 4)}, codec.ErrOverBound},
	}
	for _, c := range cases {
		got, err := c.msg.Append(prefix)
		if !errors.Is(err, c.want) || string(got) != "\xaa" {
			t.Errorf("%s: got %x, %v; want aa, %v", c.name, got, err, c.want)
		}
	}
}

// The ok snippet proves the harness builds valid code, so the wrong snippet's
// failure can only come from the NpcId/PlayerId mismatch it names.
func TestEntityKindsDoNotMix(t *testing.T) {
	build := func(dir string) (string, error) {
		out, err := exec.Command("go", "build", "-o", os.DevNull, "./testdata/kindcheck/"+dir).CombinedOutput()
		return string(out), err
	}
	if out, err := build("ok"); err != nil {
		t.Fatalf("PlayerId snippet should compile: %v\n%s", err, out)
	}
	out, err := build("wrong")
	if err == nil {
		t.Fatal("NpcId passed as PlayerId compiled")
	}
	if !strings.Contains(out, "cannot use id (variable of struct type wire.NpcId) as wire.PlayerId value") {
		t.Fatalf("wrong snippet failed for another reason:\n%s", out)
	}
}
