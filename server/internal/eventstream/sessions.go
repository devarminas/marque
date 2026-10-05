package eventstream

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"math"
)

const MaxCanonicalIntentBytes = 1032

type CapacityError struct{ RetiredOwners []game.PlayerHandle }

func (e *CapacityError) Error() string {
	return "eventstream: owner journals exhausted; other owners appended"
}
func (e *CapacityError) Unwrap() error { return ErrCapacity }

type SessionID uint64
type AccountID uint64
type StreamID uint64
type Epoch uint64

type Config struct {
	MaxSessions                               int
	JournalBytes, JournalEvents, OfferedTicks int
	GraceTicks                                uint32
}

func DefaultConfig() Config {
	return Config{MaxSessions: 5000, JournalBytes: 262144, JournalEvents: 4096, OfferedTicks: 1024, GraceTicks: 1500}
}

var (
	ErrSession   = errors.New("eventstream: unknown or expired session")
	ErrAccount   = errors.New("eventstream: account mismatch")
	ErrConnected = errors.New("eventstream: session already connected")
	ErrEpoch     = errors.New("eventstream: stale connection epoch")
	ErrSequence  = errors.New("eventstream: intent sequence gap or changed retained duplicate")
	ErrCommit    = errors.New("eventstream: commit does not match an offered boundary")
	ErrCapacity  = errors.New("eventstream: retention capacity exhausted")
	ErrTick      = errors.New("eventstream: invalid tick boundary")
	ErrExhausted = errors.New("eventstream: identity exhausted")
)

type lifecycle uint8

const (
	suspended lifecycle = iota
	connected
	expired
)

type Fact struct {
	Seq   uint64
	Tick  uint32
	Value game.OwnerValue
}
type Boundary struct {
	Stream     StreamID
	Epoch      Epoch
	Tick       uint32
	EventEnd   uint64
	StateItems uint16
	NextIntent uint32
}
type Commit struct {
	Stream   StreamID
	Epoch    Epoch
	Tick     uint32
	EventEnd uint64
}
type ResumePlan struct {
	Stream            StreamID
	Epoch             Epoch
	Player            game.PlayerHandle
	AppliedEvent      uint64
	NextIntent        uint32
	ClosedThrough     uint32
	EventEnd          uint64
	FullStateRequired bool
}
type retained struct {
	fact Fact
	data []byte
}
type session struct {
	account      AccountID
	stream       StreamID
	player       game.PlayerHandle
	status       lifecycle
	epoch        Epoch
	expiresAt    uint64
	nextIntent   uint64
	lastInput    uint32
	lastCommand  []byte
	nextEvent    uint64
	applied      Commit
	haveApplied  bool
	journal      []retained
	journalBytes int
	offered      []Boundary
	queued       uint64
	tick         uint32
	haveTick     bool
	tickDigest   [32]byte
	tickCount    uint64
}
type Sessions struct {
	cfg       Config
	sessions  map[SessionID]*session
	owners    map[game.PlayerHandle]SessionID
	maxStream StreamID
}

func New(cfg Config) (*Sessions, error) {
	if cfg.MaxSessions < 1 || cfg.JournalBytes < 1 || cfg.JournalEvents < 1 || cfg.OfferedTicks < 1 || cfg.GraceTicks < 1 {
		return nil, ErrCapacity
	}
	return &Sessions{cfg: cfg, sessions: map[SessionID]*session{}, owners: map[game.PlayerHandle]SessionID{}}, nil
}
func (ss *Sessions) Create(id SessionID, account AccountID, stream StreamID, owner game.PlayerHandle, tick uint32) error {
	if id == 0 || account == 0 || stream == 0 || owner.Index == 0 || owner.Gen == 0 {
		return ErrSession
	}
	if _, ok := ss.sessions[id]; ok {
		return ErrSession
	}
	if _, ok := ss.owners[owner]; ok {
		return ErrSession
	}
	if stream <= ss.maxStream {
		return ErrSession
	}
	if len(ss.sessions) >= ss.cfg.MaxSessions {
		return ErrCapacity
	}
	ss.sessions[id] = &session{account: account, stream: stream, player: owner, status: suspended, expiresAt: uint64(tick) + uint64(ss.cfg.GraceTicks), nextIntent: 1, nextEvent: 1}
	ss.owners[owner] = id
	ss.maxStream = stream
	return nil
}
func (ss *Sessions) Attach(id SessionID, account AccountID, tick uint32) (ResumePlan, error) {
	s := ss.sessions[id]
	if s == nil || s.status == expired {
		return ResumePlan{}, ErrSession
	}
	if s.account != account {
		return ResumePlan{}, ErrAccount
	}
	if s.status == connected {
		return ResumePlan{}, ErrConnected
	}
	if uint64(tick) >= s.expiresAt {
		s.status = expired
		return ResumePlan{}, ErrSession
	}
	if s.epoch == Epoch(math.MaxUint64) {
		s.status = expired
		return ResumePlan{}, ErrExhausted
	}
	s.epoch++
	s.status = connected
	s.offered = nil
	s.queued = s.applied.EventEnd
	return ResumePlan{Stream: s.stream, Epoch: s.epoch, Player: s.player, AppliedEvent: s.applied.EventEnd, NextIntent: uint32(s.nextIntent), ClosedThrough: s.tick, EventEnd: s.nextEvent - 1, FullStateRequired: true}, nil
}
func (ss *Sessions) bound(id SessionID, epoch Epoch) (*session, error) {
	s := ss.sessions[id]
	if s == nil || s.status == expired {
		return nil, ErrSession
	}
	if s.status != connected || s.epoch != epoch {
		return nil, ErrEpoch
	}
	return s, nil
}
func (ss *Sessions) Resolve(id SessionID, epoch Epoch) (game.PlayerHandle, error) {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return game.PlayerHandle{}, err
	}
	return s.player, nil
}
func (ss *Sessions) Suspend(id SessionID, epoch Epoch, tick uint32) error {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return err
	}
	s.status = suspended
	s.expiresAt = uint64(tick) + uint64(ss.cfg.GraceTicks)
	s.offered = nil
	return nil
}
func (ss *Sessions) Expire(tick uint32) []game.PlayerHandle {
	var owners []game.PlayerHandle
	for id, s := range ss.sessions {
		if s.status == expired || (s.status == suspended && uint64(tick) >= s.expiresAt) {
			owners = append(owners, s.player)
			delete(ss.owners, s.player)
			delete(ss.sessions, id)
		}
	}
	return owners
}

