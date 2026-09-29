package transport

import "bytes"

// Received is what one accepted datagram yields. Every byte slice is owned by
// the caller; none aliases the datagram.
type Received struct {
	// PeerAck is the peer's view of our packets, for Sender.Observe.
	PeerAck AckWindow
	// OwnAck is our view of the peer's packets after this datagram, for the
	// headers Sender writes.
	OwnAck AckWindow
	// Unreliable holds the unreliable section when it was present and newer
	// than every stamp delivered before. Items is nil otherwise.
	Unreliable Unreliable
	// Stale is set when an unreliable section was present but not newer.
	Stale bool
	// Reliable holds the reliable messages completed by this datagram, in
	// channel order.
	Reliable [][]byte
}

// Stats counts datagrams by outcome.
type Stats struct {
	Accepted, Duplicate, TooOld, Malformed, Foreign, Stale uint64
}

// Receiver is the receive half of a connection: the packet window, the
// unreliable staleness rule, and reliable reassembly. It shares nothing with
// Sender, so it can live on the socket reader goroutine.
type Receiver struct {
	from   Role
	hash   uint64
	seal   Seal
	window recvWindow

	haveStamp bool
	newest    uint32

	next     uint16
	partial  map[uint16]*inMsg
	buffered int

	stats   Stats
	scratch []byte
}

type inMsg struct {
	frags [][]byte
	got   int
}

// NewReceiver makes the receive half for a side playing role.
func NewReceiver(role Role, cfg Config) (*Receiver, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &Receiver{
		from:    role.peer(),
		hash:    cfg.SchemaHash,
		seal:    cfg.Seal,
		window:  recvWindow{AckWindow: NoAcks},
		partial: map[uint16]*inMsg{},
	}, nil
}

func (r *Receiver) Stats() Stats { return r.stats }

// Receive applies one datagram. It either commits the whole datagram or
// returns an error and changes nothing but Stats.
func (r *Receiver) Receive(d []byte) (Received, error) {
	if len(d) < HeaderSize+r.seal.Overhead() || len(d) > MaxDatagram {
		r.stats.Malformed++
		return Received{}, ErrMalformed
	}
	h := readHeader(d)
	if h.protocol != ProtocolID || h.hash != r.hash {
		r.stats.Foreign++
		return Received{}, ErrForeign
	}
	plain, err := r.seal.Open(r.scratch[:0], d[:HeaderSize], d[HeaderSize:])
	if err != nil {
		r.stats.Malformed++
		return Received{}, ErrMalformed
	}
	r.scratch = plain[:0]
	b, err := parseBody(plain, r.from)
	if err != nil {
		r.stats.Malformed++
		return Received{}, err
	}
	w, err := r.window.accept(h.seq)
	if err != nil {
		if err == ErrDuplicate {
			r.stats.Duplicate++
		} else {
			r.stats.TooOld++
		}
		return Received{}, err
	}

	r.window = w
	r.stats.Accepted++
	out := Received{PeerAck: h.ack, OwnAck: w.AckWindow}
	if u := b.unreliable; u != nil {
		if r.haveStamp && u.Stamp <= r.newest {
			r.stats.Stale++
			out.Stale = true
		} else {
			r.haveStamp, r.newest = true, u.Stamp
			out.Unreliable.Stamp = u.Stamp
			for _, it := range u.Items {
				out.Unreliable.Items = append(out.Unreliable.Items, bytes.Clone(it))
			}
		}
	}
	for _, e := range b.entries {
		r.store(e)
	}
	for m := r.partial[r.next]; m != nil && m.got == len(m.frags); m = r.partial[r.next] {
		msg := bytes.Join(m.frags, nil)
		r.buffered -= len(msg)
		out.Reliable = append(out.Reliable, msg)
		delete(r.partial, r.next)
		r.next++
	}
	return out, nil
}

// store buffers one fragment. A fragment a well-behaved sender could not
// have produced (outside the window, a fragment count that disagrees with an
// earlier one, or past WindowBytes) is ignored rather than failing the
// datagram, since only a hostile peer sends one and it only starves itself.
func (r *Receiver) store(e entry) {
	if e.id-r.next >= WindowMessages {
		return
	}
	m := r.partial[e.id]
	if m != nil && (len(m.frags) != int(e.count) || m.frags[e.index] != nil) {
		return
	}
	if r.buffered+len(e.data) > WindowBytes {
		return
	}
	if m == nil {
		m = &inMsg{frags: make([][]byte, e.count)}
		r.partial[e.id] = m
	}
	m.frags[e.index] = bytes.Clone(e.data)
	m.got++
	r.buffered += len(e.data)
}

type recvWindow struct {
	have bool
	AckWindow
}

// accept returns the window after receiving seq, or why seq is refused.
func (w recvWindow) accept(seq uint16) (recvWindow, error) {
	if !w.have {
		return recvWindow{have: true, AckWindow: AckWindow{Latest: seq}}, nil
	}
	ahead := seq - w.Latest
	switch {
	case ahead == 0:
		return w, ErrDuplicate
	case ahead < 0x8000:
		bits := uint32(0)
		if ahead < AckBits {
			bits = w.Bits<<ahead | 1<<(ahead-1)
		} else if ahead == AckBits {
			bits = 1 << (AckBits - 1)
		}
		return recvWindow{have: true, AckWindow: AckWindow{Latest: seq, Bits: bits}}, nil
	}
	behind := w.Latest - seq
	if behind > AckBits {
		return w, ErrTooOld
	}
	bit := uint32(1) << (behind - 1)
	if w.Bits&bit != 0 {
		return w, ErrDuplicate
	}
	w.Bits |= bit
	return w, nil
}
