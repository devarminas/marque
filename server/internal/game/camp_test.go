package game

import (
	"encoding/json"
	"testing"
	"time"

	mrand "math/rand/v2"

	"github.com/coder/websocket"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func seedDeterministicCamp(t *testing.T, w *World) *camp {
	t.Helper()
	w.rng = mrand.New(mrand.NewPCG(1, 2))
	if err := w.SeedImpCamp(); err != nil {
		t.Fatal(err)
	}
	if len(w.camps) != 1 {
		t.Fatalf("camps=%d, want 1", len(w.camps))
	}
	return w.camps[0]
}

func TestSeedImpCampWelcome(t *testing.T) {
	pw := newProbeWorld(t)
	c := seedDeterministicCamp(t, pw.w)
	states := pw.w.npcStates()
	if len(states) != ImpCampPoolMax {
		t.Fatalf("npcs=%d, want %d", len(states), ImpCampPoolMax)
	}
	for _, s := range states {
		if s.Kind != KindImp || s.Faction != FactionHostile {
			t.Fatalf("state=%+v", s)
		}
		if s.HP != ImpMaxHP || s.MaxHP != ImpMaxHP {
			t.Fatalf("hp=%d/%d, want %d", s.HP, s.MaxHP, ImpMaxHP)
		}
		pos := Point{X: s.X, Z: s.Z}
		if distanceBetween(pos, c.content.Center) > c.content.Radius+1e-9 {
			t.Fatalf("imp outside camp radius: pos=%v center=%v r=%v", pos, c.content.Center, c.content.Radius)
		}
	}
	spawned := pw.events(EvNpcSpawned)
	if len(spawned) != ImpCampPoolMax {
		t.Fatalf("npc_spawned=%d, want %d", len(spawned), ImpCampPoolMax)
	}
	for _, ev := range spawned {
		if ev["camp"] != CampStarterTownImps {
			t.Fatalf("spawn missing camp: %v", ev)
		}
	}
	imp := pw.w.npcByKind(KindImp)
	if imp == nil || imp.camp != CampStarterTownImps {
		t.Fatalf("camp unset: %+v", imp)
	}
	if imp.home != imp.pos {
		t.Fatalf("home=%v pos=%v", imp.home, imp.pos)
	}
}

func TestImpDeathRemovesInstanceAndLogs(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	c := seedDeterministicCamp(t, pw.w)
	c.content.JitterTicks = 0
	c.content.DeathTimerTicks = 100
	imp := pw.w.npcByKind(KindImp)
	impID := imp.id
	alice.pos = imp.pos
	imp.hp = AttackDamage

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if _, ok := pw.w.npcs[impID]; ok {
		t.Fatal("dead imp still in world")
	}
	if pw.w.campLiveCount(c) != ImpCampPoolMax-1 {
		t.Fatalf("live=%d, want %d", pw.w.campLiveCount(c), ImpCampPoolMax-1)
	}
	deaths := pw.events(EvDeath)
	if len(deaths) != 1 || deaths[0]["npc"] != float64(impID) || deaths[0]["camp"] != CampStarterTownImps {
		t.Fatalf("death=%v", deaths)
	}
	despawns := pw.events(EvNPCDespawned)
	if len(despawns) != 1 || despawns[0]["camp"] != CampStarterTownImps {
		t.Fatalf("npc_despawned=%v", despawns)
	}
	if alice.attackTarget != 0 {
		t.Fatalf("attacker still locked on despawned imp: %d", alice.attackTarget)
	}
}

func TestCampRespawnAfterDeathTimer(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	c := seedDeterministicCamp(t, pw.w)
	c.content.JitterTicks = 0
	c.content.DeathTimerTicks = 5
	imp := pw.w.npcByKind(KindImp)
	alice.pos = imp.pos
	imp.hp = AttackDamage
	beforeSpawned := len(pw.events(EvNpcSpawned))

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if pw.w.campLiveCount(c) != ImpCampPoolMax-1 {
		t.Fatalf("after death live=%d", pw.w.campLiveCount(c))
	}
	for range 4 {
		pw.w.step()
	}
	if pw.w.campLiveCount(c) != ImpCampPoolMax-1 {
		t.Fatal("respawned before death timer elapsed")
	}
	pw.w.step()
	if pw.w.campLiveCount(c) != ImpCampPoolMax {
		t.Fatalf("after timer live=%d, want %d", pw.w.campLiveCount(c), ImpCampPoolMax)
	}
	spawned := pw.events(EvNpcSpawned)
	if len(spawned) != beforeSpawned+1 {
		t.Fatalf("npc_spawned count=%d, want %d", len(spawned), beforeSpawned+1)
	}
	last := spawned[len(spawned)-1]
	if last["camp"] != CampStarterTownImps {
		t.Fatalf("respawn log=%v", last)
	}
	pos := Point{X: last["x"].(float64), Z: last["z"].(float64)}
	if distanceBetween(pos, c.content.Center) > c.content.Radius+1e-9 {
		t.Fatalf("respawn outside radius: %v", pos)
	}
}

func TestCampRespawnBroadcastsNpcSpawn(t *testing.T) {
	pw := newClassProbe(t)
	c := seedDeterministicCamp(t, pw.w)
	c.content.JitterTicks = 0
	c.content.DeathTimerTicks = 5

	peer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	_ = drainJoin(t, peer.ws)
	alice := pw.equipClass(pw.w.order[len(pw.w.order)-1], "knight")

	imp := pw.w.npcByKind(KindImp)
	deadID := imp.id
	alice.pos = imp.pos
	imp.hp = AttackDamage

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if _, ok := pw.w.npcs[deadID]; ok {
		t.Fatal("dead imp still in world")
	}

	for range 4 {
		pw.w.step()
	}
	pw.w.step()
	if pw.w.campLiveCount(c) != ImpCampPoolMax {
		t.Fatalf("after timer live=%d, want %d", pw.w.campLiveCount(c), ImpCampPoolMax)
	}

	frame := awaitWireKind(t, peer.ws, "npc_spawn", 2*time.Second)
	var spawn mnet.NpcSpawn
	if err := json.Unmarshal(frame, &spawn); err != nil {
		t.Fatalf("npc_spawn: %v: %s", err, frame)
	}
	if spawn.ID == deadID {
		t.Fatalf("npc_spawn reused dead id %d", deadID)
	}
	if spawn.Kind != KindImp || spawn.Faction != FactionHostile {
		t.Fatalf("npc_spawn=%+v", spawn)
	}
	if spawn.HP != ImpMaxHP || spawn.MaxHP != ImpMaxHP {
		t.Fatalf("npc_spawn hp=%d/%d", spawn.HP, spawn.MaxHP)
	}
	pos := Point{X: spawn.X, Z: spawn.Z}
	if distanceBetween(pos, c.content.Center) > c.content.Radius+1e-9 {
		t.Fatalf("npc_spawn outside radius: %v", pos)
	}
	if _, ok := pw.w.npcs[spawn.ID]; !ok {
		t.Fatalf("npc_spawn id %d missing from world", spawn.ID)
	}
}

func awaitWireKind(t *testing.T, ws *websocket.Conn, want string, within time.Duration) json.RawMessage {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		kind, body, ok := readHeartbeatFrame(t, ws, time.Until(deadline))
		if !ok {
			break
		}
		if kind == want {
			return body
		}
	}
	t.Fatalf("no %q frame within %v", want, within)
	return nil
}

