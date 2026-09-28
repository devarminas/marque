package game

import (
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	MaxMana          = 100
	ManaRegenPerTick = 1
)

func (w *World) broadcastMana(p *player) {
	w.broadcast(mnet.Mana{ID: p.id, Mana: p.mana, MaxMana: p.attrs.maxMana()}, nil)
}

func (w *World) spendMana(p *player, amount int) bool {
	if amount < 0 || p.mana < amount {
		return false
	}
	p.mana -= amount
	w.broadcastMana(p)
	w.log.Event(w.tick, EvManaSpend, gamelog.Fields{
		"player": p.id,
		"amount": amount,
		"mana":   p.mana,
	})
	return true
}

func (w *World) refundMana(p *player, amount int) {
	if amount <= 0 {
		return
	}
	p.mana += amount
	if p.mana > p.attrs.maxMana() {
		p.mana = p.attrs.maxMana()
	}
	w.broadcastMana(p)
	w.log.Event(w.tick, EvManaRefund, gamelog.Fields{
		"player": p.id,
		"amount": amount,
		"mana":   p.mana,
	})
}

func (w *World) regenMana() {
	if w.startMana >= 0 {
		return
	}
	for _, p := range w.order {
		if p.dead() || p.mana >= p.attrs.maxMana() {
			continue
		}
		before := p.mana
		p.mana += ManaRegenPerTick
		if p.mana > p.attrs.maxMana() {
			p.mana = p.attrs.maxMana()
		}
		if p.mana == before {
			continue
		}
		w.broadcastMana(p)
	}
}
