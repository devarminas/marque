// Package game owns every piece of authoritative state and the tick loop that
// mutates it. Exactly one goroutine runs World.Run, and it is the only thing
// that touches world state. PROTOCOL.md is the contract this implements.
package game

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math"
	"time"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// TickDuration is the tick. The tick counter is the clock; nothing in game
// logic reads wall-clock time (NOTES.md, "Tick rate").
const TickDuration = 150 * time.Millisecond

// MaxCatchUpTicks bounds how far the loop catches up in one wake-up. Beyond it
// the backlog is discarded and the drop is logged (PROTOCOL.md, "Clock").
const MaxCatchUpTicks = 5

// WalkSpeed is how fast a player walks, in world units per second; broadcast in
// every path message. Tuning: ARM-13.
const WalkSpeed = 3.0

// WorldHalfExtent bounds the playable square, centred on the origin: legal
// coordinates are x, z in [-WorldHalfExtent, +WorldHalfExtent], inclusive
// (PROTOCOL.md, "Validation").
const WorldHalfExtent = 128.0

// MinPathLength is how near a click has to land before it counts as a click on
// the ground the player is already standing on. Below it, no walk is assigned.
const MinPathLength = 1e-3

// ResumeGraceTicks is how long a player's body stays in the world after its
// socket died abruptly, in ticks. Tuning: ARM-58.
const ResumeGraceTicks = int64(60 * time.Second / TickDuration)

// HeartbeatEveryTicks is how often the server broadcasts tick, in ticks; sent
// on every welcome as heartbeat_ticks (PROTOCOL.md, "Clock").
const HeartbeatEveryTicks = 10

const (
	spawnX = 0.0
	spawnZ = 0.0
)

// Event names in the NDJSON log.
const (
	EvServerStarted  = "server_started"
	EvServerStopping = "server_stopping"
	EvConnected      = "client_connected"
	EvDisconnected   = "client_disconnected"
	EvMoveTo         = "move_to"
	EvMoveToRejected = "move_to_rejected"
	EvIntentIgnored  = "intent_ignored"
	// EvIntentDuplicate: seq at or below the sender's high-water mark; nothing
	// is sent back (PROTOCOL.md, "Sequence numbers").
	EvIntentDuplicate = "intent_duplicate"
	EvPathAssigned    = "path_assigned"
	EvArrived         = "arrived"
	EvTicksDropped    = "ticks_dropped"

	// EvPlayerSuspended follows the EvDisconnected for the same death.
	EvPlayerSuspended = "player_suspended"

	EvPlayerResumed = "player_resumed"

	EvPlayerExpired = "player_expired"

	// EvResumeRefused names only the remote address; no player exists for it.
	EvResumeRefused = "resume_refused"

	EvResumeUnknown = "resume_unknown"

	// EvPathReplayed is one path frame unicast to a joining client:
	// EvPathAssigned's fields plus "to".
	EvPathReplayed = "path_replayed"

	EvFrameDropped = "frame_dropped"

	// EvItemSpawned is an item entering the world by seed or by drop; it carries
	// the item only, never the causer.
	EvItemSpawned = "item_spawned"

	EvPickup = "pickup"

	EvPickupRejected = "pickup_rejected"

	EvPickupResolved = "pickup_resolved"

	EvPickupLost = "pickup_lost"

	EvPickupNoRoom = "pickup_no_room"

	// EvDrop is one completed drop, logged after the move with EvPickupResolved's
	// field set.
	EvDrop = "drop"

	EvDropRejected = "drop_rejected"

	// EvJoinSeeded is one item of the join kit placed in a joining player's bag.
	// It is not an EvItemSpawned: nothing entered the world and no id was minted
	// (PROTOCOL.md, "The join kit").
	EvJoinSeeded = "join_seeded"

	// EvEquip is one completed equip, logged after the move. "displaced" is
	// present only when a swap put something back in the bag.
	EvEquip = "equip"

	EvEquipRejected = "equip_rejected"

	// EvUnequip is one completed unequip, logged after the move.
	EvUnequip = "unequip"

	EvUnequipRejected = "unequip_rejected"

	EvNodeSpawned = "node_spawned"

	EvGather = "gather"

	EvGatherRejected = "gather_rejected"

	EvGatherResolved = "gather_resolved"

	EvGatherLost = "gather_lost"

	EvGatherCancelled = "gather_cancelled"

	EvGatherNoRoom = "gather_no_room"

	EvNodeDepleted = "node_depleted"

	EvNodeRespawned = "node_respawned"
)

