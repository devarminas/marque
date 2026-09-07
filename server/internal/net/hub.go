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

const (
	DisconnectClosed   = "closed"
	DisconnectPeerGone = "peer_gone"
	DisconnectSlow     = "slow_client"
	DisconnectShutdown = "server_shutdown"
	DisconnectProtocol = "protocol_error"
	DisconnectRefused = "refused"
)

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

type Event struct {
	Kind EventKind
	Conn *Conn

	Msg ClientMessage
	Err error

	Seq Seq

	Reason string
	Detail string
}

func (ev Event) Name() string {
	if ev.Msg != nil {
		return ev.Msg.Name()
	}
	if rejection, ok := Rejection(ev.Err); ok {
		return rejection.Re
	}
	return ""
}

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

func (c *Conn) Remote() string { return c.remote }

func (c *Conn) Session() string { return c.session }

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

func (h *Hub) Events() <-chan Event { return h.events }

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
