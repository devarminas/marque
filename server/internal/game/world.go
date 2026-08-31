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

// MinPathLength is the shortest path the server will assign. Below it, the
// click is ignored: a zero-length segment makes the client's interpolator
// divide by zero and produce a NaN position, which is painful to trace back
// here from there.
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
}

func (p *player) walking() bool { return len(p.remaining) > 0 }

// World is the authoritative game state.
//
// Every field is owned by the goroutine running Run. No mutex guards them
// because nothing else may read or write them.
type World struct {
	transport Transport
	log       *gamelog.Logger

	tick   int64
	nextID mnet.PlayerID

	players map[*mnet.Conn]*player
	// order keeps iteration deterministic. Go randomises map iteration, which
	// would make welcome's player list and broadcast order differ run to run,
	// and replay diffs are only useful when two identical runs agree.
	order []*mnet.Conn
}

// NewWorld returns an empty world reading intents from transport.
func NewWorld(transport Transport, log *gamelog.Logger) *World {
	if transport == nil {
		panic("game: nil transport")
	}
	return &World{
		transport: transport,
		log:       log,
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

// step advances one tick.
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
	})

	// Everyone already mid-walk is described to the newcomer with an ordinary
	// path message, so a joining client learns in-flight movement through the
	// same code path it uses for live movement. There is no snapshot format for
	// paths, and there is nothing here for the newcomer to special-case.
	for _, c := range w.order {
		other := w.players[c]
		if !other.walking() {
			continue
		}
		w.send(p, w.pathMessage(other))
	}

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
		// ordering contract broke.
		w.log.Event(w.tick, EvMoveToRejected, gamelog.Fields{
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

	w.log.Event(w.tick, EvMoveToRejected, fields)
	w.send(p, mnet.Error{Re: rejection.Re, Msg: rejection.Detail})
	if rejection.Disposition == mnet.ReplyErrorAndClose {
		p.conn.CloseAfterFlush(mnet.DisconnectProtocol)
	}
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

	// Clicking the ground you are already standing on is a no-op, not a
	// zero-length walk. Nothing is sent and nothing changes, so a player who
	// was already walking keeps walking and the client's view still matches.
	if length(points) < MinPathLength {
		w.log.Event(w.tick, EvIntentIgnored, gamelog.Fields{
			"player": p.id,
			"re":     mnet.MsgMoveTo,
			"reason": string(mnet.ReasonDegenerate),
			"x":      msg.X,
			"z":      msg.Z,
		})
		return
	}

	p.remaining = points[1:]

	out := mnet.Path{
		ID:        p.id,
		StartTick: w.tick,
		Points:    wirePoints(points),
		Speed:     WalkSpeed,
	}
	w.log.Event(w.tick, EvPathAssigned, gamelog.Fields{
		"player":     p.id,
		"start_tick": out.StartTick,
		"points":     out.Points,
		"speed":      out.Speed,
	})
	w.broadcast(out, nil)
}

// validate decides whether a destination may enter world state, and returns the
// rejection when the answer is no.
//
// M0 has no obstacles, so bounds are the only reachability rule. An illegal
// click is refused outright: clamping or snapping to the nearest legal point
// would move the player somewhere they did not click and leave the client
// unable to tell the difference between "obeyed" and "corrected".
func (w *World) validate(msg mnet.MoveTo) *mnet.RejectError {
	// Decoding already refuses non-finite coordinates. Repeated here because
	// this function, not the decoder, is what stands between a number and world
	// state, and a NaN position would poison every later broadcast.
	if !finite(msg.X) || !finite(msg.Z) {
		return &mnet.RejectError{
			Reason:      mnet.ReasonNonFinite,
			Detail:      "move_to coordinates must be finite",
			Re:          mnet.MsgMoveTo,
			Disposition: mnet.ReplyError,
		}
	}
	if math.Abs(msg.X) > WorldHalfExtent || math.Abs(msg.Z) > WorldHalfExtent {
		return &mnet.RejectError{
			Reason:      mnet.ReasonOutOfBounds,
			Detail:      fmt.Sprintf("out of bounds: x and z must be within +/-%v", WorldHalfExtent),
			Re:          mnet.MsgMoveTo,
			Disposition: mnet.ReplyError,
		}
	}
	return nil
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
