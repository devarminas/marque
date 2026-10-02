package netsim

type Direction int

const (
	AToB Direction = iota
	BToA
)

const (
	dirSaltAToB uint64 = 0xA5A5A5A5A5A5A5A5
	dirSaltBToA uint64 = 0x5A5A5A5A5A5A5A5A
)

type Simulator struct {
	profile Profile
	ab      *directionSim
	ba      *directionSim
}

func New(profile Profile, seed uint64) *Simulator {
	return &Simulator{
		profile: profile,
		ab:      newDirectionSim(seed ^ dirSaltAToB),
		ba:      newDirectionSim(seed ^ dirSaltBToA),
	}
}

func (s *Simulator) Send(dir Direction, packet []byte, now uint64) {
	s.stream(dir).send(s.profile, packet, now)
}

func (s *Simulator) Poll(dir Direction, now uint64) []Delivery {
	return s.stream(dir).poll(now)
}

func (s *Simulator) stream(dir Direction) *directionSim {
	if dir == AToB {
		return s.ab
	}
	return s.ba
}
