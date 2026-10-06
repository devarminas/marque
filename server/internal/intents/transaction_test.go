package intents_test

import (
	"math"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/intents"
	"github.com/devarminas/marque/server/internal/wire"
)

func TestAdmitAndStepMixedSquareAndQuantizedWishKeepsAction(t *testing.T) {
	for _, wish := range [][2]float64{{1, 1}, {math.Sqrt(.5), math.Sqrt(.5)}, {math.Cos(math.Pi / 6), .5}} {
		h := successFixture(t, []string{"logs"}, 1)
		owner := h.owners[0]
		drop := build((wire.DropFields{Seq: 1, Slot: 0}).Build())
		action, err := intents.Admit(h.s, owner.id, owner.plan.Epoch, drop)
		if err != nil || action == nil {
			t.Fatalf("action admission %v/%v", action, err)
		}
		input := sample(1, wish[0], wish[1], false)
		movement, err := intents.AdmitInput(h.s, owner.id, owner.plan.Epoch, input)
		if err != nil || movement == nil {
			t.Fatalf("input admission %v/%v", movement, err)
		}
		before, err := h.w.OwnerMotion(owner.plan.Player)
		if err != nil || before.Tick != 0 || before.State.X != 0 || before.State.Z != 0 {
			t.Fatalf("admission prematurely applied game command %+v/%v", before, err)
		}
		batch, err := h.w.Step([]game.Command{action, movement})
		if err != nil || batch.Tick != 1 || batch.Frame.Tick != 1 {
			t.Fatalf("mixed batch %d/%v", batch.Tick, err)
		}
		length := math.Hypot(input.Dx(), input.Dz())
		motion := batch.Frame.OwnerMotion[0]
		if math.Abs(motion.State.DX-input.Dx()/length) > 1e-12 || math.Abs(motion.State.DZ-input.Dz()/length) > 1e-12 || math.Abs(motion.State.X-.12*input.Dx()/length) > 1e-12 || math.Abs(motion.State.Z-.12*input.Dz()/length) > 1e-12 {
			t.Fatalf("wish (%v,%v) normalized to %+v", input.Dx(), input.Dz(), motion.State)
		}
		dropped := false
		for _, entity := range batch.Frame.Entities {
			if _, ok := entity.Handle.(game.ItemHandle); ok {
				dropped = entity.Appearance.Kind == "logs" && entity.Transform.X == 0 && entity.Transform.Z == 0
			}
		}
		if !dropped {
			t.Fatal("same-batch valid drop was lost")
		}
		emptyInventory := false
		for _, change := range batch.OwnerChanges {
			if change.Tick != batch.Tick {
				t.Fatal("owner fact born outside producing tick")
			}
			if value, ok := change.Value.(game.InventoryValue); ok {
				emptyInventory = len(value.Slots) == 0
			}
			if _, ok := change.Value.(game.RefusedValue); ok {
				t.Fatal("legal square-bound wish was refused")
			}
		}
		if !emptyInventory {
			t.Fatal("drop inventory fact was lost")
		}
		baseline, err := intents.OwnerMotionFromFrame(batch.Frame, owner.plan.Player, owner.plan.Stream, owner.plan.Epoch)
		if err != nil || baseline.InputSeq() != 1 || baseline.Tick() != 1 {
			t.Fatalf("consumed baseline %v/%v", baseline, err)
		}
		if err = h.s.AppendAt(batch.Tick, batch.OwnerChanges); err != nil {
			t.Fatal(err)
		}
		boundary, err := h.s.CloseTick(owner.id, owner.plan.Epoch, batch.Tick, 1, owner.pair.ss)
		if err != nil || boundary.NextIntent != 2 {
			t.Fatalf("certified command frontier %+v/%v", boundary, err)
		}
		duplicate, err := intents.Admit(h.s, owner.id, owner.plan.Epoch, drop)
		if err != nil || duplicate != nil {
			t.Fatalf("action duplicate readmitted %v/%v", duplicate, err)
		}
		duplicate, err = intents.AdmitInput(h.s, owner.id, owner.plan.Epoch, input)
		if err != nil || duplicate != nil {
			t.Fatalf("input duplicate readmitted %v/%v", duplicate, err)
		}
	}
}
func TestAdmitInputBatchConflictKeepsGameAndInputFrontier(t *testing.T) {
	w, sessions, plan := fixture(t)
	commands, err := intents.AdmitInputBatch(sessions, 7, plan.Epoch, []wire.Input{sample(3, 0, 1, false), sample(1, 1, 0, true), sample(2, 0, 0, false), sample(3, 0, 1, false)})
	if err != nil || len(commands) != 3 {
		t.Fatalf("ordered admission %d/%v", len(commands), err)
	}
	batch, err := w.Step(commands)
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := intents.OwnerMotionFromFrame(batch.Frame, plan.Player, plan.Stream, plan.Epoch)
	if err != nil || baseline.Tick() != 2 || baseline.InputSeq() != 3 || baseline.X() != 0 || math.Abs(float64(baseline.Z())-.12) > 1e-8 || math.Abs(float64(baseline.Y())-.168) > 1e-8 || math.Abs(float64(baseline.Vy())-4.2) > 1e-6 {
		t.Fatalf("literal sorted-input result %v/%v", baseline, err)
	}
	if _, err = intents.AdmitInputBatch(sessions, 7, plan.Epoch, []wire.Input{sample(5, 1, 0, false), sample(4, 0, 0, false), sample(5, 0, 1, false)}); err != intents.ErrInputBatch {
		t.Fatalf("conflicting input admission %v", err)
	}
	cursor, err := sessions.InputCursor(7, plan.Epoch)
	if err != nil || cursor.Seq != 3 {
		t.Fatalf("invalid batch advanced frontier %+v/%v", cursor, err)
	}
	unchanged, err := w.OwnerMotion(plan.Player)
	if err != nil || unchanged.Tick != batch.Tick || unchanged.State != batch.Frame.OwnerMotion[0].State {
		t.Fatalf("invalid batch changed game %+v/%v", unchanged, err)
	}
}

