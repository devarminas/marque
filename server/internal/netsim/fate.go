package netsim

// fateKind is a packet's outcome, modeled as a sum type rather than a
// dropped/duplicated pair of booleans: a dropped packet has no arrival
// time, and a once-delivered packet has no second arrival time, so the
// struct only ever carries the fields its kind defines.
type fateKind int

const (
	fateDropped fateKind = iota
	fateDeliverOnce
	fateDeliverTwice
)

type fate struct {
	kind fateKind
	at   uint64 // valid for fateDeliverOnce and fateDeliverTwice
	at2  uint64 // valid for fateDeliverTwice only
}

// computeFate is the one place that decides what happens to a packet sent
// at now. It draws from r in a fixed order that the C++ implementation
// mirrors exactly:
//
//  1. drop roll                               (always drawn)
//  2. jitter roll                              (only if not dropped)
//  3. reorder roll                             (only if not dropped)
//  4. reorder-extra roll                       (only if reordered)
//  5. duplicate roll                           (only if not dropped)
//  6. duplicate-jitter roll                    (only if duplicated)
//
// Keeping this order identical in both languages is what makes the same
// seed and profile produce the same fate sequence in Go and C++: every
// branch below consumes the same number of draws as its C++ counterpart
// for the same profile and outcome.
func computeFate(r *rng, p Profile, now uint64) fate {
	if bernoulliPPM(r, p.DropPPM) {
		return fate{kind: fateDropped}
	}

	jitter := uniformMicros(r, p.JitterRangeMicros)
	at := now + p.DelayBaseMicros + jitter

	if bernoulliPPM(r, p.ReorderPPM) {
		at += uniformMicros(r, p.ReorderWindowMicros)
	}

	if bernoulliPPM(r, p.DuplicatePPM) {
		at2 := at + uniformMicros(r, p.JitterRangeMicros)
		return fate{kind: fateDeliverTwice, at: at, at2: at2}
	}

	return fate{kind: fateDeliverOnce, at: at}
}