// Transport is the world's view of the network: a stream of connection events.
// Replies go back through the *mnet.Conn each event carries.
type Transport interface {
	Events() <-chan mnet.Event
}

const sessionTokenBytes = 16

func newSessionToken() string {
	var raw [sessionTokenBytes]byte
	if _, err := rand.Read(raw[:]); err != nil {
		panic(fmt.Sprintf("game: reading %d bytes for a session token: %v", sessionTokenBytes, err))
	}
	return hex.EncodeToString(raw[:])
}

type player struct {
	id mnet.PlayerID

	session string

	conn *mnet.Conn

	pos Point

	remaining []Point

	pending mnet.ItemID

	gatherNode     mnet.NodeID
	gatherProgress int

	lastSeq mnet.Seq

	expiresTick int64
}

func (p *player) walking() bool { return len(p.remaining) > 0 }

func (p *player) suspended() bool { return p.conn == nil }

// World is the authoritative game state.
type World struct {
	transport Transport
	log       *gamelog.Logger

	items Store

	nodes      map[mnet.NodeID]*resourceNode
	nodeOrder  []mnet.NodeID
	nextNodeID mnet.NodeID

	tick   int64
	nextID mnet.PlayerID

	resumeGrace int64

	joinKit []string

	players map[mnet.PlayerID]*player

	byConn map[*mnet.Conn]*player

	bySession map[string]*player

	order []*player
}

// NewWorld returns an empty world reading intents from transport and keeping
// items in store, holding a suspended player for resumeGrace ticks and giving
// every joining player one item per kind in joinKit. resumeGrace must be at
// least 1, joinKit may be empty, and the store must be used by nobody else.
//
// The kit is a parameter rather than a constant for resumeGrace's reason: it is
// a tunable, and a test that wants a world whose joining players carry nothing
// is asking about the rest of the game rather than about the kit.
func NewWorld(transport Transport, log *gamelog.Logger, store Store, resumeGrace int64, joinKit []string) *World {
	if transport == nil {
		panic("game: nil transport")
	}
	if store == nil {
		panic("game: nil store")
	}
	if resumeGrace < 1 {
		panic(fmt.Sprintf("game: resume grace of %d ticks; it must be at least 1", resumeGrace))
	}
	return &World{
		transport:   transport,
		log:         log,
		items:       store,
		nodes:       make(map[mnet.NodeID]*resourceNode),
		resumeGrace: resumeGrace,
		joinKit:     joinKit,
		players:     make(map[mnet.PlayerID]*player),
		byConn:      make(map[*mnet.Conn]*player),
		bySession:   make(map[string]*player),
	}
}

// Run drives the world until ctx is cancelled. It must be called on exactly one
// goroutine.
func (w *World) Run(ctx context.Context) {
	ticker := time.NewTicker(TickDuration)
	defer ticker.Stop()

	last := time.Now()
	var owed time.Duration

	events := w.transport.Events()
	for {
		select {
		case <-ctx.Done():
			w.log.Event(w.tick, EvServerStopping, gamelog.Fields{"players": len(w.order)})
			return
		case ev := <-events:
			w.handle(ev)
		case now := <-ticker.C:
			owed += now.Sub(last)
			last = now
			w.stepAll(&owed)
		}
	}
}

func (w *World) stepAll(owed *time.Duration) {
	due := int(*owed / TickDuration)
	if due <= 0 {
		return
	}
	*owed -= time.Duration(due) * TickDuration

	if due > MaxCatchUpTicks {
		w.log.Event(w.tick, EvTicksDropped, gamelog.Fields{
			"due":     due,
			"ran":     MaxCatchUpTicks,
			"dropped": due - MaxCatchUpTicks,
		})
		due = MaxCatchUpTicks
	}
	for range due {
		w.step()
	}
}