func (ss *Sessions) AcceptIntent(id SessionID, epoch Epoch, seq uint32, canonical []byte) (bool, error) {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return false, err
	}
	if len(canonical) == 0 || len(canonical) > MaxCanonicalIntentBytes {
		return false, ErrSequence
	}
	if seq == 0 || uint64(seq) > s.nextIntent {
		return false, ErrSequence
	}
	if uint64(seq) < s.nextIntent {
		if uint64(seq) == s.nextIntent-1 && !bytes.Equal(canonical, s.lastCommand) {
			return false, ErrSequence
		}
		return false, nil
	}
	if s.nextIntent == math.MaxUint32 {
		return false, ErrExhausted
	}
	s.nextIntent++
	s.lastCommand = bytes.Clone(canonical)
	return true, nil
}
func (ss *Sessions) AppendAt(tick uint32, changes []game.OwnerChange) error {
	grouped := map[SessionID][]game.OwnerChange{}
	for _, change := range changes {
		id, ok := ss.owners[change.Player]
		if !ok || change.Tick != tick {
			return ErrTick
		}
		grouped[id] = append(grouped[id], change)
	}
	type pending struct {
		s         *session
		facts     []retained
		digest    [32]byte
		duplicate bool
		overflow  bool
	}
	prepared := make([]pending, 0, len(ss.sessions))
	for id, s := range ss.sessions {
		if s.status == expired {
			continue
		}
		if s.haveTick && tick < s.tick {
			return ErrTick
		}
		batch := grouped[id]
		first := s.nextEvent
		duplicate := s.haveTick && tick == s.tick
		if duplicate {
			first -= s.tickCount
		}
		if uint64(len(batch)) > math.MaxUint64-first {
			return ErrExhausted
		}
		p := pending{s: s, duplicate: duplicate}
		h := sha256.New()
		nbytes := 0
		for i, change := range batch {
			seq := first + uint64(i)
			data, err := encode(uint64(s.stream), seq, tick, change.Value)
			if err != nil {
				return err
			}
			h.Write(data)
			nbytes += len(data)
			p.facts = append(p.facts, retained{Fact{seq, tick, game.CloneOwnerValue(change.Value)}, data})
		}
		copy(p.digest[:], h.Sum(nil))
		if duplicate {
			if uint64(len(batch)) != s.tickCount || p.digest != s.tickDigest {
				return ErrTick
			}
		} else if len(s.journal)+len(batch) > ss.cfg.JournalEvents || s.journalBytes+nbytes > ss.cfg.JournalBytes {
			p.overflow = true
		}
		prepared = append(prepared, p)
	}
	retired := &CapacityError{}
	for _, p := range prepared {
		if p.overflow {
			p.s.status = expired
			retired.RetiredOwners = append(retired.RetiredOwners, p.s.player)
			continue
		}
		if p.duplicate {
			continue
		}
		s := p.s
		for _, r := range p.facts {
			s.journal = append(s.journal, r)
			s.journalBytes += len(r.data)
		}
		s.nextEvent += uint64(len(p.facts))
		s.tick = tick
		s.haveTick = true
		s.tickDigest = p.digest
		s.tickCount = uint64(len(p.facts))
	}
	if len(retired.RetiredOwners) > 0 {
		return retired
	}
	return nil
}
func (ss *Sessions) QueueEvents(id SessionID, epoch Epoch, sender *transport.Sender) error {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return err
	}
	for _, r := range s.journal {
		if r.fact.Seq <= s.queued {
			continue
		}
		if err := sender.Send(r.data); err != nil {
			return err
		}
		if sender.State() != transport.Open {
			return transport.ErrClosed
		}
		s.queued = r.fact.Seq
	}
	return nil
}
func (ss *Sessions) CloseTick(id SessionID, epoch Epoch, tick uint32, actualStateItems int, sender *transport.Sender) (Boundary, error) {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return Boundary{}, err
	}
	if !s.haveTick || tick != s.tick || actualStateItems < 0 || actualStateItems > math.MaxUint16 {
		return Boundary{}, ErrTick
	}
	b := Boundary{Stream: s.stream, Epoch: epoch, Tick: tick, EventEnd: s.nextEvent - 1, StateItems: uint16(actualStateItems), NextIntent: uint32(s.nextIntent)}
	for _, old := range s.offered {
		if old.Tick == tick {
			if old.Stream != b.Stream || old.Epoch != b.Epoch || old.EventEnd != b.EventEnd || old.StateItems != b.StateItems {
				return Boundary{}, ErrTick
			}
			return old, nil
		}
	}
	if len(s.offered) >= ss.cfg.OfferedTicks {
		return Boundary{}, ErrCapacity
	}
	if err := ss.QueueEvents(id, epoch, sender); err != nil {
		return Boundary{}, err
	}
	data, err := built(wire.TickCloseFields{Stream: uint64(s.stream), Epoch: uint64(epoch), Tick: tick, EventEnd: b.EventEnd, StateItems: b.StateItems, NextIntent: b.NextIntent}.Build())
	if err != nil {
		return Boundary{}, err
	}
	if err := sender.Send(data); err != nil {
		return Boundary{}, err
	}
	if sender.State() != transport.Open {
		return Boundary{}, transport.ErrClosed
	}
	s.offered = append(s.offered, b)
	return b, nil
}
func (ss *Sessions) Commit(id SessionID, commit Commit) error {
	s, err := ss.bound(id, commit.Epoch)
	if err != nil {
		return err
	}
	if commit.Stream != s.stream {
		return ErrCommit
	}
	if s.haveApplied && commit.Tick == s.applied.Tick && commit.EventEnd == s.applied.EventEnd {
		return nil
	}
	if commit.Tick < s.applied.Tick || commit.EventEnd < s.applied.EventEnd {
		return ErrCommit
	}
	found := -1
	for i, b := range s.offered {
		if b.Tick == commit.Tick && b.EventEnd == commit.EventEnd {
			found = i
			break
		}
	}
	if found < 0 {
		return ErrCommit
	}
	s.applied = commit
	s.haveApplied = true
	cut := 0
	for cut < len(s.journal) && s.journal[cut].fact.Seq <= commit.EventEnd {
		s.journalBytes -= len(s.journal[cut].data)
		s.journal[cut] = retained{}
		cut++
	}
	s.journal = append([]retained(nil), s.journal[cut:]...)
	s.offered = append([]Boundary(nil), s.offered[found+1:]...)
	return nil
}
func (ss *Sessions) Journal(id SessionID) ([]Fact, error) {
	s := ss.sessions[id]
	if s == nil || s.status == expired {
		return nil, ErrSession
	}
	out := make([]Fact, len(s.journal))
	for i, r := range s.journal {
		out[i] = Fact{r.fact.Seq, r.fact.Tick, game.CloneOwnerValue(r.fact.Value)}
	}
	return out, nil
}

func (ss *Sessions) QueueResume(id SessionID, epoch Epoch, sender *transport.Sender) error {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return err
	}
	if err := ss.QueueEvents(id, epoch, sender); err != nil {
		return err
	}
	data, err := built(wire.ResumeBoundaryFields{Stream: uint64(s.stream), Epoch: uint64(epoch), Tick: s.tick, EventEnd: s.nextEvent - 1, AppliedEvent: s.applied.EventEnd, NextIntent: uint32(s.nextIntent)}.Build())
	if err != nil {
		return err
	}
	if err := sender.Send(data); err != nil {
		return err
	}
	if sender.State() != transport.Open {
		return transport.ErrClosed
	}
	return nil
}

func (ss *Sessions) AcceptInput(id SessionID, epoch Epoch, seq uint32) (bool, error) {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return false, err
	}
	if seq == 0 {
		return false, ErrSequence
	}
	if seq <= s.lastInput {
		return false, nil
	}
	s.lastInput = seq
	return true, nil
}
