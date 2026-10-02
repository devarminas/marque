package netsim

type Profile struct {
	DropPPM             uint32
	DelayBaseMicros     uint64
	JitterRangeMicros   uint64
	DuplicatePPM        uint32
	ReorderPPM          uint32
	ReorderWindowMicros uint64
}

var (
	Clean = Profile{}

	Lossy5Pct = Profile{
		DropPPM:             50_000,
		DelayBaseMicros:     20_000,
		JitterRangeMicros:   10_000,
		DuplicatePPM:        1_000,
		ReorderPPM:          2_000,
		ReorderWindowMicros: 30_000,
	}

	BadWifi = Profile{
		DropPPM:             150_000,
		DelayBaseMicros:     80_000,
		JitterRangeMicros:   60_000,
		DuplicatePPM:        5_000,
		ReorderPPM:          20_000,
		ReorderWindowMicros: 120_000,
	}
)

var Profiles = map[string]Profile{
	"clean":      Clean,
	"lossy_5pct": Lossy5Pct,
	"bad_wifi":   BadWifi,
}
