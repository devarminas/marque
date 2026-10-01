package statestream

import (
	"testing"

	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

const tickMicros uint64 = 40_000

var me = wire.PlayerId{Index: 1, Gen: 0}

func transformAt(x, z float64) wire.Transform {
	return must(wire.TransformFields{X: x, Z: z}.Build())
}

func vitals(hp uint32) wire.Vitals {
	return must(wire.VitalsFields{Hp: hp, MaxHp: 100, Mana: 10, MaxMana: 10}.Build())
}

func idle() wire.CastBar {
	return must(wire.CastBarFields{}.Build())
}

func look(kind string) wire.Look {
	return must(wire.LookFields{Kind: kind}.Build())
}

func player(id wire.PlayerId, x, z float64) Entity {
	g := must(wire.GearFields{RightHand: codec.Some("sword")}.Build())
	return Player(id, transformAt(x, z), vitals(100), g, idle())
}

func npc(index uint32, x, z float64, hp uint32) Entity {
	return Npc(wire.NpcId{Index: index}, transformAt(x, z), vitals(hp), idle(), look("wolf"))
}

type link struct {
	t        testing.TB
	w        *World
	c        *Client
	srv, cli *transport.Endpoint
	now      uint64
	inputSeq uint32
}

func newLink(t testing.TB, cfg Config) *link {
	t.Helper()
	tc := transport.DefaultConfig(wire.SchemaHash)
	return &link{
		t:   t,
		w:   must(NewWorld(cfg)),
		c:   must(NewClient(cfg, me)),
		srv: must(transport.NewEndpoint(transport.Server, tc, 0)),
		cli: must(transport.NewEndpoint(transport.Client, tc, 0)),
	}
}

func (l *link) step(f Frame, focus Focus, deliver bool) []string {
	l.t.Helper()
	l.now += tickMicros
	if err := l.w.Commit(f); err != nil {
		l.t.Fatal(err)
	}
	u := l.c.Build(l.w, focus)
	fl := must(l.srv.Flush(l.now, u))
	l.c.Sent(fl)
	if fl.UnreliableSent != len(u.Items) {
		l.t.Fatalf("tick %d: transport sent %d of %d items", f.Tick, fl.UnreliableSent, len(u.Items))
	}
	if !deliver {
		return texts(u.Items)
	}
	var got []string
	for _, d := range fl.Datagrams {
		r := must(l.cli.Receive(d, l.now))
		got = append(got, texts(r.Unreliable.Items)...)
	}
	return got
}

func (l *link) ack() (uint32, bool) {
	l.t.Helper()
	l.inputSeq++
	in := must(must(wire.InputFields{Seq: l.inputSeq}.Build()).Append(nil))
	fl := must(l.cli.Flush(l.now, transport.Unreliable{Stamp: l.inputSeq, Items: [][]byte{in}}))
	var tick uint32
	var acked bool
	for _, d := range fl.Datagrams {
		r := must(l.srv.Receive(d, l.now))
		if tk, ok := l.c.Acked(r.PeerAck); ok {
			tick, acked = tk, true
		}
	}
	return tick, acked
}

func texts(items [][]byte) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, must(wire.DecodeState(it)).String())
	}
	return out
}
