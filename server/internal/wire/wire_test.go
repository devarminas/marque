package wire_test

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"maps"
	"math"
	"os"
	"os/exec"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
	"github.com/devarminas/marque/server/internal/wire/probe"
)

type message interface {
	Append(dst []byte) ([]byte, error)
	String() string
}

var decoders = map[string]func([]byte) (message, error){
	"wire/state":    func(b []byte) (message, error) { return wire.DecodeState(b) },
	"wire/events":   func(b []byte) (message, error) { return wire.DecodeEvents(b) },
	"wire/input":    func(b []byte) (message, error) { return wire.DecodeInput(b) },
	"wire/intents":  func(b []byte) (message, error) { return wire.DecodeIntents(b) },
	"probe/state":   func(b []byte) (message, error) { return probe.DecodeState(b) },
	"probe/events":  func(b []byte) (message, error) { return probe.DecodeEvents(b) },
	"probe/input":   func(b []byte) (message, error) { return probe.DecodeInput(b) },
	"probe/intents": func(b []byte) (message, error) { return probe.DecodeIntents(b) },
}

var errorNames = map[string]error{
	"truncated":       codec.ErrTruncated,
	"trailing":        codec.ErrTrailing,
	"unknown_message": codec.ErrUnknownMessage,
	"over_bound":      codec.ErrOverBound,
	"non_finite":      codec.ErrNonFinite,
	"out_of_range":    codec.ErrOutOfRange,
	"bad_bool":        codec.ErrBadBool,
	"bad_enum":        codec.ErrBadEnum,
	"bad_varint":      codec.ErrBadVarint,
	"bad_utf8":        codec.ErrBadUTF8,
	"rule":            codec.ErrRule,
}

type vector struct {
	where       string
	accept      bool
	name        string
	decoder     string
	bytes       []byte
	textOrError string
}

func loadVectors(tb testing.TB) []vector {
	tb.Helper()
	var out []vector
	for _, file := range slices.Sorted(maps.Keys(vectorFiles)) {
		schema := ""
		for n, line := range strings.Split(vectorFiles[file], "\n") {
			line = strings.TrimSpace(line)
			where := fmt.Sprintf("%s:%d", file, n+1)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.SplitN(line, " ", 5)
			if fields[0] == "schema" && len(fields) == 2 {
				schema = fields[1]
				continue
			}
			if len(fields) != 5 || (fields[0] != "accept" && fields[0] != "reject") || schema == "" {
				tb.Fatalf("%s: want `accept|reject <name> <channel> <hex> <text|error>` after a schema line", where)
			}
			b, err := hex.DecodeString(fields[3])
			if err != nil {
				tb.Fatalf("%s: %v", where, err)
			}
			v := vector{where, fields[0] == "accept", fields[1], schema + "/" + fields[2], b, fields[4]}
			if decoders[v.decoder] == nil {
				tb.Fatalf("%s: no decoder %s", where, v.decoder)
			}
			if !v.accept && errorNames[v.textOrError] == nil {
				tb.Fatalf("%s: unknown error %q", where, v.textOrError)
			}
			out = append(out, v)
		}
	}
	if len(out) == 0 {
		tb.Fatal("no vectors")
	}
	return out
}

