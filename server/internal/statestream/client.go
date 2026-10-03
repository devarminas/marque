package statestream

import (
 "errors"
	"maps"
	"math"
	"slices"

	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

type Focus struct {
	Target codec.Opt[wire.EntityId]
	Party  []wire.PlayerId
}

type view struct {
	since uint32
	sent  bool
	acked [numComponents]uint32
	prio  int
}

type pendingFact struct {
	*sharedFact
	acked bool
}

type itemKind uint8

const (
	itemEntity itemKind = iota
	itemGone
	itemFact
 itemMotion
)

type item struct {
	kind  itemKind
	id    wire.EntityId
	parts mask
	fact  *pendingFact
}

type packet struct {
	live  bool
	seq   uint16
	tick  uint32
	items []item
}

const ringSize = 64

type Client struct {
	cfg     Config
	self    wire.PlayerId
	views   map[wire.EntityId]*view
	gone    map[wire.EntityId]uint32
	facts   []*pendingFact
	ring    [ringSize]packet
	draft   packet
	unacked int
}

func NewClient(cfg Config, self wire.PlayerId) (*Client, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &Client{cfg: cfg, self: self, views: map[wire.EntityId]*view{}, gone: map[wire.EntityId]uint32{}}, nil
}

func (c *Client) Build(w *World, focus Focus) transport.Unreliable {
 return c.build(w, focus, nil)
}

var ErrOwnerMotion = errors.New("statestream: owner motion identity, producing tick or budget")

func (c *Client) BuildOwner(w *World, focus Focus, baseline wire.OwnerMotion) (transport.Unreliable, error) {
 if baseline.Player() != c.self || baseline.Tick() != w.tick {
  return transport.Unreliable{}, ErrOwnerMotion
 }
 data, err := baseline.Append(nil)
 if err != nil || itemCost(len(data)) > c.cfg.Budget-sectionHeader {
  return transport.Unreliable{}, ErrOwnerMotion
 }
 return c.build(w, focus, data), nil
}

func (c *Client) build(w *World, focus Focus, ownerMotion []byte) transport.Unreliable {
	tick := w.tick
	if c.unacked >= FullAfter {
		for _, v := range c.views {
			v.acked = [numComponents]uint32{}
		}
		c.unacked = 0
	}
	in := w.interest(c.self)
	for id, v := range c.views {
		if in[id] != nil {
			continue
		}
		if v.sent {
			c.gone[id] = tick
		}
		delete(c.views, id)
	}
	for id := range in {
		if c.views[id] == nil {
			c.views[id] = &view{since: tick}
			delete(c.gone, id)
		}
	}
	outside := func(f *sharedFact) bool {
		return slices.ContainsFunc(f.names, func(id wire.EntityId) bool { return in[id] == nil })
	}
	c.facts = slices.DeleteFunc(c.facts, func(f *pendingFact) bool {
		return f.acked || f.tick+FactTicks <= tick || outside(f.sharedFact)
	})
	for _, f := range w.facts {
		if !outside(f) {
			c.facts = append(c.facts, &pendingFact{sharedFact: f})
		}
	}

	budget := c.cfg.Budget - sectionHeader
	small := budget - maxEntityCost
	used := 0
	c.draft = packet{tick: tick}
	var items [][]byte
	add := func(b []byte, it item) {
		used += itemCost(len(b))
		items = append(items, b)
		c.draft.items = append(c.draft.items, it)
	}
 if ownerMotion != nil {
  add(ownerMotion, item{kind:itemMotion})
 }
	for _, id := range slices.SortedFunc(maps.Keys(c.gone), compareIds) {
		b := must(must(wire.GoneFields{Id: id}.Build()).Append(nil))
		if used+itemCost(len(b)) > small {
			break
		}
		add(b, item{kind: itemGone, id: id})
	}
	for _, f := range c.facts {
		if used+itemCost(len(f.bytes)) > small {
			break
		}
		add(f.bytes, item{kind: itemFact, fact: f})
	}

	type candidate struct {
		id    wire.EntityId
		parts mask
		v     *view
		r     *record
	}
	var due []candidate
	me := in[c.self]
	for id, r := range in {
		v := c.views[id]
		var parts mask
		for comp := range numComponents {
			if r.changed[comp] > v.acked[comp] {
				parts |= 1 << comp
			}
		}
		if parts == 0 {
			continue
		}
		v.prio += c.weight(me, id, r, focus)
		due = append(due, candidate{id, parts, v, r})
	}
	slices.SortFunc(due, func(a, b candidate) int {
		if a.v.prio != b.v.prio {
			return b.v.prio - a.v.prio
		}
		return compareIds(a.id, b.id)
	})
	for _, d := range due {
		b := d.r.encode(d.parts)
		if used+itemCost(len(b)) > budget {
			continue
		}
		add(b, item{kind: itemEntity, id: d.id, parts: d.parts})
	}
	return transport.Unreliable{Stamp: tick, Items: items}
}

func (c *Client) weight(me *record, id wire.EntityId, r *record, focus Focus) int {
	wt := c.cfg.Weights
	reach := float64(c.cfg.Radius+1) * c.cfg.CellSize
	dx := r.entity.transform.X() - me.entity.transform.X()
	dz := r.entity.transform.Z() - me.entity.transform.Z()
	score := wt.Base + int(float64(wt.Near)*max(0, reach-math.Hypot(dx, dz))/reach)
	if t, ok := focus.Target.Get(); ok && t == id {
		score += wt.Target
	}
	if p, ok := id.(wire.PlayerId); ok && (p == c.self || slices.Contains(focus.Party, p)) {
		score += wt.Party
	}
	return score
}

func (c *Client) Sent(f transport.Flushed) {
	p := c.draft
	c.draft = packet{}
	n := min(f.UnreliableSent, len(p.items))
	if n == 0 {
		return
	}
	p.live, p.seq, p.items = true, f.UnreliableSeq, p.items[:n]
	for _, it := range p.items {
		if it.kind == itemEntity {
			v := c.views[it.id]
			v.prio, v.sent = 0, true
		}
	}
	c.ring[p.seq%ringSize] = p
	c.unacked++
}

func (c *Client) Acked(peer transport.AckWindow) (uint32, bool) {
	if peer == transport.NoAcks {
		return 0, false
	}
	p := &c.ring[peer.Latest%ringSize]
	if !p.live || p.seq != peer.Latest {
		return 0, false
	}
	p.live = false
	c.unacked = 0
	for _, it := range p.items {
		switch it.kind {
		case itemEntity:
			v := c.views[it.id]
			if v == nil || p.tick < v.since {
				continue
			}
			for comp := range numComponents {
				if it.parts.has(comp) {
					v.acked[comp] = max(v.acked[comp], p.tick)
				}
			}
		case itemGone:
			if since, ok := c.gone[it.id]; ok && p.tick >= since {
				delete(c.gone, it.id)
			}
		case itemFact:
			it.fact.acked = true
		}
	}
	return p.tick, true
}
