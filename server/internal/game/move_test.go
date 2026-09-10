package game

import (
	"math"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestMoveSteersAtWalkSpeed(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	if !alice.steering() {
		t.Fatal("expected sticky steer after non-zero move")
	}
	pw.w.step()
	want := WalkSpeed * TickDuration.Seconds()
	if math.Abs(alice.pos.X-want) > 1e-9 || alice.pos.Z != 0 {
		t.Fatalf("pos=%v, want x≈%v z=0", alice.pos, want)
	}
	if got := pw.events(EvPathAssigned); len(got) != 0 {
		t.Fatalf("steer must not assign path, got %v", got)
	}
	if alice.lastPoseTick != pw.w.tick {
		t.Fatalf("lastPoseTick=%d, want %d after steer step", alice.lastPoseTick, pw.w.tick)
	}
}

func TestMoveZeroClearsSteer(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{DX: 0, DZ: -1}, 0)
	pw.w.step()
	pw.w.move(alice, mnet.Move{DX: 0, DZ: 0}, 0)
	if alice.steering() {
		t.Fatal("zero move left sticky steer")
	}
	before := alice.pos
	pw.w.step()
	if alice.pos != before {
		t.Fatalf("moved after halt: %v → %v", before, alice.pos)
	}
}

func TestMoveIdlePoseKeepalive(t *testing.T) {
	t.Skip("idle pose reanchor deferred until client applies pose (silence harness); PoseIdleEveryTicks kept")
}

func TestMoveCancelsPendingAttack(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.step()

	pw.w.move(alice, mnet.Move{DX: -1, DZ: 0}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("pending attack survived move: target=%d", alice.attackTarget)
	}
	cancelled := pw.events(EvAttackCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != CauseMove {
		t.Fatalf("cancel events=%v, want one cause=%s", cancelled, CauseMove)
	}
	before := hostile.hp
	for range AttackPeriodTicks + 2 {
		pw.w.step()
	}
	if hostile.hp != before {
		t.Fatalf("hits continued after cancel: hp %d→%d", before, hostile.hp)
	}
}

func TestLastIntentWinsMoveOverApproach(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()

	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	points, ok := destinationPath(alice, Point{X: 0, Z: 5})
	if !ok {
		t.Fatal("expected approach path")
	}
	alice.clearSteer()
	pw.w.assignPath(alice, points)
	if alice.steering() {
		t.Fatal("approach left sticky steer")
	}
	if len(alice.remaining) == 0 {
		t.Fatal("approach assigned no remaining")
	}

	pw.w.move(alice, mnet.Move{DX: 0, DZ: 1}, 0)
	if !alice.steering() {
		t.Fatal("move did not take ownership after approach")
	}
	if len(alice.remaining) != 0 {
		t.Fatalf("move left approach remaining=%v", alice.remaining)
	}
}

func TestClientCannotAuthorPositionViaMove(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{DX: 100, DZ: 0}, 0)
	pw.w.step()
	want := WalkSpeed * TickDuration.Seconds()
	if math.Abs(alice.pos.X-want) > 1e-9 {
		t.Fatalf("large dx teleported to x=%v, want WalkSpeed step %v", alice.pos.X, want)
	}
}

func TestMoveClampsToWorldBounds(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	alice.pos = Point{X: WorldHalfExtent, Z: 0}
	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	pw.w.step()
	if alice.pos.X != WorldHalfExtent {
		t.Fatalf("x=%v, want clamped at %v", alice.pos.X, WorldHalfExtent)
	}
}

func TestDeadRefusesMove(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	alice.hp = 0
	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Move{DX: 1, DZ: 0},
		Seq:  1,
	})
	if alice.steering() {
		t.Fatal("dead player accepted move")
	}
	if got := pw.events(EvMoveRejected); len(got) != 1 {
		t.Fatalf("rejection events=%v", got)
	}
}

func TestWireStateIncludesY(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	state := alice.wireState()
	if state.Y != 0 {
		t.Fatalf("Y=%v, want 0", state.Y)
	}
}
