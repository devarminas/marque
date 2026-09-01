// Package game owns every piece of authoritative state and the tick loop that
// mutates it.
//
// Exactly one goroutine runs World.Run, and that goroutine is the only thing
// that ever touches world state. Connections hand it intents over a channel and
// receive pre-encoded frames over their own buffered channels, so nothing that
// blocks on a socket can block the tick (CLAUDE.md, "Architecture invariants").
//
// PROTOCOL.md at the repository root is the contract this implements.
package game

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// TickDuration is the tick. It is the only tick duration in the codebase;
// nothing else may hardcode one and nothing in game logic reads wall-clock
// time. The tick counter is the clock.
//
// Decided at 150ms and revisitable exactly once, after M1, when there is an
// inventory action to time (NOTES.md, "Tick rate"). Not configurable: a flag
// here would be a hedge against a decision that has already been made.
const TickDuration = 150 * time.Millisecond

// MaxCatchUpTicks bounds how far the loop will catch up in one wake-up when it
// has fallen behind. Beyond it the backlog is discarded and the drop is logged.
//
// Unbounded catch-up spirals: a stall produces a burst of ticks, the burst
// costs more than one tick's budget, and the backlog grows (PROTOCOL.md,
// "Clock").
const MaxCatchUpTicks = 5

// WalkSpeed is how fast a player walks, in world units per second. It is
// broadcast in every path message so the client never guesses.
//
// Placeholder: chosen to be usable, not good. Tuning it is feel, and feel is
// parked in FOLLOW-UPS.md.
const WalkSpeed = 3.0

// WorldHalfExtent bounds the playable square, centred on the origin: legal
// coordinates are x, z in [-WorldHalfExtent, +WorldHalfExtent], inclusive.
//
// M0 has no obstacles, so bounds are the whole of reachability. A destination
// outside them is rejected, never clamped and never snapped to the nearest
// legal point (PROTOCOL.md, "Validation"). Bounds are also what stops a large
// finite coordinate such as 1e30, which decodes cleanly and then overflows
// 32-bit vector math on the client. Revisitable: a placeholder chosen to be
// finite, not chosen to be right.
const WorldHalfExtent = 128.0

// MinPathLength is how near a click has to land before it counts as a click on
// the ground the player is already standing on. Below it, no walk is assigned:
// a zero-length segment makes the client's interpolator divide by zero and
// produce a NaN position, which is painful to trace back here from there.
//
// One millimetre of world. Nobody intends a walk that short, and it is far
// enough above 32-bit float noise near the world edge to be meaningful there.
// Revisitable.
const MinPathLength = 1e-3

