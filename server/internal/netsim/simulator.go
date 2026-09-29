package netsim

// Direction picks which of the simulator's two independent packet streams
// a call applies to.
type Direction int

const (
	AToB Direction = iota
	BToA
)

// Direction salts mix the shared seed into two unrelated RNG states. XOR
// with the seed rather than a separate derive step: cheap, and any nonzero
// salt distinct per direction is enough to decorrelate the two streams
// since splitmix64's avalanche mixes the whole state on the first draw.
const (
	dirSaltAToB uint64 = 0xA5A5A5A5A5A5A5A5
	dirSaltBToA uint64 = 0x5A5A5A5A5A5A5A5A
)

// Simulator sits between two endpoints and decides, deterministically from
// a seed and a Profile, whether each sent packet is dropped, delayed,
// duplicated, or reordered before Poll hands it back. It never inspects
// packet contents and never reads wall time; every packet moves as an
// opaque byte slice and every delay is relative to the now callers pass.
type Simulator struct {
	profile Profile
	ab      *directionSim
	ba      *directionSim
}

// New constructs a simulator for profile, seeded so that the same seed and
// profile always produce the same fate sequence in both directions and
// across runs.
func New(profile Profile, seed uint64) *Simulator {
	return &Simulator{
		profile: profile,
		ab:      newDirectionSim(seed ^ dirSaltAToB),
		ba:      newDirectionSim(seed ^ dirSaltBToA),
	}
}

// Send hands the simulator a packet sent at time now (caller-owned clock,
// never wall time). Its fate (drop, delay, duplicate, reorder) is decided
// immediately, deterministically, from the direction's RNG stream.
func (s *Simulator) Send(dir Direction, packet []byte, now uint64) {
	s.stream(dir).send(s.profile, packet, now)
}

// Poll drains and returns every packet due at or before now, in delivery
// order.
func (s *Simulator) Poll(dir Direction, now uint64) []Delivery {
	return s.stream(dir).poll(now)
}

func (s *Simulator) stream(dir Direction) *directionSim {
	if dir == AToB {
		return s.ab
	}
	return s.ba
}