func (w *World) step() {
	w.tick++
	if w.tick%HeartbeatEveryTicks == 0 {
		w.broadcast(mnet.Tick{T: w.tick}, nil)
	}
	distance := WalkSpeed * TickDuration.Seconds()

	for _, p := range w.order {
		if !p.walking() {
			continue
		}
		p.pos, p.remaining = Advance(p.pos, p.remaining, distance)
		if !p.walking() {
			w.log.Event(w.tick, EvArrived, gamelog.Fields{
				"player": p.id,
				"x":      p.pos.X,
				"z":      p.pos.Z,
			})
		}
	}

	for _, p := range w.order {
		if p.pending != 0 {
			w.resolvePickup(p)
		}
		if p.gatherNode != 0 {
			w.resolveGather(p)
		}
	}

	w.respawnNodes()
	w.expireSuspended()
}

func (w *World) handle(ev mnet.Event) {
	switch ev.Kind {
	case mnet.EventConnected:
		w.admit(ev.Conn)
	case mnet.EventFrame:
		w.handleFrame(ev)
	case mnet.EventDisconnected:
		w.removePlayer(ev.Conn, ev.Reason, ev.Detail)
	default:
		panic(fmt.Sprintf("game: unhandled event kind %v", ev.Kind))
	}
}

func (w *World) admit(conn *mnet.Conn) {
	if _, dup := w.byConn[conn]; dup {
		panic("game: connection announced twice")
	}

	token := conn.Session()
	if token == "" {
		w.addPlayer(conn)
		return
	}

	claimed, known := w.bySession[token]
	switch {
	case !known:
		w.log.Event(w.tick, EvResumeUnknown, gamelog.Fields{"remote": conn.Remote()})
		w.addPlayer(conn)
	case !claimed.suspended():
		w.refuseResume(conn)
	default:
		w.resumePlayer(claimed, conn)
	}
}

func (w *World) refuseResume(conn *mnet.Conn) {
	w.log.Event(w.tick, EvResumeRefused, gamelog.Fields{"remote": conn.Remote()})
	conn.Send(mustEncode(mnet.Error{Msg: "session is still connected"}))
	conn.CloseAfterFlush(mnet.DisconnectRefused)
}

func (w *World) resumePlayer(p *player, conn *mnet.Conn) {
	p.conn = conn
	p.expiresTick = 0
	w.byConn[conn] = p

	w.log.Event(w.tick, EvPlayerResumed, gamelog.Fields{
		"player": p.id,
		"remote": conn.Remote(),
	})

	w.sendJoinStep(p)
}

func (w *World) addPlayer(conn *mnet.Conn) {
	w.nextID++
	p := &player{
		id:      w.nextID,
		session: newSessionToken(),
		conn:    conn,
		pos:     Point{X: spawnX, Z: spawnZ},
	}
	w.players[p.id] = p
	w.byConn[conn] = p
	w.bySession[p.session] = p
	w.order = append(w.order, p)
	w.items.AddPlayer(p.id)

	w.log.Event(w.tick, EvConnected, gamelog.Fields{
		"player": p.id,
		"remote": conn.Remote(),
	})

	w.seedJoinKit(p)
	w.sendJoinStep(p)
	w.broadcast(mnet.Spawn{ID: p.id, X: p.pos.X, Z: p.pos.Z}, p)
}

func (w *World) sendJoinStep(p *player) {
	states := make([]mnet.PlayerState, 0, len(w.order))
	for _, other := range w.order {
		states = append(states, mnet.PlayerState{ID: other.id, X: other.pos.X, Z: other.pos.Z})
	}
	w.send(p, mnet.Welcome{
		You:            p.id,
		Session:        p.session,
		LastSeq:        p.lastSeq,
		TickMS:         int(TickDuration.Milliseconds()),
		Tick:           w.tick,
		HeartbeatTicks: HeartbeatEveryTicks,
		Players:        states,
		Items:          w.groundItemStates(),
		Nodes:          w.nodeStates(),
	})

	for _, other := range w.order {
		if !other.walking() {
			continue
		}
		replay := w.pathMessage(other)
		fields := pathLogFields(replay)
		fields["to"] = p.id
		w.log.Event(w.tick, EvPathReplayed, fields)
		w.send(p, replay)
	}

	w.sendInventory(p)
	w.sendEquipment(p)
}

func suspends(reason string) bool {
	return reason == mnet.DisconnectPeerGone || reason == mnet.DisconnectSlow
}

