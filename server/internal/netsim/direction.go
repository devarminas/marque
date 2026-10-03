package netsim

import "sort"

type Delivery struct {
	Packet []byte
	At     uint64
}

type scheduled struct {
	seq       uint64
	copyIndex uint8
	at        uint64
	packet    []byte
}

type directionSim struct {
	r       *rng
	nextSeq uint64
	pending []scheduled
}

func newDirectionSim(seed uint64) *directionSim {
	return &directionSim{r: newRNG(seed)}
}

func (d *directionSim) send(profile Profile, packet []byte, now uint64) {
	f := computeFate(d.r, profile, now)
	seq := d.nextSeq
	d.nextSeq++

	switch f.kind {
	case fateDropped:
		return
	case fateDeliverOnce:
		d.pending = append(d.pending, scheduled{seq: seq, copyIndex: 0, at: f.at, packet: packet})
	case fateDeliverTwice:
		d.pending = append(d.pending, scheduled{seq: seq, copyIndex: 0, at: f.at, packet: packet})
		d.pending = append(d.pending, scheduled{seq: seq, copyIndex: 1, at: f.at2, packet: packet})
	}
}

func (d *directionSim) poll(now uint64) []Delivery {
	due := d.pending[:0:0]
	rest := d.pending[:0:0]
	for _, s := range d.pending {
		if s.at <= now {
			due = append(due, s)
		} else {
			rest = append(rest, s)
		}
	}
	d.pending = rest

	sort.Slice(due, func(i, j int) bool {
		if due[i].at != due[j].at {
			return due[i].at < due[j].at
		}
		if due[i].seq != due[j].seq {
			return due[i].seq < due[j].seq
		}
		return due[i].copyIndex < due[j].copyIndex
	})

	out := make([]Delivery, len(due))
	for i, s := range due {
		out[i] = Delivery{Packet: s.packet, At: s.at}
	}
	return out
}
