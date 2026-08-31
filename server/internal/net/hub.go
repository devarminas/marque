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

// Disconnect reasons, reported on EventDisconnected.
const (
	DisconnectClosed     = "closed"           // the peer closed the connection
	DisconnectReadError  = "read_error"       // the connection failed while reading
	DisconnectWriteError = "write_error"      // the connection failed while writing
	DisconnectSlow       = "send_buffer_full" // the client could not keep up
	DisconnectShutdown   = "server_shutdown"  // the server is going away
	DisconnectProtocol   = "protocol_error"   // the client sent an uninterpretable frame
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
	// Reason explains an EventDisconnected. One of the Disconnect constants.
	Reason string
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

	closeOnce   sync.Once
	closed      chan struct{}
	closeReason string
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
		c.close(DisconnectSlow)
		return false
	}
}

// CloseAfterFlush queues a shutdown behind everything already queued, so that a
// final frame -- an error explaining why the connection is going away --
// reaches the client before the socket does.
//
// A full buffer means the client is not draining and that last frame would
// never arrive anyway, so the connection is closed at once instead.
func (c *Conn) CloseAfterFlush(reason string) {
	select {
	case <-c.closed:
		return
	default:
	}

	select {
	case c.send <- outgoing{closeReason: reason}:
	default:
		c.close(reason)
	}
}

// close shuts the connection down and records why. The first caller wins: a
// slow-client drop and a peer-initiated close racing each other still yield one
// reason and one EventDisconnected.
func (c *Conn) close(reason string) {
	c.closeOnce.Do(func() {
		c.closeReason = reason
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

	mu     sync.Mutex
	conns  map[*Conn]struct{}
	closed bool

	done chan struct{}
}

// NewHub returns a hub that is ready to accept connections.
func NewHub() *Hub {
	return &Hub{
		events: make(chan Event, eventBuffer),
		conns:  make(map[*Conn]struct{}),
		done:   make(chan struct{}),
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
		ws:     ws,
		remote: r.RemoteAddr,
		send:   make(chan outgoing, sendBuffer),
		closed: make(chan struct{}),
	}

	if !h.register(conn) {
		conn.close(DisconnectShutdown)
		return
	}
	defer h.unregister(conn)

	go conn.writePump()

	h.emit(Event{Kind: EventConnected, Conn: conn})
	reason := conn.readPump(h)
	h.emit(Event{Kind: EventDisconnected, Conn: conn, Reason: reason})
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
		c.close(DisconnectShutdown)
	}
}

// readPump reads frames until the connection fails, decoding each one and
// emitting it. It returns the reason the connection ended.
//
// Decoding happens here, off the world goroutine, but rejection is not reported
// here: only the world knows the tick number a rejection belongs to, so the
// error rides along on the event.
func (c *Conn) readPump(h *Hub) string {
	for {
		typ, data, err := c.ws.Read(context.Background())
		if err != nil {
			c.close(readReason(err))
			return c.closeReason
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

// readReason classifies why a read stopped. A clean peer close is not a
// failure; everything else is.
func readReason(err error) string {
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return DisconnectClosed
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return DisconnectClosed
	}
	return DisconnectReadError
}

// writePump drains the send buffer onto the socket. It is the only writer, so
// frames reach the client in the order the world produced them.
func (c *Conn) writePump() {
	for {
		select {
		case <-c.closed:
			return
		case out := <-c.send:
			if out.payload == nil {
				c.close(out.closeReason)
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
			err := c.ws.Write(ctx, websocket.MessageText, out.payload)
			cancel()
			if err != nil {
				c.close(DisconnectWriteError)
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
