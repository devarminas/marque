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

func TestApproachPathBroadcastsPoseEachStep(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	alice.pos = Point{X: 0, Z: 0}
	points, ok := destinationPath(alice, Point{X: 0, Z: 3})
	if !ok {
		t.Fatal("expected approach path")
	}
	pw.w.assignPath(alice, points)
	if alice.lastPoseTick != pw.w.tick {
		t.Fatalf("assignPath lastPoseTick=%d, want %d", alice.lastPoseTick, pw.w.tick)
	}
	moved := 0
	for i := 0; i < 100 && alice.walking(); i++ {
		before := alice.pos
		pw.w.step()
		if alice.pos == before {
			continue
		}
		moved++
		if alice.lastPoseTick != pw.w.tick {
			t.Fatalf("step %d lastPoseTick=%d, want %d while approaching", i, alice.lastPoseTick, pw.w.tick)
		}
	}
	if alice.walking() {
		t.Fatalf("still walking after steps: remaining=%v pos=%v", alice.remaining, alice.pos)
	}
	if moved == 0 {
		t.Fatal("approach never moved")
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

func TestJumpStartsVerticalMotion(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{DX: 0, DZ: 0, Jump: true}, 0)
	if alice.vy != JumpSpeed {
		t.Fatalf("vy=%v, want JumpSpeed %v", alice.vy, JumpSpeed)
	}
	if alice.grounded() {
		t.Fatal("jump left player grounded")
	}
	pw.w.step()
	dt := TickDuration.Seconds()
	wantVY := JumpSpeed - Gravity*dt
	wantY := wantVY * dt
	if math.Abs(alice.vy-wantVY) > 1e-9 {
		t.Fatalf("vy=%v, want %v", alice.vy, wantVY)
	}
	if math.Abs(alice.y-wantY) > 1e-9 {
		t.Fatalf("y=%v, want %v", alice.y, wantY)
	}
	if alice.lastPoseTick != pw.w.tick {
		t.Fatalf("lastPoseTick=%d, want %d after airborne step", alice.lastPoseTick, pw.w.tick)
	}
}

func TestJumpWhileWalkingKeepsSteer(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0, Jump: true}, 0)
	if !alice.steering() {
		t.Fatal("jump+wish cleared steer")
	}
	if alice.vy != JumpSpeed {
		t.Fatalf("vy=%v, want JumpSpeed", alice.vy)
	}
	pw.w.step()
	wantX := WalkSpeed * TickDuration.Seconds()
	if math.Abs(alice.pos.X-wantX) > 1e-9 {
		t.Fatalf("x=%v, want %v", alice.pos.X, wantX)
	}
	if alice.y <= 0 {
		t.Fatalf("y=%v, want airborne", alice.y)
	}
}

func TestJumpLandsOnGround(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{Jump: true}, 0)
	landed := false
	for range 200 {
		pw.w.step()
		if alice.grounded() {
			landed = true
			break
		}
	}
	if !landed {
		t.Fatalf("never landed: y=%v vy=%v", alice.y, alice.vy)
	}
	if alice.y != 0 || alice.vy != 0 {
		t.Fatalf("land pose y=%v vy=%v, want zeros", alice.y, alice.vy)
	}
}

func TestMidAirJumpRefused(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0, Jump: true}, 0)
	pw.w.step()
	if alice.grounded() {
		t.Fatal("expected airborne before second jump")
	}
	beforeVY := alice.vy
	beforeX := alice.pos.X
	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Move{DX: 1, DZ: 0, Jump: true},
		Seq:  1,
	})
	if alice.vy != beforeVY {
		t.Fatalf("mid-air jump changed vy %v→%v", beforeVY, alice.vy)
	}
	if !alice.steering() {
		t.Fatal("mid-air refuse dropped wish")
	}
	rejected := pw.events(EvMoveRejected)
	if len(rejected) != 1 {
		t.Fatalf("rejection events=%v", rejected)
	}
	if got := rejected[0]["reason"]; got != string(mnet.ReasonIllegalSample) {
		t.Fatalf("reason=%v, want %s", got, mnet.ReasonIllegalSample)
	}
	pw.w.step()
	wantX := beforeX + WalkSpeed*TickDuration.Seconds()
	if math.Abs(alice.pos.X-wantX) > 1e-9 {
		t.Fatalf("x=%v, want wish to keep integrating to %v", alice.pos.X, wantX)
	}
}

func TestJumpCancelsPendingAttack(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	hostile := pw.seedHostile()
	hostile.pos = Point{X: 1, Z: 0}
	alice.pos = Point{X: 0, Z: 0}
	pw.w.attack(alice, mnet.Attack{Player: hostile.id}, 0)
	pw.w.step()

	pw.w.move(alice, mnet.Move{DX: -1, DZ: 0, Jump: true}, 0)
	if alice.attackTarget != 0 {
		t.Fatalf("pending attack survived jump+move: target=%d", alice.attackTarget)
	}
	if alice.vy != JumpSpeed {
		t.Fatalf("vy=%v, want JumpSpeed after canceling move", alice.vy)
	}
	cancelled := pw.events(EvAttackCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != CauseMove {
		t.Fatalf("cancel events=%v, want one cause=%s", cancelled, CauseMove)
	}
}
