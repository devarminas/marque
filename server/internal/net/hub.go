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
	sendBuffer   = 64
	writeTimeout = 5 * time.Second
	eventBuffer  = 256
)

// Disconnect reasons and details, reported on EventDisconnected. The vocabulary
// and the rules that pick between them are PROTOCOL.md, "Which reason is
// authoritative".
const (
	DisconnectClosed   = "closed"
	DisconnectPeerGone = "peer_gone"
	DisconnectSlow     = "slow_client"
	DisconnectShutdown = "server_shutdown"
	DisconnectProtocol = "protocol_error"
)

const (
	DetailSendBufferFull = "send_buffer_full"
	DetailWriteTimeout   = "write_timeout"
	DetailWriteError     = "write_error"
	DetailReadError      = "read_error"
)

type outgoing struct {
	payload     []byte
	closeReason string
}

type EventKind int

const (
	EventConnected EventKind = iota
	EventFrame
	EventDisconnected
)

// Event is one thing that happened on one connection.
//
// Events for a given connection arrive in order: EventConnected, then zero or
// more EventFrame, then exactly one EventDisconnected.
type Event struct {
	Kind EventKind
	Conn *Conn

	// Exactly one of Msg and Err is set, and only when Kind is EventFrame. Err
	// is a *RejectError.
	Msg ClientMessage
	Err error

	// Reason is one of the Disconnect constants; Detail one of the Detail
	// constants, or empty. Nothing may branch on Detail.
	Reason string
	Detail string
}

// Conn is one client connection. Reads run on the connection's own goroutine;
// writes run on a second one draining send, so the goroutine that owns world
// state never blocks on a socket.
type Conn struct {
	ws           *websocket.Conn
	remote       string
	send         chan outgoing
	writeTimeout time.Duration

	closeOnce   sync.Once
	closed      chan struct{}
	closeReason string
	closeDetail string
}

// Remote is the peer address, for logging only. It is not an identity.
func (c *Conn) Remote() string { return c.remote }

// Send queues one encoded frame and reports whether it was accepted. It never
// blocks.
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

// CloseAfterFlush queues a shutdown behind everything already queued, so a
// final frame reaches the client before the socket goes.
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

func (c *Conn) close(reason, detail string) {
	c.closeOnce.Do(func() {
		c.closeReason = reason
		c.closeDetail = detail
		close(c.closed)
		// CloseNow is safe to call concurrently with a blocked Read or Write on
		// the same connection, and is what unblocks them.
		_ = c.ws.CloseNow()
	})
}

// Hub turns accepted WebSocket connections into a single ordered stream of
// Events for one consumer.
type Hub struct {
	events       chan Event
	writeTimeout time.Duration

	mu     sync.Mutex
	conns  map[*Conn]struct{}
	closed bool

	done chan struct{}
}

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

// ServeHTTP upgrades a request to WebSocket and blocks for the connection's
// lifetime.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
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

func (h *Hub) emit(ev Event) {
	select {
	case h.events <- ev:
	case <-h.done:
	}
}

// Close stops accepting connections and closes every open one. Safe to call
// more than once.
func (h *Hub) Close() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	close(h.done)
	open := make([]*Conn, 0, len(h.conns))
	for c := range h.conns {
		open = append(open, c)
	}
	h.mu.Unlock()

	for _, c := range open {
		c.close(DisconnectShutdown, "")
	}
}

// readPump reads frames until the connection fails, and returns the latched
// reason and detail it ended on.
//
// Reading c.closeReason unsynchronised is safe exactly here: sync.Once
// establishes a happens-before edge from the winning Do to every later Do that
// returns, so any caller of close happens-after the write.
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

// readReason classifies why a read stopped, by cause.
//
// A context error reaches here despite readPump passing context.Background():
// coder/websocket derives its own five-second deadline for control frames, so a
// jammed peer's pong surfaces as a wrapped context.DeadlineExceeded on this
// goroutine. It is a slow peer, not a clean logout, so it must not fall into
// DisconnectClosed. TestAJammedPongCondemnsTheClientAsPeerGone stages it;
// TestAReadContextDeadlineIsNotACleanClose pins the mapping.
func readReason(err error) (reason, detail string) {
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return DisconnectClosed, ""
	}
	return DisconnectPeerGone, DetailReadError
}

// writePump drains the send buffer onto the socket, and is the only writer.
//
// It must keep owning the write deadline rather than handing one to
// coder/websocket, which tears the connection down before returning the error
// and lets the read pump condemn it first (PROTOCOL.md, "The server owns the
// write deadline for data frames").
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
			condemn := time.AfterFunc(c.writeTimeout, func() {
				c.close(DisconnectSlow, DetailWriteTimeout)
			})
			err := c.ws.Write(context.Background(), websocket.MessageText, out.payload)
			condemn.Stop()
			if err != nil {
				c.close(DisconnectPeerGone, DetailWriteError)
				return
			}
		}
	}
}

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
