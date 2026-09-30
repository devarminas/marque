package transport

import (
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/devarminas/marque/server/internal/wire"
)

type Inbound struct {
	From            netip.AddrPort
	At              uint64
	PeerAck, OwnAck AckWindow
	InputStamp uint32
	Input      []wire.InputMsg
	Intents    []wire.IntentsMsg
	Fault error
}

type Reader struct {
	conn  *net.UDPConn
	cfg   Config
	clock func() uint64
	peers map[netip.AddrPort]*Receiver

	mu     sync.Mutex
	forget []netip.AddrPort
}

func (rd *Reader) Forget(peer netip.AddrPort) {
	rd.mu.Lock()
	rd.forget = append(rd.forget, peer)
	rd.mu.Unlock()
}

func (rd *Reader) drainForget() {
	rd.mu.Lock()
	gone := rd.forget
	rd.forget = nil
	rd.mu.Unlock()
	for _, p := range gone {
		delete(rd.peers, p)
	}
}

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
		rd.drainForget()
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

func MonotonicClock() func() uint64 {
	start := time.Now()
	return func() uint64 { return uint64(time.Since(start).Microseconds()) }
}
