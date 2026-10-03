package intents_test

import (
	"errors"
	"github.com/devarminas/marque/server/internal/eventstream"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/intents"
	"github.com/devarminas/marque/server/internal/navmesh"
	"github.com/devarminas/marque/server/internal/wire"
	"math"
	"testing"
)

func sample(seq uint32, dx, dz float64, jump bool) wire.Input {
	return build((wire.InputFields{Seq: seq, Dx: dx, Dz: dz, Jump: jump}).Build())
}

func TestOwnerMotionRampAndServerApproach(t *testing.T) {
	w, sessions, plan := fixture(t)
	w.SetNav(&navmesh.Mesh{Vertices: []navmesh.Vec3{{X: -2, Y: -1, Z: -2}, {X: 2, Y: 1, Z: -2}, {X: 2, Y: 1, Z: 2}, {X: -2, Y: -1, Z: 2}}, Polys: [][3]int{{0, 1, 2}, {0, 2, 3}}})
	if e := intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, []wire.Input{sample(1, 1, 0, false)}); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 10; i++ {
		w.AdvanceTick()
	}
	m, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	if m.X() != float32(1.2) || m.Y() != float32(.6) || !m.Grounded() || m.MapRevision() != 2 {
		t.Fatalf("actual grounded ramp baseline %v", m)
	}
	decoded := build(wire.DecodeState(build(m.Append(nil)))).(wire.OwnerMotion)
	if decoded != m || math.Abs(float64(decoded.Y())-.6) > math.Ldexp(1, -25) {
		t.Fatalf("ramp f32 serialization %v", decoded)
	}
	t.Logf("grounded-ramp y serialized error %.15g", math.Abs(float64(decoded.Y())-.6))
	w, sessions, plan = fixture(t)
	if e := w.SeedGroundItem("logs", 2, 0); e != nil {
		t.Fatal(e)
	}
	owner, e := sessions.Resolve(7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	if e = w.ApplyAction(owner, game.Origin{Source: game.OriginIntent, Seq: 1}, game.PickupAction{Item: game.ItemHandle{Index: 1, Gen: 1}}); e != nil {
		t.Fatal(e)
	}
	w.AdvanceTick()
	m, e = intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	if m.InputSeq() != 0 || m.Dx() != 1 || m.Dz() != 0 || m.X() != float32(.12) {
		t.Fatalf("server approach full wish without invented input ACK %v", m)
	}
}
func TestInputBatchAndOwnerMotion(t *testing.T) {
	w, sessions, plan := fixture(t)
	first, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	if first.Tick() != 1 || first.InputSeq() != 0 || first.Stream() != 88 || first.Player().Index != 1 || !first.Grounded() {
		t.Fatalf("initial baseline %v", first)
	}
	batch := []wire.Input{sample(3, 0, 1, false), sample(1, 1, 0, true), sample(2, 0, 0, false), sample(3, 0, 1, false)}
	if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, batch); e != nil {
		t.Fatal(e)
	}
	w.AdvanceTick()
	m, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	if m.Tick() != 2 || m.InputSeq() != 3 || m.X() != 0 || math.Abs(float64(m.Z())-.12) > 1e-8 || math.Abs(float64(m.Y())-.168) > 1e-8 || math.Abs(float64(m.Vy())-4.2) > 1e-6 || m.Grounded() {
		t.Fatalf("one physics tick from sorted batch %v", m)
	}
	conflicting := []wire.Input{sample(5, 1, 0, false), sample(4, 0, 0, false), sample(5, 0, 1, false)}
	if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, conflicting); !errors.Is(e, intents.ErrInputBatch) {
		t.Fatalf("conflicting batch %v", e)
	}
	unchanged, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil || unchanged != m {
		t.Fatalf("batch conflict mutated state %v %v", unchanged, e)
	}
	if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, []wire.Input{sample(3, 1, 0, true), sample(2, 1, 0, true)}); e != nil {
		t.Fatal(e)
	}
	w.AdvanceTick()
	m, e = intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	if m.InputSeq() != 3 || m.X() != 0 || math.Abs(float64(m.Z())-.24) > 1e-8 || math.Abs(float64(m.Y())-.304) > 1e-8 {
		t.Fatalf("already consumed changed copies must not jump or replace wish %v", m)
	}
	if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, make([]wire.Input, 257)); !errors.Is(e, intents.ErrInputBatch) {
		t.Fatalf("batch capacity %v", e)
	}
	if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, []wire.Input{sample(4, 0, 0, false), sample(math.MaxUint32, 1, 0, false)}); !errors.Is(e, eventstream.ErrExhausted) {
		t.Fatalf("exhaustion %v", e)
	}
	cursor, e := sessions.InputCursor(7, plan.Epoch)
	if e != nil || cursor.Seq != 3 {
		t.Fatalf("validation advanced input cursor %v %v", cursor, e)
	}
	if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch+1, []wire.Input{sample(4, 1, 0, false)}); e == nil {
		t.Fatal("wrong epoch admitted")
	}
}

func TestOwnerMotionBoundaryAndSerialization(t *testing.T) {
	w, sessions, plan := fixture(t)
	base, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
	if e != nil {
		t.Fatal(e)
	}
	f := wire.OwnerMotionFields{Stream: base.Stream(), Epoch: base.Epoch(), Player: base.Player(), Tick: base.Tick(), InputSeq: base.InputSeq(), X: 4095.9998, Y: 4095.9998, Z: -4095.9998, Vy: 1.8, Dx: 0, Dz: 0, Grounded: false, Mode: wire.MotionModeFree, MapId: "fixture", MapRevision: 1, HalfExtent: 4096, GroundY: 0, TickIntervalUs: 40000}
	m := build(f.Build())
	data := build(m.Append(nil))
	decoded := build(wire.DecodeState(data)).(wire.OwnerMotion)
	if decoded != m || intents.ValidateOwnerMotion(decoded) != nil {
		t.Fatalf("full f32 baseline roundtrip %v", decoded)
	}
	serializationError := math.Abs(float64(decoded.X()) - 4095.9998)
	if serializationError > 1.0/8192 {
		t.Fatalf("largest coordinate f32 rounding %.15g", serializationError)
	}
	t.Logf("largest-coordinate serialized f32 error %.15g raw kernel tolerance remains 1e-9", serializationError)
	cases := []struct {
		name   string
		change func(*wire.OwnerMotionFields)
	}{
		{"map bounds", func(f *wire.OwnerMotionFields) { f.HalfExtent = 128 }},
		{"unnormalized effective wish", func(f *wire.OwnerMotionFields) { f.Dx = 1; f.Dz = 1 }},
		{"vertical velocity", func(f *wire.OwnerMotionFields) { f.Vy = 4097 }},
		{"expired root", func(f *wire.OwnerMotionFields) { f.Mode = wire.MotionModeRooted; f.CastEnd = f.Tick }},
		{"empty map identity", func(f *wire.OwnerMotionFields) { f.MapId = "" }},
		{"empty stream", func(f *wire.OwnerMotionFields) { f.Stream = 0 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bad := f
			tc.change(&bad)
			m := build(bad.Build())
			if intents.ValidateOwnerMotion(m) == nil {
				t.Fatal("typed motion boundary accepted invalid baseline")
			}
		})
	}
	f.X = float32(math.NaN())
	if _, e = f.Build(); e == nil {
		t.Fatal("generated finite f32 boundary accepted NaN")
	}
}