// Spawn point. Everyone enters the world at the origin; M0 has no collision, so
// stacking is free. Revisitable once there is a map with a sensible entrance.
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
	EvPathAssigned   = "path_assigned"
	EvArrived        = "arrived"
	EvTicksDropped   = "ticks_dropped"

	// EvPathReplayed is one path frame sent to a joining client to describe a
	// walk that was already in flight. It carries the same fields as
	// EvPathAssigned plus "to", the player it was sent to, because a replay is
	// unicast to the newcomer where an assignment is broadcast to everyone.
	//
	// Deliberately not EvPathAssigned with a marker field. Nothing was decided
	// here: no intent arrived, no path was chosen, and the values differ from
	// the ones the original assignment recorded. A reader counting
	// EvPathAssigned to ask "how many times did the server choose a path" must
	// get the right answer without knowing to exclude anything, and the two
	// events do not have the same field set. The cost is that reconstructing
	// every path frame a client received means reading two event names instead
	// of one; the field names are shared so that is the whole of the cost.
	// Revisitable.
	EvPathReplayed = "path_replayed"

	// EvFrameDropped is a frame the world refused without answering it. Only
	// the unknown-sender branch reaches it, and only if the hub's ordering
	// contract has broken. It is not EvMoveToRejected: nothing there has read
	// the frame's kind yet, so naming one would be a claim the code cannot
	// make.
	EvFrameDropped = "frame_dropped"

	// Item and pickup events. Every change to where an item is has its own
	// name, for EvPathReplayed's reason: a reader counting one outcome must get
	// the right answer without knowing to exclude anything, and these five do
	// not share a field set.
	//
	// EvItemSpawned is an item entering the world. Seeding is the only way in
	// M1a; M1b's drop is the second, and it reuses this name because it is the
	// same state change with the same fields.
	EvItemSpawned = "item_spawned"
	// EvPickup is the intent arriving. It records what the client asked for,
	// before the server has decided anything about it.
	EvPickup = "pickup"
	// EvPickupRejected is a pickup refused outright, which in M1a means it
	// named no live ground item or its body would not decode. It carries the
	// rejection's fields, not a pickup's, because it shares refuse with
	// move_to.
	EvPickupRejected = "pickup_rejected"
	// EvPickupResolved is the item changing hands: one winner, one slot, in one
	// tick. It is the only event in M1a that records an item leaving the
	// ground.
	EvPickupResolved = "pickup_resolved"
	// EvPickupLost is a pending pickup whose item was gone when the player
	// arrived. Distinct from EvPickupRejected because nothing was wrong with
	// the intent: it was legal when it was made and somebody else was faster.
	EvPickupLost = "pickup_lost"
	// EvPickupNoRoom is a pending pickup that arrived at a full inventory. The
	// item stays where it is.
	EvPickupNoRoom = "pickup_no_room"
)

// Transport is the world's view of the network: a stream of connection events.
// Replies go back through the *mnet.Conn each event carries.
type Transport interface {
	Events() <-chan mnet.Event
}

// player is one connected player's authoritative state.
type player struct {
	id   mnet.PlayerID
	conn *mnet.Conn

	// pos is the player's position at the current tick, not an interpolated
	// in-between. Clients do the interpolating.
	pos Point

	// remaining is the waypoints still ahead. Empty means standing still.
	remaining []Point

	// pending is the item this player is walking to take, or zero when there is
	// none. A player has at most one: a second pickup replaces it, and a
	// move_to cancels it, because clicking the ground says you wanted something
	// else (PROTOCOL.md, "Pickup").
	//
	// Zero is the absent value rather than a pointer or a second bool, because
	// item ids start at 1 and are never reused, so no live item can ever be
	// mistaken for "none".
	pending mnet.ItemID
}

func (p *player) walking() bool { return len(p.remaining) > 0 }

// World is the authoritative game state.
//
// Every field is owned by the goroutine running Run. No mutex guards them
// because nothing else may read or write them.
type World struct {
	transport Transport
	log       *gamelog.Logger

	// items holds every item location, on the ground and in inventories. The
	// world owns no item state of its own: asking the store is the only way to
	// learn where something is. Swapping this for a Postgres implementation is
	// the whole of what standing order 6 asks for.
	items Store

	tick   int64
	nextID mnet.PlayerID

	players map[*mnet.Conn]*player
	// order keeps iteration deterministic. Go randomises map iteration, which
	// would make welcome's player list and broadcast order differ run to run,
	// and replay diffs are only useful when two identical runs agree. It is
	// also the tiebreaker for a contested pickup, so it is load-bearing for
	// game rules and not only for logs.
	order []*mnet.Conn
}

// NewWorld returns an empty world reading intents from transport and keeping
// items in store.
//
// The store must be used by nobody else. Once Run starts, its goroutine is the
// only thing allowed to touch it.
func NewWorld(transport Transport, log *gamelog.Logger, store Store) *World {
	if transport == nil {
		panic("game: nil transport")
	}
	if store == nil {
		panic("game: nil store")
	}
	return &World{
		transport: transport,
		log:       log,
		items:     store,
		players:   make(map[*mnet.Conn]*player),
	}
}

