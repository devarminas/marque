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
	"crypto/rand"
	"encoding/hex"
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

// ResumeGraceTicks is how long a player's body stays in the world after its
// socket died abruptly, in ticks. Four hundred is sixty seconds at 150ms.
//
// Ticks and not a duration, because the tick counter is the clock and nothing
// in game logic reads wall-clock time (PROTOCOL.md, "Clock"). A grace measured
// against time.Now would be the one rule in the game a paused process gets
// wrong.
//
// A placeholder chosen to be long enough to survive restarting a client and
// short enough that an abandoned body is not furniture. Parked in
// FOLLOW-UPS.md.
const ResumeGraceTicks = 400

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

	// The five events a resume can produce, each with its own field set and no
	// field added to an existing event. None of them carries a session token:
	// a token in a log is a token in every place a log is pasted, and this log
	// is read by agents and quoted into pull requests (PROTOCOL.md,
	// "The session token").
	//
	// EvPlayerSuspended is a socket dying without its player leaving. It is
	// logged *after* the EvDisconnected for the same death rather than instead
	// of it: the socket really did die, and its latched reason is what decided
	// the suspension, so a reader has to see both lines to see why.
	EvPlayerSuspended = "player_suspended"
	// EvPlayerResumed is a connection being handed a suspended player. It
	// carries the remote address because that is the only new fact about it;
	// the player is the one it always was.
	EvPlayerResumed = "player_resumed"
	// EvPlayerExpired is a grace running out. The retirement that follows is
	// the same one a clean logout gets, despawn included.
	EvPlayerExpired = "player_expired"
	// EvResumeRefused is a token whose player is still connected. It names only
	// the remote address, because no player was created for it: naming the
	// player it asked for would file a connection the world turned away under
	// the id of a player who is sitting there connected and unaffected.
	EvResumeRefused = "resume_refused"
	// EvResumeUnknown is a token that names nothing, whether stale, expired or
	// invented. One event for all three, for the reason ReasonUnknownItem is
	// one reason: the server must not tell a client which identities exist.
	EvResumeUnknown = "resume_unknown"

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

	// Item, pickup and drop events. Every change to where an item is has its own
	// name, for EvPathReplayed's reason: a reader counting one outcome must get
	// the right answer without knowing to exclude anything, and these seven do
	// not share a field set.
	//
	// EvItemSpawned is an item entering the world, and carries only the item:
	// id, kind, and where it landed. There are two ways in -- a seed before the
	// world opens, and a drop once it is running -- and both log this name with
	// this field set.
	//
	// **The causer is deliberately not on it.** M1a pre-committed to reusing the
	// name here on the grounds that a drop is "the same state change with the
	// same fields", and the first half of that is right while the second is a
	// trap: a drop has a player behind it and a seed does not, so a "player"
	// field would make one event name carry two field sets, which is the exact
	// shape EvPathReplayed exists to refuse.
	//
	// Splitting the name instead was the other candidate and it is worse, and
	// the doctrine above is why. EvPathReplayed earns a name of its own because
	// a replay is not the server choosing a path: the outcome differs, not only
	// the fields. A drop is not like that. A dropped item and a seeded item have
	// both entered the world, at a position, for the first time, and a reader
	// counting item_spawned to ask "how many items entered the world, and where"
	// must get both. Naming the drop's entry separately would make that reader
	// wrong in the other direction, and would leave item_spawned quietly meaning
	// "seeded".
	//
	// So the two halves are split by what they are about rather than by who
	// caused them: this name carries the world's state change, and EvDrop below
	// carries the transaction, including the player and the slot the item came
	// from. Neither has to be joined to the other by adjacency.
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

	// EvDrop is one completed drop: which player, which slot it came out of,
	// and which item it became. Logged after the move, never before it, which
	// is where it differs from EvPickup.
	//
	// EvPickup records an intent on arrival because a pickup is pending: the
	// intent and its outcome are separated by a walk of many ticks, and without
	// a line at arrival the log cannot show that a player is walking to
	// something. A drop is immediate (PROTOCOL.md, "Drop"). Its intent and its
	// outcome are the same tick, in one function call, with nothing observable
	// in between, so one line for the whole transaction is the honest shape and
	// a second one at arrival would say nothing the first does not.
	//
	// Its four fields are EvPickupResolved's four fields, spelled by the same
	// helper: these are the two events that move an item between the ground and
	// a slot, and a reader who has learned one row has learned the other.
	EvDrop = "drop"
	// EvDropRejected is a drop refused: an index outside the inventory, a slot
	// holding nothing, or a body that would not decode. It carries the
	// rejection's fields, not a drop's, because it shares refuse with move_to
	// and pickup.
	EvDropRejected = "drop_rejected"
)

