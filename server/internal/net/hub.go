package net

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	// sendBuffer is how many encoded frames may queue for one client before the
	// server gives up on it. At one tick per 150ms a full buffer means the
	// client is seconds behind.
	sendBuffer = 64

	// writeTimeout bounds a single frame write. A client whose TCP window has
	// been shut for this long is gone whether or not it has noticed.
	writeTimeout = 5 * time.Second

	// eventBuffer smooths bursts of inbound frames so read pumps rarely block
	// on the world goroutine. It is not a queue the world is allowed to fall
	// behind on; it only absorbs jitter.
	eventBuffer = 256
)

// Disconnect reasons, reported on EventDisconnected. A reason names the cause a
// connection died of, never the component that noticed, and the first
// condemnation latches (PROTOCOL.md, "Which reason is authoritative").
//
// Which of the two slow-client detectors fires depends on the send rate into a
// jammed socket, which is not something this package controls. A reason that
// named the detector would therefore have meant a different thing from one
// death to the next, which is exactly what classifying by cause removes.
const (
	DisconnectClosed   = "closed"          // the peer closed the connection cleanly
	DisconnectPeerGone = "peer_gone"       // the peer went away or the socket broke
	DisconnectSlow     = "slow_client"     // the client stopped keeping up
	DisconnectShutdown = "server_shutdown" // the server is going away
	DisconnectProtocol = "protocol_error"  // the client sent an uninterpretable frame
)

// Disconnect details name the detector that noticed, for a human reading a log.
// A detail never changes what a reason means and no code branches on one: it
// answers "which of the ways of finding this out actually fired", nothing else.
//
// Empty where the cause admits no detector distinction. A clean peer close, a
// server shutdown, and a protocol refusal each have exactly one path in.
const (
	DetailSendBufferFull = "send_buffer_full" // Conn.Send found the queue already full
	DetailWriteTimeout   = "write_timeout"    // one frame's write outlived writeTimeout
	DetailWriteError     = "write_error"      // a write failed for some other reason
	DetailReadError      = "read_error"       // a read failed other than on a close frame
)

// outgoing is one item in a connection's send queue: either a frame to write,
// or a request to close once everything queued ahead of it has been written.
type outgoing struct {
	payload     []byte
	closeReason string
}

// EventKind tags what happened on a connection.
type EventKind int

const (
	// EventConnected is emitted once per connection, before any of its frames.
	EventConnected EventKind = iota
	// EventFrame carries one decoded client message, or the error explaining
	// why the frame was refused.
	EventFrame
	// EventDisconnected is emitted exactly once per connection, after all of
	// its frames, and is the only place a connection is retired.
	EventDisconnected
)

// Event is one thing that happened on one connection.
//
// Events for a given connection arrive in order: EventConnected, then zero or
// more EventFrame, then EventDisconnected. That ordering is what lets the world
// assume a frame's sender is already known to it.
type Event struct {
	Kind EventKind
	Conn *Conn

	// Msg is the decoded message, set when Kind is EventFrame and Err is nil.
	Msg ClientMessage
	// Err is a *RejectError, set when Kind is EventFrame and the frame was
	// refused. Exactly one of Msg and Err is set.
	Err error
	// Reason explains an EventDisconnected: the cause, one of the Disconnect
	// constants.
	Reason string
	// Detail names the detector that noticed, one of the Detail constants, or
	// empty where the cause admits no detector distinction. It is for a human
	// reading a log; nothing may branch on it.
	Detail string
}

// Conn is one client connection.
//
// Reads happen on the connection's own goroutine and turn into Events. Writes
// happen on a second goroutine draining a buffered channel, so that the
// goroutine which owns world state never blocks on a socket.
type Conn struct {
	ws     *websocket.Conn
	remote string
	send   chan outgoing

	// writeTimeout is the hub's, copied in at accept time so that writePump
	// never reads hub state.
	writeTimeout time.Duration

	closeOnce   sync.Once
	closed      chan struct{}
	closeReason string
	closeDetail string
}

// Remote is the peer address, for logging only. It is not an identity.
func (c *Conn) Remote() string { return c.remote }

// Send queues one encoded frame and reports whether it was accepted.
//
// Never blocks. If the buffer is full the client is too slow to keep up with
// the tick and the connection is dropped: the goroutine that owns world state
// must not wait on a socket, and silently discarding a single frame would leave
// that client's view of the world permanently wrong with no way to notice.
// A dropped connection produces an EventDisconnected like any other, so there
// is exactly one path by which a player leaves the world.
func (c *Conn) Send(payload []byte) bool {
	select {
	case <-c.closed:
		return false
	default:
	}

	select {
	case c.send <- outgoing{payload: payload}:
		return true
	default:
		c.close(DisconnectSlow, DetailSendBufferFull)
		return false
	}
}