func TestFrozenFrameMotionDoesNotCertifyLaterAdmittedInput(t *testing.T) {
	w, sessions, plan := fixture(t)
	first, err := intents.AdmitInput(sessions, 7, plan.Epoch, sample(1, 1, 0, false))
	if err != nil {
		t.Fatal(err)
	}
	frozen, err := w.Step([]game.Command{first})
	if err != nil {
		t.Fatal(err)
	}
	later, err := intents.AdmitInput(sessions, 7, plan.Epoch, sample(2, 0, 0, false))
	if err != nil {
		t.Fatal(err)
	}
	cursor, err := sessions.InputCursor(7, plan.Epoch)
	if err != nil || cursor.Seq != 2 {
		t.Fatalf("later input was not actually admitted %+v/%v", cursor, err)
	}
	baseline, err := intents.OwnerMotionFromFrame(frozen.Frame, plan.Player, plan.Stream, plan.Epoch)
	if err != nil || baseline.Tick() != 2 || baseline.InputSeq() != 1 || baseline.Dx() != 1 || baseline.X() != float32(.12) {
		t.Fatalf("frozen frame certified later input %v/%v", baseline, err)
	}
	next, err := w.Step([]game.Command{later})
	if err != nil {
		t.Fatal(err)
	}
	stopped, err := intents.OwnerMotionFromFrame(next.Frame, plan.Player, plan.Stream, plan.Epoch)
	if err != nil || stopped.Tick() != 3 || stopped.InputSeq() != 2 || stopped.Dx() != 0 || stopped.X() != float32(.12) {
		t.Fatalf("consumed stop baseline %v/%v", stopped, err)
	}
	baseline, err = intents.OwnerMotionFromFrame(frozen.Frame, plan.Player, plan.Stream, plan.Epoch)
	if err != nil || baseline.InputSeq() != 1 || baseline.Dx() != 1 {
		t.Fatalf("later consumption mutated frozen baseline %v/%v", baseline, err)
	}
}