func (w *World) removePlayer(conn *mnet.Conn, reason, detail string) {
	p, ok := w.byConn[conn]
	if !ok {
		return
	}

	fields := gamelog.Fields{
		"player": p.id,
		"reason": reason,
	}
	if detail != "" {
		fields["detail"] = detail
	}
	w.log.Event(w.tick, EvDisconnected, fields)

	if suspends(reason) {
		w.suspend(p)
		return
	}
	w.retire(p)
}

func (w *World) suspend(p *player) {
	delete(w.byConn, p.conn)
	p.conn = nil
	p.expiresTick = w.tick + w.resumeGrace

	w.log.Event(w.tick, EvPlayerSuspended, gamelog.Fields{
		"player":       p.id,
		"expires_tick": p.expiresTick,
	})
}

func (w *World) expireSuspended() {
	var expired []*player
	for _, p := range w.order {
		if p.suspended() && w.tick >= p.expiresTick {
			expired = append(expired, p)
		}
	}
	for _, p := range expired {
		w.log.Event(w.tick, EvPlayerExpired, gamelog.Fields{"player": p.id})
		w.retire(p)
	}
}

func (w *World) retire(p *player) {
	delete(w.players, p.id)
	delete(w.bySession, p.session)
	if p.conn != nil {
		delete(w.byConn, p.conn)
	}
	for i, other := range w.order {
		if other == p {
			w.order = append(w.order[:i], w.order[i+1:]...)
			break
		}
	}
	w.items.RemovePlayer(p.id)

	w.broadcast(mnet.Despawn{ID: p.id}, p)
}

func (w *World) handleFrame(ev mnet.Event) {
	p, ok := w.byConn[ev.Conn]
	if !ok {
		w.log.Event(w.tick, EvFrameDropped, gamelog.Fields{
			"reason": string(mnet.ReasonUnknownSender),
			"remote": ev.Conn.Remote(),
		})
		return
	}

	if ev.Seq != 0 {
		if ev.Seq <= p.lastSeq {
			w.log.Event(w.tick, EvIntentDuplicate, gamelog.Fields{
				"player":   p.id,
				"re":       ev.Name(),
				"seq":      ev.Seq,
				"last_seq": p.lastSeq,
			})
			return
		}
		p.lastSeq = ev.Seq
	}

	if ev.Err != nil {
		rejection, ok := mnet.Rejection(ev.Err)
		if !ok {
			panic(fmt.Sprintf("game: frame error without a rejection: %v", ev.Err))
		}
		w.refuse(p, rejection)
		return
	}

	switch msg := ev.Msg.(type) {
	case mnet.MoveTo:
		w.moveTo(p, msg, ev.Seq)
	case mnet.Pickup:
		w.pickup(p, msg, ev.Seq)
	case mnet.Drop:
		w.drop(p, msg, ev.Seq)
	case mnet.Equip:
		w.equip(p, msg, ev.Seq)
	case mnet.Unequip:
		w.unequip(p, msg, ev.Seq)
	case mnet.Gather:
		w.gather(p, msg, ev.Seq)
	default:
		panic(fmt.Sprintf("game: unhandled client message %T", ev.Msg))
	}
}

func (w *World) refuse(p *player, rejection *mnet.RejectError) {
	fields := gamelog.Fields{
		"player": p.id,
		"reason": string(rejection.Reason),
		"detail": rejection.Detail,
	}
	if rejection.Re != "" {
		fields["re"] = rejection.Re
	}

	if rejection.Disposition == mnet.Ignore {
		w.log.Event(w.tick, EvIntentIgnored, fields)
		return
	}

	w.log.Event(w.tick, rejectionEvent(rejection.Re), fields)
	w.send(p, mnet.Error{Re: rejection.Re, Msg: rejection.Detail})
	if rejection.Disposition == mnet.ReplyErrorAndClose {
		p.conn.CloseAfterFlush(mnet.DisconnectProtocol)
	}
}

func rejectionEvent(re string) string {
	switch re {
	case mnet.MsgMoveTo, "":
		return EvMoveToRejected
	case mnet.MsgPickup:
		return EvPickupRejected
	case mnet.MsgDrop:
		return EvDropRejected
	case mnet.MsgEquip:
		return EvEquipRejected
	case mnet.MsgUnequip:
		return EvUnequipRejected
	case mnet.MsgGather:
		return EvGatherRejected
	default:
		panic(fmt.Sprintf("game: no rejection event for %q", re))
	}
}