// CloseAfterFlush queues a shutdown behind everything already queued, so that a
// final frame -- an error explaining why the connection is going away --
// reaches the client before the socket does.
//
// A full buffer means the client is not draining and that last frame would
// never arrive anyway, so the connection is closed at once instead.
//
// It carries no detail: the reasons that travel this way are decided by the
// world rather than detected by a pump, so there is no second detector a
// detail could distinguish it from.
func (c *Conn) CloseAfterFlush(reason string) {
	select {
	case <-c.closed:
		return
	default:
	}

	select {
	case c.send <- outgoing{closeReason: reason}:
	default:
		c.close(reason, "")
	}
}

// close condemns the connection and records the cause. It is the latch: the
// first caller wins and every later one is a no-op, so a slow-client drop and
// the read error it goes on to provoke still yield one reason and one
// EventDisconnected. A consequence never overwrites a cause.
//
// detail names the detector that got here first, or is empty. It is latched
// with the reason, so a log line's reason and detail always describe the same
// observation rather than two racing ones.
func (c *Conn) close(reason, detail string) {
	c.closeOnce.Do(func() {
		c.closeReason = reason
		c.closeDetail = detail
		close(c.closed)
		// CloseNow is safe to call concurrently with a blocked Read and is what
		// unblocks it.
		_ = c.ws.CloseNow()
	})
}

// Hub accepts WebSocket connections and turns them into a single ordered
// stream of Events for one consumer.
//
// The hub owns sockets. It does not own players, positions, or ids: those
// belong to the goroutine draining Events.
type Hub struct {
	events chan Event

	// writeTimeout is handed to every connection this hub accepts. It is read
	// once per accept and never written after the hub starts serving, which is
	// why it needs no lock.
	writeTimeout time.Duration

	mu     sync.Mutex
	conns  map[*Conn]struct{}
	closed bool

	done chan struct{}
}

// NewHub returns a hub that is ready to accept connections.
func NewHub() *Hub {
	return &Hub{
		events:       make(chan Event, eventBuffer),
		writeTimeout: writeTimeout,
		conns:        make(map[*Conn]struct{}),
		done:         make(chan struct{}),
	}
}

// Events is the hub's output. Exactly one goroutine may drain it.
func (h *Hub) Events() <-chan Event { return h.events }

// ServeHTTP upgrades a request to WebSocket and runs the connection until it
// closes. It blocks for the connection's lifetime, so http.Server.Shutdown
// waits for connections that Hub.Close has already told to go away.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// The game client is a desktop Godot build, not a browser page, and
		// sends no Origin header worth checking. Origin checking is a
		// same-origin-policy defence for browsers; it becomes meaningful again
		// when there is an account to hijack, which is when auth lands.
		InsecureSkipVerify: true,
	})
	if err != nil {
		// Accept has already written an error response.
		return
	}

	conn := &Conn{
		ws:           ws,
		remote:       r.RemoteAddr,
		send:         make(chan outgoing, sendBuffer),
		writeTimeout: h.writeTimeout,
		closed:       make(chan struct{}),
	}

	if !h.register(conn) {
		conn.close(DisconnectShutdown, "")
		return
	}
	defer h.unregister(conn)

	go conn.writePump()

	h.emit(Event{Kind: EventConnected, Conn: conn})
	reason, detail := conn.readPump(h)
	h.emit(Event{Kind: EventDisconnected, Conn: conn, Reason: reason, Detail: detail})
}

func (h *Hub) register(c *Conn) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return false
	}
	h.conns[c] = struct{}{}
	return true
}

func (h *Hub) unregister(c *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.conns, c)
}

// emit hands an event to the consumer, or discards it if the hub is shutting
// down. Discarding is correct at that point: the world has stopped and nobody
// will read the event.
func (h *Hub) emit(ev Event) {
	select {
	case h.events <- ev:
	case <-h.done:
	}
}

// Close stops accepting connections and closes every open one, which unblocks
// their read pumps and returns their HTTP handlers.
//
// Safe to call more than once.
func (h *Hub) Close() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	close(h.done)
	// Snapshot and release the lock before closing sockets: a connection's
	// teardown path takes this same lock to unregister itself.
	open := make([]*Conn, 0, len(h.conns))
	for c := range h.conns {
		open = append(open, c)
	}
	h.mu.Unlock()

	for _, c := range open {
		c.close(DisconnectShutdown, "")
	}
}

