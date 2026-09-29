package netsim

import (
	"encoding/binary"
	"fmt"
	"sort"
)

// goldenSendGapMicros is the fixed spacing between sends when generating a
// golden vector: one send every 1ms of simulated time.
const goldenSendGapMicros = 1000

// GoldenLines runs count packets through a fresh Simulator on the AToB
// direction, seeded and profiled as given, and returns one formatted line
// per packet in send-index order:
//
//	"<index> DROP"
//	"<index> DELIVER <at>"
//	"<index> DUPLICATE <at1> <at2>"
//
// This is the single generator behind the committed golden files under
// shared/wire/vectors/netsim: the Go test compares this output to the
// committed file, and the C++ implementation of the same algorithm is
// expected to reproduce the identical lines byte for byte.
func GoldenLines(profile Profile, seed uint64, count int) []string {
	sim := New(profile, seed)

	for i := 0; i < count; i++ {
		sim.Send(AToB, packetPayload(uint32(i)), uint64(i)*goldenSendGapMicros)
	}

	// Every fate's arrival time is bounded by the last send time plus the
	// slowest possible path through computeFate: base delay, jitter,
	// reorder push, and (for a duplicate) one more jitter draw. Polling
	// once past that bound drains every surviving packet in one call.
	lastSend := uint64(count-1) * goldenSendGapMicros
	maxExtra := profile.DelayBaseMicros + profile.JitterRangeMicros +
		profile.ReorderWindowMicros + profile.JitterRangeMicros
	deliveries := sim.Poll(AToB, lastSend+maxExtra+1)

	type arrival struct {
		at uint64
	}
	arrivalsByIndex := make(map[uint32][]arrival, count)
	for _, d := range deliveries {
		idx := packetIndex(d.Packet)
		arrivalsByIndex[idx] = append(arrivalsByIndex[idx], arrival{at: d.At})
	}

	lines := make([]string, count)
	for i := 0; i < count; i++ {
		idx := uint32(i)
		arrivals := arrivalsByIndex[idx]
		sort.Slice(arrivals, func(a, b int) bool { return arrivals[a].at < arrivals[b].at })

		switch len(arrivals) {
		case 0:
			lines[i] = fmt.Sprintf("%d DROP", idx)
		case 1:
			lines[i] = fmt.Sprintf("%d DELIVER %d", idx, arrivals[0].at)
		case 2:
			lines[i] = fmt.Sprintf("%d DUPLICATE %d %d", idx, arrivals[0].at, arrivals[1].at)
		default:
			panic(fmt.Sprintf("packet %d arrived %d times, computeFate only ever schedules up to 2", idx, len(arrivals)))
		}
	}
	return lines
}

func packetPayload(index uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, index)
	return b
}

func packetIndex(payload []byte) uint32 {
	return binary.BigEndian.Uint32(payload)
}
