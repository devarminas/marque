package transport

import (
	"bytes"
	"slices"
)

type Received struct {
	PeerAck AckWindow
	OwnAck AckWindow
	Unreliable Unreliable
	Stale bool
	Reliable [][]byte
}

type Stats struct {
	Accepted, Duplicate, TooOld, Malformed, Foreign, Stale uint64
}

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
	count uint8
	frags []inFrag
}

type inFrag struct {
	index uint8
	data  []byte
}

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
	for m := r.partial[r.next]; m != nil && len(m.frags) == int(m.count); m = r.partial[r.next] {
		var msg []byte
		for _, f := range m.frags {
			msg = append(msg, f.data...)
		}
		r.buffered -= len(msg)
		out.Reliable = append(out.Reliable, msg)
		delete(r.partial, r.next)
		r.next++
	}
	return out, nil
}

func (r *Receiver) store(e entry) {
	if e.id-r.next >= WindowMessages {
		return
	}
	m := r.partial[e.id]
	if m != nil && m.count != e.count {
		return
	}
	at := 0
	if m != nil {
		at, _ = slices.BinarySearchFunc(m.frags, e.index, func(f inFrag, index uint8) int { return int(f.index) - int(index) })
		if at < len(m.frags) && m.frags[at].index == e.index {
			return
		}
	}
	if r.buffered+len(e.data) > WindowBytes {
		return
	}
	if m == nil {
		m = &inMsg{count: e.count}
		r.partial[e.id] = m
	}
	m.frags = slices.Insert(m.frags, at, inFrag{index: e.index, data: bytes.Clone(e.data)})
	r.buffered += len(e.data)
}

type recvWindow struct {
	have bool
	AckWindow
}

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
