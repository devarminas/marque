package transport

import (
	"errors"
	"net"
	"net/netip"
	"time"

	"github.com/devarminas/marque/server/internal/wire"
)

// Inbound is what the socket reader goroutine hands the tick loop for one
// accepted datagram (ADR 0018 section 1.9). It carries decoded messages and
// ack windows by value; the reader keeps no reference to anything in it.
type Inbound struct {
	From            netip.AddrPort
	At              uint64
	PeerAck, OwnAck AckWindow
	// InputStamp and Input are set when the input section was fresh.
	InputStamp uint32
	Input      []wire.InputMsg
	Intents    []wire.IntentsMsg
	// Fault is a delivered message that failed its schema decode. The reader
	// has already forgotten the peer; the tick loop drops its Sender.
	Fault error
}

// Reader is the state of the server's one socket reader goroutine: a
// Receiver per peer and nothing else. It cannot reach game state; its only
// output is the Inbound channel.
type Reader struct {
	conn  *net.UDPConn
	cfg   Config
	clock func() uint64
	peers map[netip.AddrPort]*Receiver
}

// NewReader serves the given peers. Until ARM-354 adds the handshake, which
// will allocate Receivers here, the peer set is fixed at construction.
func NewReader(conn *net.UDPConn, cfg Config, clock func() uint64, peers ...netip.AddrPort) (*Reader, error) {
	rd := &Reader{conn: conn, cfg: cfg, clock: clock, peers: map[netip.AddrPort]*Receiver{}}
	for _, p := range peers {
		rx, err := NewReceiver(Server, cfg)
		if err != nil {
			return nil, err
		}
		rd.peers[p] = rx
	}
	return rd, nil
}

// Run reads until the socket closes, then closes out and returns nil.
// Datagrams from unknown peers and datagrams the Receiver refuses are dropped.
func (rd *Reader) Run(out chan<- Inbound) error {
	defer close(out)
	buf := make([]byte, MaxDatagram+1)
	for {
		n, from, err := rd.conn.ReadFromUDPAddrPort(buf)
		if errors.Is(err, net.ErrClosed) {
			return nil
		}
		if err != nil {
			return err
		}
		rx := rd.peers[from]
		if rx == nil {
			continue
		}
		r, err := rx.Receive(buf[:n])
		if err != nil {
			continue
		}
		in, ok := decode(r)
		in.From, in.At = from, rd.clock()
		if !ok {
			delete(rd.peers, from)
		}
		out <- in
	}
}

func decode(r Received) (Inbound, bool) {
	in := Inbound{PeerAck: r.PeerAck, OwnAck: r.OwnAck}
	if r.Unreliable.Items != nil {
		in.InputStamp = r.Unreliable.Stamp
		for _, it := range r.Unreliable.Items {
			m, err := wire.DecodeInput(it)
			if err != nil {
				in.Fault = err
				return in, false
			}
			in.Input = append(in.Input, m)
		}
	}
	for _, it := range r.Reliable {
		m, err := wire.DecodeIntents(it)
		if err != nil {
			in.Fault = err
			return in, false
		}
		in.Intents = append(in.Intents, m)
	}
	return in, true
}

// MonotonicClock returns microseconds since it was created, for the reader
// and the tick loop to share as the transport's clock.
func MonotonicClock() func() uint64 {
	start := time.Now()
	return func() uint64 { return uint64(time.Since(start).Microseconds()) }
}