// Transport is the world's view of the network: a stream of connection events.
// Replies go back through the *mnet.Conn each event carries.
type Transport interface {
	Events() <-chan mnet.Event
}

// sessionTokenBytes is how much randomness a session token carries. Sixteen
// bytes is the 32 hex characters PROTOCOL.md fixes, and 128 bits is far enough
// past the birthday bound that no uniqueness check is written anywhere: a
// collision is not a case the code handles, it is a case that does not happen.
const sessionTokenBytes = 16

// newSessionToken mints one player's durable identity.
//
// Opaque to everyone, including this server: nothing derives a player id from
// it, nothing orders two of them, and it is never written to the event log.
func newSessionToken() string {
	var raw [sessionTokenBytes]byte
	if _, err := rand.Read(raw[:]); err != nil {
		// The system entropy source failed. There is no degraded token worth
		// issuing, and issuing a guessable one would be worse than not starting.
		panic(fmt.Sprintf("game: reading %d bytes for a session token: %v", sessionTokenBytes, err))
	}
	return hex.EncodeToString(raw[:])
}

// player is one player's authoritative state.
//
// A player is a durable entity and the connection is a field on it, rather than
// the connection being the player. Nothing here is keyed on the socket.
type player struct {
	id mnet.PlayerID

	// session is this player's durable identity: minted once, the same across
	// every connection the player ever has, and never logged.
	session string

	// conn is the socket this player is speaking through, or nil when it has
	// none. Everything that writes to a player checks it.
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

	// expiresTick is the tick at which a suspended player is retired. It is
	// meaningful only while suspended and is zero the rest of the time; the
	// sweep in step tests conn first, which is what keeps a connected player's
	// zero from reading as "expired at tick 0".
	expiresTick int64
}

func (p *player) walking() bool { return len(p.remaining) > 0 }

// suspended reports whether the player is in the world with nobody listening.
// Its walk still advances and its pending pickup still resolves; only the
// frames go nowhere.
func (p *player) suspended() bool { return p.conn == nil }

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

	// resumeGrace is how many ticks a suspended player is kept. Fixed at
	// construction: a value that could change while players are suspended would
	// mean two of them are waiting on different rules.
	resumeGrace int64

	// players is every player in the world, by the id that names them
	// everywhere else in the protocol.
	players map[mnet.PlayerID]*player
	// byConn finds the player speaking through a socket. Only players with a
	// live connection appear here, so a lookup that misses is the answer to
	// "does the world know this socket", not a bug.
	byConn map[*mnet.Conn]*player
	// bySession finds a player by its durable identity. Every player in
	// w.players has exactly one entry here for its whole life in the world.
	bySession map[string]*player
	// order keeps iteration deterministic. Go randomises map iteration, which
	// would make welcome's player list and broadcast order differ run to run,
	// and replay diffs are only useful when two identical runs agree. It is
	// also the tiebreaker for a contested pickup, so it is load-bearing for
	// game rules and not only for logs.
	order []*player
}

