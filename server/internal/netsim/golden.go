package netsim

import (
	"encoding/binary"
	"fmt"
	"sort"
)

const goldenSendGapMicros = 1000

func GoldenLines(profile Profile, seed uint64, count int) []string {
	sim := New(profile, seed)

	for i := 0; i < count; i++ {
		sim.Send(AToB, packetPayload(uint32(i)), uint64(i)*goldenSendGapMicros)
	}

	lastSend := uint64(count-1) * goldenSendGapMicros
	slowestPossiblePathThroughComputeFate := profile.DelayBaseMicros + profile.JitterRangeMicros +
		profile.ReorderWindowMicros + profile.JitterRangeMicros
	deliveries := sim.Poll(AToB, lastSend+slowestPossiblePathThroughComputeFate+1)

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