func withSeq(f gamelog.Fields, seq mnet.Seq) gamelog.Fields {
	if seq != 0 {
		f["seq"] = seq
	}
	return f
}

func (w *World) moveTo(p *player, msg mnet.MoveTo, seq mnet.Seq) {
	w.log.Event(w.tick, EvMoveTo, withSeq(gamelog.Fields{
		"player": p.id,
		"x":      msg.X,
		"z":      msg.Z,
	}, seq))

	if rejection := w.validate(msg); rejection != nil {
		w.refuse(p, rejection)
		return
	}

	points, assign := destinationPath(p, Point{X: msg.X, Z: msg.Z})
	if !assign {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonDegenerate,
			Detail:      "already there",
			Re:          mnet.MsgMoveTo,
			Disposition: mnet.ReplyError,
		})
		return
	}

	p.pending = 0
	w.cancelGather(p)
	w.assignPath(p, points)
}

func destinationPath(p *player, dest Point) (points []Point, assign bool) {
	line := StraightLine(p.pos, dest)
	if length(line) >= MinPathLength {
		return line, true
	}
	if p.walking() {
		return []Point{p.pos}, true
	}
	return nil, false
}

func (w *World) assignPath(p *player, points []Point) {
	p.remaining = points[1:]

	out := mnet.Path{
		ID:        p.id,
		StartTick: w.tick,
		Points:    wirePoints(points),
		Speed:     WalkSpeed,
	}
	w.log.Event(w.tick, EvPathAssigned, pathLogFields(out))
	w.broadcast(out, nil)
}

func pathLogFields(msg mnet.Path) gamelog.Fields {
	return gamelog.Fields{
		"player":     msg.ID,
		"start_tick": msg.StartTick,
		"points":     msg.Points,
		"speed":      msg.Speed,
	}
}

func (w *World) validate(msg mnet.MoveTo) *mnet.RejectError {
	reason, detail := checkCoordinates(msg.X, msg.Z)
	if reason == "" {
		return nil
	}
	return &mnet.RejectError{
		Reason:      reason,
		Detail:      mnet.MsgMoveTo + ": " + detail,
		Re:          mnet.MsgMoveTo,
		Disposition: mnet.ReplyError,
	}
}

func checkCoordinates(x, z float64) (mnet.RejectReason, string) {
	if !finite(x) || !finite(z) {
		return mnet.ReasonNonFinite, "coordinates must be finite"
	}
	if math.Abs(x) > WorldHalfExtent || math.Abs(z) > WorldHalfExtent {
		return mnet.ReasonOutOfBounds, fmt.Sprintf("out of bounds: x and z must be within +/-%v", WorldHalfExtent)
	}
	return "", ""
}

func (w *World) pathMessage(p *player) mnet.Path {
	points := make([]Point, 0, len(p.remaining)+1)
	points = append(points, p.pos)
	points = append(points, p.remaining...)
	return mnet.Path{
		ID:        p.id,
		StartTick: w.tick,
		Points:    wirePoints(points),
		Speed:     WalkSpeed,
	}
}

func (w *World) send(p *player, msg mnet.ServerMessage) {
	if p.conn == nil {
		return
	}
	p.conn.Send(mustEncode(msg))
}

func (w *World) broadcast(msg mnet.ServerMessage, skip *player) {
	payload := mustEncode(msg)
	for _, p := range w.order {
		if p == skip || p.conn == nil {
			continue
		}
		p.conn.Send(payload)
	}
}

func mustEncode(msg mnet.ServerMessage) []byte {
	payload, err := mnet.Encode(msg)
	if err != nil {
		panic(fmt.Sprintf("game: encoding %T: %v", msg, err))
	}
	return payload
}

func length(points []Point) float64 {
	var total float64
	for i := 1; i < len(points); i++ {
		total += math.Hypot(points[i].X-points[i-1].X, points[i].Z-points[i-1].Z)
	}
	return total
}

func wirePoints(points []Point) []mnet.Point {
	out := make([]mnet.Point, len(points))
	for i, p := range points {
		out[i] = mnet.Pt(p.X, p.Z)
	}
	return out
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