// readPump reads frames until the connection fails, decoding each one and
// emitting it. It returns the latched reason and detail the connection ended
// on, which are its own classification only if nothing condemned the
// connection first.
//
// Reading c.closeReason unsynchronised is safe exactly here: close returns only
// after sync.Once has run the write, so the caller of close happens-after it
// whether or not it was the caller that won.
//
// Decoding happens here, off the world goroutine, but rejection is not reported
// here: only the world knows the tick number a rejection belongs to, so the
// error rides along on the event.
func (c *Conn) readPump(h *Hub) (reason, detail string) {
	for {
		typ, data, err := c.ws.Read(context.Background())
		if err != nil {
			c.close(readReason(err))
			return c.closeReason, c.closeDetail
		}
		if typ != websocket.MessageText {
			h.emit(Event{
				Kind: EventFrame,
				Conn: c,
				Err: &RejectError{
					Reason:      ReasonBinaryFrame,
					Detail:      "text frames only",
					Disposition: ReplyErrorAndClose,
				},
			})
			continue
		}
		msg, decErr := Decode(data)
		h.emit(Event{Kind: EventFrame, Conn: c, Msg: msg, Err: decErr})
	}
}

// readReason classifies why a read stopped, by cause. A close frame is the peer
// leaving on purpose and is the only thing here that is not a condemnation.
// Anything else means the peer went away or the socket broke.
//
// A read pump reaching this after a slow client has already been condemned
// classifies the same way and loses: close latches the first condemnation, so
// the read error stays a consequence rather than becoming the cause.
//
// A context error is deliberately not special-cased. It used to map to closed,
// on the reasoning that readPump passes context.Background() so no deadline of
// ours can expire. The conclusion was wrong, and wrong in this unit's own
// domain: a slow client was logged as a clean logout.
//
// Observed. TestAJammedPongCondemnsTheClientAsPeerGone stages it -- a peer whose
// receive side is jammed pings, the read goroutine tries to write the pong, and
// five seconds later the read fails -- and asserts the reason and detail. It does
// not assert the error string below, which was captured under instrumentation
// during review and exists nowhere in the tree, so do not expect to grep for it:
//
//	failed to handle control frame opPing: failed to write control frame
//	opPong: failed to acquire lock: context deadline exceeded
//
// Read, and corrected once: the deadline is the library's, not ours. writeControl
// wraps whatever context it is handed in a five-second one (write.go:277) and
// writeFrame's first act is writeFrameMu.lock(ctx), which returns ctx.Err()
// wrapped when the wait expires (conn.go:291). The mutex is held for the whole
// of the jammed data-frame write, so the pong waits behind it.
//
// Observed again, under the same instrumentation: nothing in the library closes
// the connection here. setupWriteTimeout is only reached after writeFrameMu.lock
// returns (write.go:289), and on this path the lock wait is what fails, so the
// close timer is never armed at all. Our own close ends it, after this
// classifies.
//
// An earlier version of this comment blamed finishRead's ctx.Err() overwrite at
// read.go:255. That was wrong: finishRead tests the context it was passed, and
// on this path that is readPump's context.Background(), whose Err is always nil.
// Same symptom, wrong mechanism, which is the combination that feels confirmed
// because the symptom really does happen.
func readReason(err error) (reason, detail string) {
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return DisconnectClosed, ""
	}
	return DisconnectPeerGone, DetailReadError
}

// writePump drains the send buffer onto the socket. It is the only writer, so
// frames reach the client in the order the world produced them.
//
// It owns the write deadline itself instead of handing one to the websocket
// library, and that is load-bearing rather than a style choice. Given a context
// with a deadline, coder/websocket closes the whole connection from its own
// timer goroutine and only afterwards returns the error (conn.go,
// setupWriteTimeout). The read pump then wakes on a socket that is already dead
// and condemns it as peer_gone before this goroutine has classified anything,
// so the cause loses the race about half the time. Measured, not reasoned
// about: the ordering test failed five runs in ten before this changed.
//
// Condemning from our own timer puts the latch in front of the teardown rather
// than racing it. By the time anything else can observe a dead socket, the
// reason is already recorded.
func (c *Conn) writePump() {
	for {
		select {
		case <-c.closed:
			return
		case out := <-c.send:
			if out.payload == nil {
				c.close(out.closeReason, "")
				return
			}
			// close is what unblocks the write below, via CloseNow. Stop
			// reports false if the timer already fired, and there is nothing to
			// undo in that case: the connection is condemned and this frame was
			// never going to arrive.
			condemn := time.AfterFunc(c.writeTimeout, func() {
				c.close(DisconnectSlow, DetailWriteTimeout)
			})
			err := c.ws.Write(context.Background(), websocket.MessageText, out.payload)
			condemn.Stop()
			if err != nil {
				// Two ways here. The timer above condemned this connection and
				// closed the socket underneath the write, in which case this
				// call is a no-op and the latched cause stands. Or the socket
				// broke on its own, which is what peer_gone names.
				c.close(DisconnectPeerGone, DetailWriteError)
				return
			}
		}
	}
}

// String makes an EventKind readable in test failures.
func (k EventKind) String() string {
	switch k {
	case EventConnected:
		return "connected"
	case EventFrame:
		return "frame"
	case EventDisconnected:
		return "disconnected"
	default:
		return fmt.Sprintf("EventKind(%d)", int(k))
	}
}
