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
	w.broadcast(mnet.Mana{ID: p.id, Mana: p.mana, MaxMana: MaxMana}, nil)
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
	if p.mana > MaxMana {
		p.mana = MaxMana
	}
	w.broadcastMana(p)
	w.log.Event(w.tick, EvManaRefund, gamelog.Fields{
		"player": p.id,
		"amount": amount,
		"mana":   p.mana,
	})
}

func (w *World) regenMana() {
	for _, p := range w.order {
		if p.dead() || p.mana >= MaxMana {
			continue
		}
		before := p.mana
		p.mana += ManaRegenPerTick
		if p.mana > MaxMana {
			p.mana = MaxMana
		}
		if p.mana == before {
			continue
		}
		w.broadcastMana(p)
	}
}
