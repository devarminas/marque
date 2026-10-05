package transport

import (
	"bytes"
	"errors"
)

type State uint8

const (
	Open State = iota
	TimedOut
	SlowClient
)

func (s State) String() string {
	switch s {
	case Open:
		return "open"
	case TimedOut:
		return "timed_out"
	case SlowClient:
		return "slow_client"
	}
	return "state?"
}

type Flushed struct {
	Datagrams [][]byte
	UnreliableSent int
	UnreliableSeq  uint16
	State          State
}

type Sender struct {
	role Role
	cfg  Config
	seal Sealer

	nextSeq uint16
	sent    [256]sentPacket
	own     AckWindow

	front  uint64
	queue  []*outMsg
	queued int

	lastSend, lastRecv uint64
	state              State
	capture            func(uint64, []byte, []byte)
}

func (s *Sender) SetCapture(capture func(uint64, []byte, []byte)) { s.capture = capture }

type outMsg struct {
	data  []byte
	frags []outFrag
}

type outFrag struct {
	acked, sent bool
	lastSent    uint64
}

func (f outFrag) due(now, resendAfter uint64) bool {
	return !f.acked && (!f.sent || elapsed(now, f.lastSent) >= resendAfter)
}

func elapsed(now, since uint64) uint64 {
	if now < since {
		return 0
	}
	return now - since
}

type sentPacket struct {
	live  bool
	seq   uint16
	frags []fragRef
}

type fragRef struct {
	serial uint64
	index  uint8
}

func NewSender(role Role, cfg Config, seal Sealer, now uint64) (*Sender, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	if seal == nil {
		return nil, errors.New("transport: Sealer is nil")
	}
	return &Sender{role: role, cfg: cfg, seal: seal, own: NoAcks, lastSend: now, lastRecv: now}, nil
}

func (s *Sender) State() State { return s.state }

func (s *Sender) Backlog() int { return len(s.queue) }

func (s *Sender) Send(msg []byte) error {
	if s.state != Open {
		return ErrClosed
	}
	if len(msg) == 0 || len(msg) > MaxMessage {
		return ErrMessage
	}
	n := (len(msg) + FragmentSize - 1) / FragmentSize
	s.queue = append(s.queue, &outMsg{data: bytes.Clone(msg), frags: make([]outFrag, n)})
	s.queued += len(msg)
	if len(s.queue) > s.cfg.BacklogLimit || s.queued > s.cfg.BacklogBytes {
		s.close(SlowClient)
	}
	return nil
}

func (s *Sender) close(state State) {
	s.state = state
	s.queue = nil
	s.queued = 0
	s.sent = [256]sentPacket{}
}

func (s *Sender) Observe(peer, own AckWindow, now uint64) {
	if s.state != Open {
		return
	}
	s.lastRecv = max(s.lastRecv, now)
	s.own = own
	if peer == NoAcks {
		return
	}
	s.ack(peer.Latest)
	for i := uint16(0); i < AckBits; i++ {
		if peer.Bits&(1<<i) != 0 {
			s.ack(peer.Latest - 1 - i)
		}
	}
	for len(s.queue) > 0 && s.queue[0].done() {
		s.queued -= len(s.queue[0].data)
		s.queue[0] = nil
		s.queue = s.queue[1:]
		s.front++
	}
}

func (s *Sender) ack(seq uint16) {
	p := &s.sent[seq%uint16(len(s.sent))]
	if !p.live || p.seq != seq {
		return
	}
	p.live = false
	for _, f := range p.frags {
		if i := f.serial - s.front; i < uint64(len(s.queue)) {
			s.queue[i].frags[f.index].acked = true
		}
	}
	p.frags = nil
}

func (m *outMsg) done() bool {
	for _, f := range m.frags {
		if !f.acked {
			return false
		}
	}
	return true
}

type datagram struct {
	size, cap  int
	unreliable *Unreliable
	entries    []entry
	refs       []fragRef
}

