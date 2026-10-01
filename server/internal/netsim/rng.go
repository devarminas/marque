package netsim

type rng struct {
	state uint64
}

func newRNG(seed uint64) *rng {
	return &rng{state: seed}
}

func (r *rng) uint64() uint64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

const ppmScale = 1_000_000

func bernoulliPPM(r *rng, ppm uint32) bool {
	return r.uint64()%ppmScale < uint64(ppm)
}

func uniformMicros(r *rng, rangeMicros uint64) uint64 {
	draw := r.uint64()
	if rangeMicros == 0 {
		return 0
	}
	return draw % (rangeMicros + 1)
}