func TestCampNeverExceedsPoolMax(t *testing.T) {
	pw := newProbeWorld(t)
	c := seedDeterministicCamp(t, pw.w)
	c.content.JitterTicks = 0
	c.content.DeathTimerTicks = 1
	c.pending = []int64{pw.w.tick + 1, pw.w.tick + 1, pw.w.tick + 1}
	pw.w.step()
	if pw.w.campLiveCount(c) != ImpCampPoolMax {
		t.Fatalf("live=%d, want cap %d", pw.w.campLiveCount(c), ImpCampPoolMax)
	}
	if len(c.pending) != 3 {
		t.Fatalf("pending drained under cap: %v", c.pending)
	}
}

func TestCampRespawnDelayIncludesJitter(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	c := seedDeterministicCamp(t, pw.w)
	c.content.DeathTimerTicks = 10
	c.content.JitterTicks = 5
	pw.w.rng = mrand.New(mrand.NewPCG(9, 9))
	imp := pw.w.npcByKind(KindImp)
	alice.pos = imp.pos
	imp.hp = AttackDamage

	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 1)
	for range pw.playerPeriod(alice) {
		pw.w.step()
	}
	if len(c.pending) != 1 {
		t.Fatalf("pending=%v", c.pending)
	}
	delay := c.pending[0] - pw.w.tick
	if delay < 10 || delay > 15 {
		t.Fatalf("delay=%d, want in [10,15]", delay)
	}
}

func TestCampPendingStaysSortedUnderJitter(t *testing.T) {
	pw := newProbeWorld(t)
	c := seedDeterministicCamp(t, pw.w)
	c.content.DeathTimerTicks = 10
	c.content.JitterTicks = 20
	pw.w.rng = mrand.New(mrand.NewPCG(3, 7))
	for range 8 {
		pw.w.scheduleCampRespawn(c)
	}
	for i := 1; i < len(c.pending); i++ {
		if c.pending[i] < c.pending[i-1] {
			t.Fatalf("pending not sorted: %v", c.pending)
		}
	}
}