func (s *Sender) Flush(now uint64, u Unreliable) (Flushed, error) {
	if s.state == Open && elapsed(now, s.lastRecv) >= TimeoutAfter {
		s.close(TimedOut)
	}
	if s.state != Open {
		return Flushed{State: s.state}, nil
	}
	empty := HeaderSize + s.seal.Overhead()
	for _, it := range u.Items {
		if len(it) == 0 || empty+unreliableSectionHeader+itemSize(it) > MaxDatagram {
			return Flushed{State: s.state}, ErrItem
		}
	}

	left := s.cfg.TickBudget
	var done []*datagram
	var cur *datagram
	room := func() int {
		if cur == nil {
			return min(MaxDatagram, left)
		}
		return min(MaxDatagram, left-cur.size)
	}
	open := func() {
		if cur != nil {
			left -= cur.size
			done = append(done, cur)
		}
		cur = &datagram{size: empty, cap: min(MaxDatagram, left)}
	}

	s.eachDue(now, func(serial uint64, m *outMsg, index int) bool {
		lo := index * FragmentSize
		data := m.data[lo:min(lo+FragmentSize, len(m.data))]
		add := entrySize(data)
		if cur == nil || cur.size+add+sectionCost(cur.entries) > cur.cap {
			if empty+reliableSectionHeader+add > room() {
				return false
			}
			open()
		}
		cur.size += add + sectionCost(cur.entries)
		cur.entries = append(cur.entries, entry{id: uint16(serial), index: uint8(index), count: uint8(len(m.frags)), data: data})
		cur.refs = append(cur.refs, fragRef{serial: serial, index: uint8(index)})
		m.frags[index].sent = true
		m.frags[index].lastSent = now
		return true
	})

	sent := 0
	if len(u.Items) > 0 {
		inCur := 0
		if cur != nil {
			inCur = fitItems(u.Items, cur.cap-cur.size)
		}
		inNew := fitItems(u.Items, room()-empty)
		if inCur >= inNew && inCur > 0 {
			sent = inCur
		} else if inNew > 0 {
			open()
			sent = inNew
		}
		if sent > 0 {
			cur.unreliable = &Unreliable{Stamp: u.Stamp, Items: u.Items[:sent]}
		}
	}
	if cur != nil {
		done = append(done, cur)
	}
	if len(done) == 0 && elapsed(now, s.lastSend) >= KeepaliveAfter {
		done = append(done, &datagram{})
	}

	out := Flushed{UnreliableSent: sent, State: Open}
	for _, d := range done {
		if d.unreliable != nil {
			out.UnreliableSeq = s.nextSeq
		}
		out.Datagrams = append(out.Datagrams, s.emit(d, now))
	}
	if len(done) > 0 {
		s.lastSend = now
	}
	return out, nil
}

func (s *Sender) eachDue(now uint64, f func(serial uint64, m *outMsg, index int) bool) {
	total := 0
	for i, m := range s.queue {
		total += len(m.data)
		if i >= WindowMessages || total > WindowBytes {
			return
		}
		for j, fr := range m.frags {
			if !fr.due(now, s.cfg.ResendAfter) {
				continue
			}
			if !f(s.front+uint64(i), m, j) {
				return
			}
		}
	}
}

func sectionCost(entries []entry) int {
	if len(entries) == 0 {
		return reliableSectionHeader
	}
	return 0
}

func fitItems(items [][]byte, room int) int {
	used := unreliableSectionHeader
	for i, it := range items {
		used += itemSize(it)
		if used > room {
			return i
		}
	}
	return len(items)
}

func (s *Sender) emit(d *datagram, now uint64) []byte {
	seq := s.nextSeq
	s.nextSeq++
	s.sent[seq%uint16(len(s.sent))] = sentPacket{live: true, seq: seq, frags: d.refs}

	hdr := putHeader(make([]byte, 0, MaxDatagram), header{protocol: ProtocolID, hash: s.cfg.SchemaHash, seq: seq, ack: s.own})
	body := encodeBody(nil, s.role, d.unreliable, d.entries)
	if s.capture != nil {
		s.capture(now, bytes.Clone(hdr[:HeaderSize]), bytes.Clone(body))
	}
	return s.seal.Seal(hdr, hdr[:HeaderSize], body)
}
