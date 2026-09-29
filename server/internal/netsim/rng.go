// Package netsim is a deterministic network simulator: given a fixed seed
// and a loss/delay/duplication/reorder profile, it decides the fate of each
// packet the same way on every run. A C++ implementation under
// native/core/{include,src}/netsim mirrors this package byte for byte, so
// the two must never diverge in RNG algorithm, draw order, or arithmetic.
package netsim

// rng is splitmix64: one 64-bit state word advanced by a fixed increment,
// mixed through fixed shift/multiply constants. Chosen over the standard
// library's PRNGs because splitmix64 is trivial to reimplement bit-exact in
// C++: unsigned 64-bit add/xor/multiply wrap identically in both languages,
// so the same seed produces the same draw sequence in Go and C++.
type rng struct {
	state uint64
}

func newRNG(seed uint64) *rng {
	return &rng{state: seed}
}

// uint64 returns the next draw and advances the stream.
func (r *rng) uint64() uint64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

const ppmScale = 1_000_000

// bernoulliPPM reports whether one draw lands inside a parts-per-million
// probability. ppm is clamped to [0, 1_000_000] by callers (profiles never
// exceed that range); a draw is always consumed, even for a 0 or 1_000_000
// ppm, so the RNG stream stays aligned between languages regardless of the
// profile's numbers.
func bernoulliPPM(r *rng, ppm uint32) bool {
	return r.uint64()%ppmScale < uint64(ppm)
}

// uniformMicros returns a draw uniformly distributed over [0, rangeMicros],
// always consuming exactly one draw. A zero range still consumes a draw and
// always returns 0, keeping the stream aligned with the range-independent
// call sites in computeFate.
func uniformMicros(r *rng, rangeMicros uint64) uint64 {
	draw := r.uint64()
	if rangeMicros == 0 {
		return 0
	}
	return draw % (rangeMicros + 1)
}