// NewWorld returns an empty world reading intents from transport and keeping
// items in store, holding a suspended player for resumeGrace ticks.
//
// The store must be used by nobody else. Once Run starts, its goroutine is the
// only thing allowed to touch it.
//
// resumeGrace is a parameter rather than a constant read straight from
// ResumeGraceTicks so that a test can reach the expiry branch in under a second
// instead of waiting out the production sixty. It must be at least one tick: a
// grace of zero would make a suspension expire on the tick after it began,
// which is retiring the player with extra log lines rather than a shorter
// grace, and it would make every assertion about resuming silently vacuous.
func NewWorld(transport Transport, log *gamelog.Logger, store Store, resumeGrace int64) *World {
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
		resumeGrace: resumeGrace,
		players:   make(map[mnet.PlayerID]*player),
		byConn:    make(map[*mnet.Conn]*player),
		bySession: make(map[string]*player),
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
// Movement, pickup resolution and expiry are three passes rather than one, so
// that "a pending pickup resolves after movement has advanced" (PROTOCOL.md,
// "Pickup") is true of every player and not only of the player being visited.
// The first two happen to be equivalent today, because resolving reads only the
// resolving player's own position; the day a rule reads somebody else's, one
// pass would be wrong and nothing would say so. The third is separate for a
// harder reason: it removes players from w.order.
func (w *World) step() {
	w.tick++
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

	// Join order, deliberately: the first player in w.order who has a pending
	// pickup for an item and is near enough to it takes it, and every later
	// player in this same pass finds it gone. Never a range over w.players,
	// whose iteration order Go randomises; the winner of a contest must be the
	// same in two identical runs.
	for _, p := range w.order {
		if p.pending != 0 {
			w.resolvePickup(p)
		}
	}

	// Last, so that a suspended player's final tick is a whole one: it moves
	// and it resolves whatever it was walking to, and only then does the grace
	// run out. Expiring first would silently shorten every grace by a tick and
	// would lose the last pickup of a player who arrived on exactly this one.
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

// admit decides what a new connection gets: its own player, somebody's player
// back, or the door.
//
// Four cases and they are decided here rather than scattered, because they are
// four answers to one question and a reader has to be able to see that the four
// are exhaustive.
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
		// Stale, expired, or invented; one answer for all three, because the
		// server must not tell a client which identities exist. The client can
		// still tell it did not resume, because the welcome it gets back names
		// a different you and a different session.
		w.log.Event(w.tick, EvResumeUnknown, gamelog.Fields{"remote": conn.Remote()})
		w.addPlayer(conn)
	case !claimed.suspended():
		w.refuseResume(conn)
	default:
		w.resumePlayer(claimed, conn)
	}
}

// refuseResume turns away a connection presenting a token whose player is still
// connected.
//
// Refused and not superseded: the connection that holds the player is not
// touched, and no player is created for this one. Superseding would mean
// telling the older connection it had been replaced, and no such message
// exists (PROTOCOL.md, "When the connection dies").
//
// It writes to the socket directly rather than through send, because send takes
// a player and the whole point of this path is that there is not one.
func (w *World) refuseResume(conn *mnet.Conn) {
	w.log.Event(w.tick, EvResumeRefused, gamelog.Fields{"remote": conn.Remote()})
	// No "re": nothing this connection sent was rejected. It never got as far
	// as sending anything.
	conn.Send(mustEncode(mnet.Error{Msg: "session is still connected"}))
	conn.CloseAfterFlush(mnet.DisconnectRefused)
}

// resumePlayer hands a suspended player to the connection that proved it holds
// that player's token.
//
// No spawn is broadcast and nothing at all is sent to anybody else: every other
// client has had that body on screen the whole time, and a spawn would be a
// duplicate avatar. From outside, a resume is not an event.
func (w *World) resumePlayer(p *player, conn *mnet.Conn) {
	p.conn = conn
	p.expiresTick = 0
	w.byConn[conn] = p

	w.log.Event(w.tick, EvPlayerResumed, gamelog.Fields{
		"player": p.id,
		"remote": conn.Remote(),
	})

	// The ordinary join step, unchanged: the world as of now, one re-anchored
	// path per walker, then this player's inventory. The player's own walk is
	// among those replays, because it is in w.order and it never stopped, which
	// is how a resuming client is told where its own body actually is.
	w.sendJoinStep(p)
}

