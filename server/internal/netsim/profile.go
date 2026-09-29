package netsim

// Profile is the set of independent knobs the simulator draws against. All
// probabilities are parts per million (0..1_000_000) and all durations are
// microseconds, so every field is an exact integer with no cross-language
// floating-point drift.
type Profile struct {
	// DropPPM is the chance a packet never arrives.
	DropPPM uint32
	// DelayBaseMicros is added to every surviving packet's arrival time.
	DelayBaseMicros uint64
	// JitterRangeMicros is the width of the uniform delay drawn on top of
	// DelayBaseMicros, and reused as the duplicate's own arrival spread.
	JitterRangeMicros uint64
	// DuplicatePPM is the chance a surviving packet is delivered twice.
	DuplicatePPM uint32
	// ReorderPPM is the chance a surviving packet's arrival is pushed out
	// by an extra draw, letting later-sent packets overtake it.
	ReorderPPM uint32
	// ReorderWindowMicros is the width of that extra uniform push.
	ReorderWindowMicros uint64
}

// Named profiles. Numbers live here once per language; the golden vector
// tests under shared/wire/vectors/netsim are what proves the Go and C++
// numbers are equal, since a mismatch would change the committed fate
// sequence in one language but not the other.
var (
	// Clean never drops, delays, duplicates, or reorders.
	Clean = Profile{}

	// Lossy5Pct models an imperfect but usable connection: 5% loss and
	// modest delay, with duplication and reordering rare.
	Lossy5Pct = Profile{
		DropPPM:             50_000, // 5%
		DelayBaseMicros:     20_000, // 20ms
		JitterRangeMicros:   10_000, // +-10ms
		DuplicatePPM:        1_000,  // 0.1%
		ReorderPPM:          2_000,  // 0.2%
		ReorderWindowMicros: 30_000, // 30ms
	}

	// BadWifi models a congested access point: heavy loss and delay, with
	// duplication and reordering an order of magnitude more common than
	// Lossy5Pct.
	BadWifi = Profile{
		DropPPM:             150_000, // 15%
		DelayBaseMicros:     80_000,  // 80ms
		JitterRangeMicros:   60_000,  // +-60ms
		DuplicatePPM:        5_000,   // 0.5%
		ReorderPPM:          20_000,  // 2%
		ReorderWindowMicros: 120_000, // 120ms
	}
)

// Profiles maps a profile's name (as used in golden filenames and test
// output) to its numbers, so tests can iterate every named profile without
// repeating the list.
var Profiles = map[string]Profile{
	"clean":      Clean,
	"lossy_5pct": Lossy5Pct,
	"bad_wifi":   BadWifi,
}
