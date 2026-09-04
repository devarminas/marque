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

// Disconnect reasons reported on EventDisconnected (PROTOCOL.md, "Which reason
// is authoritative").
const (
	DisconnectClosed   = "closed"
	DisconnectPeerGone = "peer_gone"
	DisconnectSlow     = "slow_client"
	DisconnectShutdown = "server_shutdown"
	DisconnectProtocol = "protocol_error"
	// DisconnectRefused: turned away at the door because the token's player is
	// still connected.
	DisconnectRefused = "refused"
)

// SessionParam is the WebSocket URL query parameter carrying a resuming
// client's session token, as in ws://host/ws?session=<token>.
const SessionParam = "session"

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

// Event is one thing that happened on one connection. Per connection they
// arrive as EventConnected, zero or more EventFrame, then one EventDisconnected.
type Event struct {
	Kind EventKind
	Conn *Conn

	// Exactly one of Msg and Err is set, and only when Kind is EventFrame. Err
	// is a *RejectError.
	Msg ClientMessage
	Err error

	// Seq is the envelope's sequence number, set even when Err rejects the
	// body, and 0 when the frame carried none.
	Seq Seq

	// Reason is one of the Disconnect constants; Detail one of the Detail
	// constants, or empty. Nothing may branch on Detail.
	Reason string
	Detail string
}

// Name is the wire name of the message this event is about, or empty for a
// frame too malformed to attribute to one.
func (ev Event) Name() string {
	if ev.Msg != nil {
		return ev.Msg.Name()
	}
	if rejection, ok := Rejection(ev.Err); ok {
		return rejection.Re
	}
	return ""
}

// Conn is one client connection.
type Conn struct {
	ws           *websocket.Conn
	remote       string
	session      string
	send         chan outgoing
	writeTimeout time.Duration

	closeOnce   sync.Once
	closed      chan struct{}
	closeReason string
	closeDetail string
}

// Remote is the peer address, for logging only. It is not an identity.
func (c *Conn) Remote() string { return c.remote }

// Session is the session token this connection presented, or empty. It is a
// claim, not a fact; the world decides what it entitles.
func (c *Conn) Session() string { return c.session }

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
		// CloseNow is the documented way to unblock a concurrent Read or Write.
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
	session := r.URL.Query().Get(SessionParam)

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		return
	}

	conn := &Conn{
		ws:           ws,
		remote:       r.RemoteAddr,
		session:      session,
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

// readPump reads c.closeReason unsynchronised: sync.Once's winning Do
// happens-before every later Do that returns.
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
		msg, seq, decErr := Decode(data)
		h.emit(Event{Kind: EventFrame, Conn: c, Msg: msg, Seq: seq, Err: decErr})
	}
}

// readReason maps a read error to a reason. coder/websocket's internal 5s
// control-frame deadline surfaces here as context.DeadlineExceeded, which is a
// jammed peer, not a clean close (TestAJammedPongCondemnsTheClientAsPeerGone,
// TestAReadContextDeadlineIsNotACleanClose).
func readReason(err error) (reason, detail string) {
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return DisconnectClosed, ""
	}
	return DisconnectPeerGone, DetailReadError
}

// writePump owns the write deadline itself: a deadline-bearing context makes
// coder/websocket tear the connection down before returning the error, and the
// read pump would then win the reason (PROTOCOL.md, "The server owns the write
// deadline for data frames").
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