// Run drives the world until ctx is cancelled. It must be called on exactly one
// goroutine, and that goroutine owns all world state for its lifetime.
func (w *World) Run(ctx context.Context) {
	ticker := time.NewTicker(TickDuration)
	defer ticker.Stop()

	// The monotonic clock is used to decide when a tick happens and for nothing
	// else. No game rule reads it, and the tick counter remains the clock.
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

// stepAll runs every whole tick the elapsed time has earned, up to the
// catch-up bound, and leaves the sub-tick remainder in owed.
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

// step advances one tick. It is the transaction boundary: everything one tick
// decides is decided here, on this goroutine, with nothing observable in
// between.
//
// Movement and pickup resolution are two passes rather than one, so that "a
// pending pickup resolves after movement has advanced" (PROTOCOL.md, "Pickup")
// is true of every player and not only of the player being visited. The passes
// happen to be equivalent today, because resolving reads only the resolving
// player's own position; the day a rule reads somebody else's, one pass would
// be wrong and nothing would say so.
func (w *World) step() {
	w.tick++
	distance := WalkSpeed * TickDuration.Seconds()

	for _, conn := range w.order {
		p := w.players[conn]
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

	// Join order, deliberately: the first player in w.order who has a pending
	// pickup for an item and is near enough to it takes it, and every later
	// player in this same pass finds it gone. Never a range over w.players,
	// whose iteration order Go randomises; the winner of a contest must be the
	// same in two identical runs.
	for _, conn := range w.order {
		if p := w.players[conn]; p.pending != 0 {
			w.resolvePickup(p)
		}
	}
}

func (w *World) handle(ev mnet.Event) {
	switch ev.Kind {
	case mnet.EventConnected:
		w.addPlayer(ev.Conn)
	case mnet.EventFrame:
		w.handleFrame(ev)
	case mnet.EventDisconnected:
		w.removePlayer(ev.Conn, ev.Reason)
	default:
		panic(fmt.Sprintf("game: unhandled event kind %v", ev.Kind))
	}
}

// addPlayer admits a connection to the world.
//
// Welcome and its path replays are composed and enqueued here, in one step, on
// the goroutine that owns the world. Nothing interleaves with it, so any
// broadcast enqueued afterwards is seen by the newcomer and any broadcast
// before it is not. That is what keeps two clients joining in the same tick
// from either missing a player or seeing one twice.
func (w *World) addPlayer(conn *mnet.Conn) {
	if _, dup := w.players[conn]; dup {
		panic("game: connection announced twice")
	}

	w.nextID++
	p := &player{id: w.nextID, conn: conn, pos: Point{X: spawnX, Z: spawnZ}}
	w.players[conn] = p
	w.order = append(w.order, conn)
	w.items.AddPlayer(p.id)

	w.log.Event(w.tick, EvConnected, gamelog.Fields{
		"player": p.id,
		"remote": conn.Remote(),
	})

	states := make([]mnet.PlayerState, 0, len(w.order))
	for _, c := range w.order {
		other := w.players[c]
		states = append(states, mnet.PlayerState{ID: other.id, X: other.pos.X, Z: other.pos.Z})
	}
	w.send(p, mnet.Welcome{
		You:     p.id,
		TickMS:  int(TickDuration.Milliseconds()),
		Tick:    w.tick,
		Players: states,
		Items:   w.groundItemStates(),
	})

	// Everyone already mid-walk is described to the newcomer with an ordinary
	// path message, so a joining client learns in-flight movement through the
	// same code path it uses for live movement. There is no snapshot format for
	// paths, and there is nothing here for the newcomer to special-case.
	//
	// Every replay is logged, once per walker. Without that the log records
	// neither the re-anchored values nor the fact that a replay happened, and
	// the only way back to what the newcomer was told is to re-simulate the
	// walk from its original path_assigned -- which nothing in the log would
	// tell a reader was necessary.
	for _, c := range w.order {
		other := w.players[c]
		if !other.walking() {
			continue
		}
		replay := w.pathMessage(other)
		fields := pathLogFields(replay)
		fields["to"] = p.id
		w.log.Event(w.tick, EvPathReplayed, fields)
		w.send(p, replay)
	}

	// Last inside the atomic step, after the replays. The inventory is the one
	// thing in the step that is about this player rather than about the world,
	// and nothing about the world may be observable to the newcomer before it
	// has been told everything the step describes (PROTOCOL.md, "Ordering and
	// the join race").
	w.sendInventory(p)

	w.broadcast(mnet.Spawn{ID: p.id, X: p.pos.X, Z: p.pos.Z}, conn)
}

// removePlayer retires a connection. This is the only place a player leaves the
// world, whichever way the connection died.
func (w *World) removePlayer(conn *mnet.Conn, reason string) {
	p, ok := w.players[conn]
	if !ok {
		// A connection the hub accepted but the world never saw, or a second
		// disconnect for one it already retired. Neither should happen; neither
		// is worth killing the server over.
		return
	}

	delete(w.players, conn)
	for i, c := range w.order {
		if c == conn {
			w.order = append(w.order[:i], w.order[i+1:]...)
			break
		}
	}
	// Whatever they were carrying leaves with them. M1 has no persistence and
	// no drop-on-logout, so this is deletion rather than a transfer to the
	// ground; making it a transfer is a design decision, not a bug fix, and it
	// is parked in FOLLOW-UPS.md.
	w.items.RemovePlayer(p.id)

	w.log.Event(w.tick, EvDisconnected, gamelog.Fields{
		"player": p.id,
		"reason": reason,
	})
	w.broadcast(mnet.Despawn{ID: p.id}, conn)
}

func (w *World) handleFrame(ev mnet.Event) {
	p, ok := w.players[ev.Conn]
	if !ok {
		// The hub emits EventConnected before any frame, so this is defensive.
		// It is logged rather than dropped because reaching it means the
		// ordering contract broke. The frame's kind has not been read at this
		// point and may not be a move_to at all, which is why the event does
		// not name one.
		w.log.Event(w.tick, EvFrameDropped, gamelog.Fields{
			"reason": string(mnet.ReasonUnknownSender),
			"remote": ev.Conn.Remote(),
		})
		return
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
		w.moveTo(p, msg)
	case mnet.Pickup:
		w.pickup(p, msg)
	default:
		panic(fmt.Sprintf("game: unhandled client message %T", ev.Msg))
	}
}

// refuse logs a refused frame and does whatever the protocol says about it.
//
// An ignored frame is logged loudly and nothing is sent: that is the narrow,
// deliberate relaxation of fail-fast that lets a client written against a later
// protocol version keep working against this server. Everything else gets one
// error message, and the frames that cannot be interpreted at all also get the
// connection closed behind it.
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

// rejectionEvent names the log event for a refusal after the message it refused.
//
// A reader asking "how many pickups did this server turn down" must not have to
// know that pickups were once logged under move_to's name. The default covers
// the frames too malformed to attribute to any message, which carry no "re" and
// which the log has always filed here.
func rejectionEvent(re string) string {
	if re == mnet.MsgPickup {
		return EvPickupRejected
	}
	return EvMoveToRejected
}

// moveTo answers a click.
//
// A second move_to mid-walk replaces the first: the new path starts at where
// the player actually is now, not at where the abandoned path began. Two
// intents inside one tick therefore both take effect in order, and the last one
// wins, because a player's position does not change between ticks.
func (w *World) moveTo(p *player, msg mnet.MoveTo) {
	w.log.Event(w.tick, EvMoveTo, gamelog.Fields{
		"player": p.id,
		"x":      msg.X,
		"z":      msg.Z,
	})

	if rejection := w.validate(msg); rejection != nil {
		w.refuse(p, rejection)
		return
	}

	dest := Point{X: msg.X, Z: msg.Z}
	points := StraightLine(p.pos, dest)

	// A click that resolves to where the player already is means one of two
	// different things, and which one depends on whether they are moving.
	if length(points) < MinPathLength {
		if !p.walking() {
			// Standing still and asked to stand still. Nothing changes, so
			// there is nothing to broadcast; the sender is told, because
			// otherwise the click is indistinguishable from a dropped frame.
			w.refuse(p, &mnet.RejectError{
				Reason:      mnet.ReasonDegenerate,
				Detail:      "already there",
				Re:          mnet.MsgMoveTo,
				Disposition: mnet.ReplyError,
			})
			return
		}
		// Walking and asked to stop. A walker holds at the final point of its
		// polyline, so a polyline of one point is a complete instruction to
		// stand still there. This is the whole of "stop walking": no separate
		// message exists, and none is needed.
		points = []Point{p.pos}
	}

	// Clicking the ground says you wanted something else, so it cancels a
	// pending pickup. Here, at the point the click actually changes where the
	// player is going, and not on entry: a click the server refuses changes
	// nothing, and an out-of-bounds coordinate must not quietly cost the player
	// the item they were already walking to.
	p.pending = 0
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

// pathLogFields describes one path frame for the event log.
//
// Both events that carry a path build their fields here, so the two cannot
// drift apart on a key name and a reader who has learned one shape has learned
// the other. EvPathReplayed adds "to" on top.
func pathLogFields(msg mnet.Path) gamelog.Fields {
	return gamelog.Fields{
		"player":     msg.ID,
		"start_tick": msg.StartTick,
		"points":     msg.Points,
		"speed":      msg.Speed,
	}
}

// validate decides whether a destination may enter world state, and returns the
// rejection when the answer is no.
//
// M0 has no obstacles, so bounds are the only reachability rule. An illegal
// click is refused outright: clamping or snapping to the nearest legal point
// would move the player somewhere they did not click and leave the client
// unable to tell the difference between "obeyed" and "corrected".
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

// checkCoordinates says why (x, z) may not enter world state, or returns an
// empty reason when it may. It is the one place the question is answered, so a
// seeded item and a clicked destination are held to the same rule and cannot
// drift apart.
//
// Decoding already refuses non-finite client coordinates. Repeated here because
// this function, not the decoder, is what stands between a number and world
// state: a NaN would poison every later broadcast, and seeds do not come
// through the decoder at all.
func checkCoordinates(x, z float64) (mnet.RejectReason, string) {
	if !finite(x) || !finite(z) {
		return mnet.ReasonNonFinite, "coordinates must be finite"
	}
	if math.Abs(x) > WorldHalfExtent || math.Abs(z) > WorldHalfExtent {
		return mnet.ReasonOutOfBounds, fmt.Sprintf("out of bounds: x and z must be within +/-%v", WorldHalfExtent)
	}
	return "", ""
}

// pathMessage describes a walk already in progress as if it had just been
// assigned: points[0] is where the walker is right now, start_tick is now, and
// only the waypoints still ahead are listed. Re-anchoring rather than replaying
// the original path keeps one meaning for both fields everywhere in the
// protocol, and keeps a replay from contradicting the position the same welcome
// reports.
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

// send queues one message for one player.
func (w *World) send(p *player, msg mnet.ServerMessage) {
	p.conn.Send(mustEncode(msg))
}

// broadcast queues one message for every player except the connection in
// skip, which may be nil to reach everyone.
//
// Encoding happens once. Send never blocks, so a client that has stopped
// draining cannot stall the tick; it is dropped and reappears here as a
// disconnect on a later event, which is why this loop can safely ignore the
// result. Nothing outside this goroutine can mutate w.order, so a connection
// dying mid-broadcast cannot disturb the iteration either.
func (w *World) broadcast(msg mnet.ServerMessage, skip *mnet.Conn) {
	payload := mustEncode(msg)
	for _, conn := range w.order {
		if conn == skip {
			continue
		}
		conn.Send(payload)
	}
}

func mustEncode(msg mnet.ServerMessage) []byte {
	payload, err := mnet.Encode(msg)
	if err != nil {
		// Only a non-finite coordinate can get here, and nothing non-finite is
		// allowed into world state. Reaching this is a broken invariant, not a
		// runtime condition to recover from.
		panic(fmt.Sprintf("game: encoding %T: %v", msg, err))
	}
	return payload
}

// length is the total distance along a polyline.
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
