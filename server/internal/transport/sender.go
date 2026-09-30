package transport

import "bytes"

// State is a connection's lifecycle. It only ever leaves Open once.
type State uint8

const (
	Open State = iota
	// TimedOut: nothing arrived for TimeoutAfter.
	TimedOut
	// SlowClient: the reliable backlog passed Config.BacklogLimit. On the
	// server this is ADR 0018's slow_client; the client applies the same rule
	// to intents.
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
	// UnreliableSent is how many leading items of the Unreliable passed to
	// Flush made it into a datagram. The rest were trimmed by the budget.
	UnreliableSent int
	State          State
}

// Sender is the send half of a connection: packet sequencing, the reliable
// queue and its resends, the per-tick budget, keepalive, and timeout. It
// owns no receive state; Observe hands it what the Receiver learned.
type Sender struct {
	role Role
	cfg  Config

	nextSeq uint16
	sent    [256]sentPacket
	own     AckWindow

	base  uint16
	queue []*outMsg

	lastSend, lastRecv uint64
	state              State
}

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
	msg   *outMsg
	index uint8
}

func NewSender(role Role, cfg Config, now uint64) (*Sender, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &Sender{role: role, cfg: cfg, own: NoAcks, lastSend: now, lastRecv: now}, nil
}

func (s *Sender) State() State { return s.state }

// Backlog is how many reliable messages are queued and not fully acked.
func (s *Sender) Backlog() int { return len(s.queue) }

// Send queues one reliable message: one encoded schema message on this
// role's reliable channel. It is never dropped; if the backlog passes
// BacklogLimit the connection closes as SlowClient instead.
func (s *Sender) Send(msg []byte) error {
	if s.state != Open {
		return ErrClosed
	}
	if len(msg) == 0 || len(msg) > MaxMessage {
		return ErrMessage
	}
	n := (len(msg) + FragmentSize - 1) / FragmentSize
	s.queue = append(s.queue, &outMsg{data: bytes.Clone(msg), frags: make([]outFrag, n)})
	if len(s.queue) > s.cfg.BacklogLimit {
		s.state = SlowClient
	}
	return nil
}

// Observe feeds the sender what the Receiver learned from one accepted
// datagram at now.
func (s *Sender) Observe(peer, own AckWindow, now uint64) {
	if s.state != Open {
		return
	}
	s.lastRecv = max(s.lastRecv, now)
	s.own = own
	s.ack(peer.Latest)
	for i := uint16(0); i < AckBits; i++ {
		if peer.Bits&(1<<i) != 0 {
			s.ack(peer.Latest - 1 - i)
		}
	}
	for len(s.queue) > 0 && s.queue[0].done() {
		s.queue[0] = nil
		s.queue = s.queue[1:]
		s.base++
	}
}

func (s *Sender) ack(seq uint16) {
	p := &s.sent[seq%uint16(len(s.sent))]
	if !p.live || p.seq != seq {
		return
	}
	p.live = false
	for _, f := range p.frags {
		f.msg.frags[f.index].acked = true
	}
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

// Flush builds this tick's datagrams at now: due reliable fragments first,
// then as many leading items of u as the remaining budget allows, then a
// keepalive if nothing went out and KeepaliveAfter has passed.
func (s *Sender) Flush(now uint64, u Unreliable) (Flushed, error) {
	if s.state == Open && elapsed(now, s.lastRecv) >= TimeoutAfter {
		s.state = TimedOut
	}
	if s.state != Open {
		return Flushed{State: s.state}, nil
	}
	empty := HeaderSize + s.cfg.Seal.Overhead()
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

	s.eachDue(now, func(id uint16, m *outMsg, index int) bool {
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
		cur.entries = append(cur.entries, entry{id: id, index: uint8(index), count: uint8(len(m.frags)), data: data})
		cur.refs = append(cur.refs, fragRef{msg: m, index: uint8(index)})
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
		out.Datagrams = append(out.Datagrams, s.seal(d))
	}
	if len(done) > 0 {
		s.lastSend = now
	}
	return out, nil
}

func (s *Sender) eachDue(now uint64, f func(id uint16, m *outMsg, index int) bool) {
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
			if !f(s.base+uint16(i), m, j) {
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

func (s *Sender) seal(d *datagram) []byte {
	seq := s.nextSeq
	s.nextSeq++
	s.sent[seq%uint16(len(s.sent))] = sentPacket{live: true, seq: seq, frags: d.refs}

	hdr := putHeader(make([]byte, 0, MaxDatagram), header{protocol: ProtocolID, hash: s.cfg.SchemaHash, seq: seq, ack: s.own})
	body := encodeBody(nil, s.role, d.unreliable, d.entries)
	return s.cfg.Seal.Seal(hdr, hdr[:HeaderSize], body)
}
