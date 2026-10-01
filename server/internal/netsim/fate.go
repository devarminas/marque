package netsim

type fateKind int

const (
	fateDropped fateKind = iota
	fateDeliverOnce
	fateDeliverTwice
)

type fate struct {
	kind fateKind
	at   uint64
	at2  uint64
}

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