func TestVectors(t *testing.T) {
	for _, v := range loadVectors(t) {
		m, err := decoders[v.decoder](v.bytes)
		if !v.accept {
			if !errors.Is(err, errorNames[v.textOrError]) {
				t.Errorf("%s %s: got %v, want %s", v.where, v.name, err, v.textOrError)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s %s: decode: %v", v.where, v.name, err)
			continue
		}
		if m.String() != v.textOrError {
			t.Errorf("%s %s: text\n  got  %s\n  want %s", v.where, v.name, m.String(), v.textOrError)
		}
		back, err := m.Append(nil)
		if err != nil || !bytes.Equal(back, v.bytes) {
			t.Errorf("%s %s: re-encoded %x, %v; want %x", v.where, v.name, back, err, v.bytes)
		}
	}
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func must[T any](m T, err error) T {
	if err != nil {
		panic(fmt.Sprintf("build: %v", err))
	}
	return m
}

func errOf[T any](_ T, err error) error { return err }

func TestBuiltMessagesEncodeToVectorBytes(t *testing.T) {
	id := wire.PlayerId{Index: 7, Gen: 2}
	cases := []struct {
		msg  message
		want string
	}{
		{must(wire.InputFields{Dx: 0.5, Dz: -1, Jump: true, Seq: 300}.Build()), "019600012c010000"},
		{must(wire.PoseFields{Id: id, X: 12.34, Y: 0.5, Z: -100.25}.Build()), "020702d244060032400600d7180600"},
		{must(wire.HpFields{Id: id, Hp: 85, MaxHp: 120}.Build()), "0307025500000078000000"},
		{must(wire.RefusedFields{Tick: 1000, Seq: 42, Reason: wire.RefuseReasonCooldown}.Build()), "04e80300002a00000006"},
		{must(probe.PartyFields{Leader: probe.PlayerId{Index: 1}, Members: []probe.PlayerId{{Index: 1}, {Index: 2}}}.Build()), "0401000201000200"},
	}
	for _, c := range cases {
		got, err := c.msg.Append(nil)
		if err != nil || hex.EncodeToString(got) != c.want {
			t.Errorf("%v: encoded %x, %v; want %s", c.msg, got, err, c.want)
		}
	}
}

func TestQuantizationSnapsToGrid(t *testing.T) {
	in := must(wire.InputFields{Dx: 0.123, Dz: -0.456, Seq: 1}.Build())
	b, err := in.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	m, err := wire.DecodeInput(b)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.(wire.Input); got.Dx() != 0.12 || got.Dz() != -0.46 {
		t.Fatalf("decoded dx=%v dz=%v, want 0.12 -0.46", got.Dx(), got.Dz())
	}
}

// Build runs the encoder's checks, so it refuses a value with the error the
// decoder gives for the same value's bytes in rules.vec.
func TestBuildRefusesWhatDecodersRefuse(t *testing.T) {
	npc := probe.NpcId{Index: 7}
	p1, p2 := probe.PlayerId{Index: 1}, probe.PlayerId{Index: 2}
	slot := func(n uint8, item uint32) probe.BagSlot {
		return must(probe.BagSlotFields{Slot: n, Item: probe.ItemId{Index: item}}.Build())
	}
	offer := func(owner probe.PlayerId, item uint32) probe.Offer {
		return must(probe.OfferFields{Owner: owner, Item: probe.ItemId{Index: item}}.Build())
	}
	cases := []struct {
		name string
		err  error
		want error
	}{
		{"give slot 40", errOf(probe.GiveFields{Npc: npc, Slot: 40}.Build()), codec.ErrRule},
		{"bag slot 40", errOf(probe.BagSlotFields{Slot: 40}.Build()), codec.ErrRule},
		{"inventory size 0", errOf(probe.InventoryFields{}.Build()), codec.ErrRule},
		{"tilt 46", errOf(probe.ZoneFields{Tilt: 46}.Build()), codec.ErrRule},
		{"lo -8.25", errOf(probe.ZoneFields{Lo: -8.25, Hi: -8}.Build()), codec.ErrRule},
		{"hi 5.5", errOf(probe.ZoneFields{Hi: 5.5}.Build()), codec.ErrRule},
		{"lo 11", errOf(probe.ZoneFields{Lo: 11}.Build()), codec.ErrOutOfRange},
		{"line 501", errOf(probe.DialogFields{Lines: []uint16{501}}.Build()), codec.ErrRule},
		{"pick trade", errOf(probe.PickFields{Option: probe.OptionTrade}.Build()), codec.ErrRule},
		{"pick undeclared", errOf(probe.PickFields{Option: 9}.Build()), codec.ErrBadEnum},
		{"five options", errOf(probe.DialogFields{Options: make([]probe.Option, 5)}.Build()), codec.ErrOverBound},
		{"repeated member", errOf(probe.PartyFields{Leader: p1, Members: []probe.PlayerId{p1, p1}}.Build()), codec.ErrRule},
		{"repeated slot", errOf(probe.InventoryFields{Size: 10, Slots: []probe.BagSlot{slot(0, 5), slot(0, 6)}}.Build()), codec.ErrRule},
		{"leader outside", errOf(probe.PartyFields{Leader: p2, Members: []probe.PlayerId{p1}}.Build()), codec.ErrRule},
		{"slot at size", errOf(probe.InventoryFields{Size: 9, Slots: []probe.BagSlot{slot(9, 6)}}.Build()), codec.ErrRule},
		{"lo above hi", errOf(probe.ZoneFields{Lo: 2, Hi: 1.75}.Build()), codec.ErrRule},
		{"lo above hi on the grid", errOf(probe.ZoneFields{Lo: 2.1, Hi: 2}.Build()), nil},
		{"foreign offer", errOf(probe.TradeFields{From: p1, Offers: []probe.Offer{offer(p1, 5), offer(p2, 6)}}.Build()), codec.ErrRule},
		{"repeated item", errOf(probe.TradeFields{From: p1, Offers: []probe.Offer{offer(p1, 5), offer(p1, 5)}}.Build()), codec.ErrRule},
		{"duel self", errOf(probe.DuelFields{Challenger: p1, Target: p1}.Build()), codec.ErrRule},
		{"NaN wish", errOf(wire.InputFields{Dx: math.NaN()}.Build()), codec.ErrNonFinite},
		{"wish above range", errOf(wire.InputFields{Dz: 1.01}.Build()), codec.ErrOutOfRange},
		{"label over bound", errOf(probe.ProbeFields{Label: "123456789"}.Build()), codec.ErrOverBound},
		{"infinite ratio", errOf(probe.ProbeFields{Ratio: float32(math.Inf(-1))}.Build()), codec.ErrNonFinite},
	}
	for _, c := range cases {
		if !errors.Is(c.err, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, c.err, c.want)
		}
	}
}

// A built message owns its lists; changing the caller's slice afterwards
// cannot make it break a rule.
func TestBuildCopiesLists(t *testing.T) {
	members := []probe.PlayerId{{Index: 1}, {Index: 2}}
	party := must(probe.PartyFields{Leader: members[0], Members: members}.Build())
	members[0] = probe.PlayerId{Index: 9}
	if got := party.String(); got != "party{leader:PlayerId(1/0) members:[PlayerId(1/0) PlayerId(2/0)]}" {
		t.Fatalf("party changed with the caller's slice: %s", got)
	}
}

// The zero value is the one message Build never checked; Append refuses it
// when it breaks the schema and leaves the buffer as it was.
func TestAppendRefusesInvalidZeroValue(t *testing.T) {
	prefix := []byte{0xaa}
	cases := []struct {
		msg  message
		want error
	}{
		{probe.Party{}, codec.ErrRule},
		{probe.Inventory{}, codec.ErrRule},
		{wire.Refused{}, codec.ErrBadEnum},
	}
	for _, c := range cases {
		got, err := c.msg.Append(prefix)
		if !errors.Is(err, c.want) || string(got) != "\xaa" {
			t.Errorf("%T zero value: got %x, %v; want aa, %v", c.msg, got, err, c.want)
		}
	}
}

func TestListViewReadsDecodedElements(t *testing.T) {
	m, err := probe.DecodeEvents(mustHex(t, "0401000201000200"))
	if err != nil {
		t.Fatal(err)
	}
	members := m.(probe.Party).Members()
	var got []probe.PlayerId
	for i, id := range members.All() {
		if members.At(i) != id {
			t.Fatalf("At(%d) = %v, All gave %v", i, members.At(i), id)
		}
		got = append(got, id)
	}
	if want := []probe.PlayerId{{Index: 1}, {Index: 2}}; members.Len() != 2 || !reflect.DeepEqual(got, want) {
		t.Fatalf("members = %v (len %d), want %v", got, members.Len(), want)
	}
}

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
	want := []string{
		"pose{id:PlayerId(7/2) x:12.34 y:0.5 z:-100.25}",
		"hp{id:PlayerId(7/2) hp:85 max_hp:120}",
		"pose{id:PlayerId(1/0) x:-4046 y:-4096 z:-4096}",
	}
	for i, w := range want {
		got, err := wire.DecodeNextState(r)
		if err != nil {
			t.Fatalf("message %d: %v", i, err)
		}
		if got.String() != w {
			t.Fatalf("message %d: got %v, want %s", i, got, w)
		}
	}
	if r.Len() != 0 {
		t.Fatalf("%d bytes left after three messages", r.Len())
	}
	if err := r.Finish(); err != nil {
		t.Fatalf("Finish after three messages: %v", err)
	}
}

// Each ok snippet proves the harness builds valid code, so the matching bad
// snippet's failure can only come from the line it names.
func TestGeneratedTypesRefuseMisuse(t *testing.T) {
	build := func(dir string) (string, error) {
		out, err := exec.Command("go", "build", "-o", os.DevNull, "./testdata/kindcheck/"+dir).CombinedOutput()
		return string(out), err
	}
	if out, err := build("ok"); err != nil {
		t.Fatalf("PlayerId snippet should compile: %v\n%s", err, out)
	}
	for _, c := range []struct{ dir, want string }{
		{"wrong", "cannot use id (variable of struct type wire.NpcId) as wire.PlayerId value"},
		{"mutate", "v.f undefined (cannot refer to unexported field f)"},
	} {
		out, err := build(c.dir)
		if err == nil {
			t.Fatalf("%s snippet compiled", c.dir)
		}
		if !strings.Contains(out, c.want) {
			t.Fatalf("%s snippet failed for another reason:\n%s", c.dir, out)
		}
	}
}