// addPlayer gives a connection a brand new player.
//
// Welcome and its path replays are composed and enqueued here, in one step, on
// the goroutine that owns the world. Nothing interleaves with it, so any
// broadcast enqueued afterwards is seen by the newcomer and any broadcast
// before it is not. That is what keeps two clients joining in the same tick
// from either missing a player or seeing one twice.
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

	w.sendJoinStep(p)
	w.broadcast(mnet.Spawn{ID: p.id, X: p.pos.X, Z: p.pos.Z}, p)
}

// sendJoinStep composes and enqueues the whole atomic welcome step for one
// player: the world, then one path per walker, then that player's own
// inventory.
//
// It is separate from addPlayer because the step is about handing a connection
// the world, and admitting a new player is only one of the ways a connection
// comes to need it.
func (w *World) sendJoinStep(p *player) {
	states := make([]mnet.PlayerState, 0, len(w.order))
	for _, other := range w.order {
		states = append(states, mnet.PlayerState{ID: other.id, X: other.pos.X, Z: other.pos.Z})
	}
	w.send(p, mnet.Welcome{
		You:     p.id,
		Session: p.session,
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

	// Last inside the atomic step, after the replays. The inventory is the one
	// thing in the step that is about this player rather than about the world,
	// and nothing about the world may be observable to the newcomer before it
	// has been told everything the step describes (PROTOCOL.md, "Ordering and
	// the join race").
	w.sendInventory(p)
}

// suspends reports whether a socket death leaves the player standing.
//
// It is the whole of the split, and it keys on the latched cause because the
// cause is the only thing that says whether the player meant to go. A clean
// close and a protocol refusal are departures. A vanished peer and a client
// that stopped keeping up are accidents, and RuneScape leaves your character
// in the world after one of those (PROTOCOL.md, "When the connection dies").
//
// A whitelist and not a blacklist: a reason invented later suspends nobody
// until somebody decides it should, which is the failure that loses a body
// rather than the one that leaks one.
func suspends(reason string) bool {
	return reason == mnet.DisconnectPeerGone || reason == mnet.DisconnectSlow
}

// removePlayer answers a dead socket, either by suspending its player or by
// retiring it.
//
// reason is the latched cause and detail names the detector that noticed it,
// which may be empty. The world logs both and interprets only the reason, and
// only to the extent suspends does.
func (w *World) removePlayer(conn *mnet.Conn, reason, detail string) {
	p, ok := w.byConn[conn]
	if !ok {
		// A connection the world never admitted, which since M2a is the
		// ordinary fate of a refused resume, or a second disconnect for one it
		// already retired. Neither produces a client_disconnected line: the
		// world has no player to log it against, and a reader counting those to
		// ask how many players left must not be handed connections that never
		// arrived.
		return
	}

	fields := gamelog.Fields{
		"player": p.id,
		"reason": reason,
	}
	// Omitted rather than logged empty: a "detail" key is a promise that two
	// detectors could have fired, and for a clean close or a shutdown none
	// could have.
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

// suspend takes a player's connection away and leaves everything else standing.
//
// No despawn, because nothing about the world changed for anybody else: the
// body is where it was, the walk it is on continues, and a pending pickup
// resolves into an inventory that is still theirs. The only difference is that
// every frame addressed to this player is now dropped, which send handles.
func (w *World) suspend(p *player) {
	delete(w.byConn, p.conn)
	p.conn = nil
	p.expiresTick = w.tick + w.resumeGrace

	w.log.Event(w.tick, EvPlayerSuspended, gamelog.Fields{
		"player":       p.id,
		"expires_tick": p.expiresTick,
	})
}

// expireSuspended retires every player whose grace has run out.
//
// Two passes because retire mutates w.order, and iterating a slice while
// removing from it is the bug this shape exists to not write. The snapshot
// allocates nothing on the overwhelming majority of ticks, on which nobody is
// suspended and the append never runs.
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

// retire takes a player out of the world for good: every index forgets them,
// whatever they were carrying is deleted, and everyone else is told the body is
// gone.
//
// Whatever they were carrying leaves with them. M1 has no persistence and no
// drop-on-logout, so this is deletion rather than a transfer to the ground;
// making it a transfer is a design decision, not a bug fix, and it is parked in
// FOLLOW-UPS.md.
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
	case mnet.Drop:
		w.drop(p, msg)
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
//
// Every intent this server accepts needs an arm here, and the cost of forgetting
// one is quiet rather than loud: the refusals get filed under move_to's name and
// nothing fails.
func rejectionEvent(re string) string {
	switch re {
	case mnet.MsgPickup:
		return EvPickupRejected
	case mnet.MsgDrop:
		return EvDropRejected
	default:
		return EvMoveToRejected
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

	points, assign := destinationPath(p, Point{X: msg.X, Z: msg.Z})
	if !assign {
		// Standing still and asked to stand still. Nothing changes, so there is
		// nothing to broadcast; the sender is told, because otherwise the click
		// is indistinguishable from a dropped frame.
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonDegenerate,
			Detail:      "already there",
			Re:          mnet.MsgMoveTo,
			Disposition: mnet.ReplyError,
		})
		return
	}

	// Clicking the ground says you wanted something else, so it cancels a
	// pending pickup. Here, at the point the click actually changes where the
	// player is going, and not on entry: a click the server refuses changes
	// nothing, and an out-of-bounds coordinate must not quietly cost the player
	// the item they were already walking to.
	p.pending = 0
	w.assignPath(p, points)
}

// destinationPath is the polyline that takes p to dest, and whether there is one
// to assign at all.
//
// Three shapes, and move_to and pickup agree on all three, because a pickup is a
// move_to at the item's position (PROTOCOL.md, "Pickup"):
//
//   - an ordinary walk, when dest is further off than MinPathLength;
//   - a one-element halt at p.pos, when dest is where p already is and p is
//     walking. A walker holds at the final point of its polyline, so a polyline
//     of one point is a complete instruction to stand still there, and that is
//     the whole of "stop walking": no separate message exists, and none is
//     needed;
//   - nothing at all, when dest is where p already is and p is standing still.
//
// The two callers differ only in what they say about the third. move_to answers
// "already there", because nothing is left to do. A pickup says nothing, because
// its pending pickup still has something left to do.
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

// assignPath puts a player on a polyline and tells everyone.
//
// points[0] must be where the player is right now: that is what the wire
// contract says the field means, and it is what lets a client processing the
// frame a tick late still place the walker correctly.
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

// send queues one message for one player, and does nothing for a player with no
// connection.
//
// Dropping the frame is right rather than merely convenient: a message to a
// player nobody is listening for is not lost state. Every message this server
// sends is either a full restatement (welcome, inventory) or an announcement
// that is restated on the next join step (spawn, path, item_spawn), so a
// connection that arrives later is told everything it missed by the step that
// admits it.
func (w *World) send(p *player, msg mnet.ServerMessage) {
	if p.conn == nil {
		return
	}
	p.conn.Send(mustEncode(msg))
}

// broadcast queues one message for every player except the one in skip, which
// may be nil to reach everyone.
//
// Encoding happens once. Send never blocks, so a client that has stopped
// draining cannot stall the tick; it is dropped and reappears here as a
// disconnect on a later event, which is why this loop can safely ignore the
// result. Nothing outside this goroutine can mutate w.order, so a connection
// dying mid-broadcast cannot disturb the iteration either.
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
