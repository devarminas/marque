package game

import mnet "github.com/devarminas/marque/server/internal/net"

// combatant shares cast resolve/effects so NPCs do not fork a second path.
type combatant interface {
	combatID() mnet.PlayerID
	combatPos() Point
	combatHP() *int
	combatMaxHP() int
	combatDead() bool
	runtimeCast() *castRuntime
	runtimeSwing() *swingRuntime
}

type castRuntime struct {
	castAbility    string
	castLocomotion string
	castTarget     mnet.PlayerID
	castProgress   int
	castTotal      int
	castCost       int
}

func (c *castRuntime) casting() bool { return c.castAbility != "" }

func (c *castRuntime) clear() {
	*c = castRuntime{}
}

type swingRuntime struct {
	attackTarget   mnet.PlayerID
	attackProgress int
}

func (s *swingRuntime) clear() {
	*s = swingRuntime{}
}

func (p *player) combatID() mnet.PlayerID   { return p.id }
func (p *player) combatPos() Point          { return p.pos }
func (p *player) combatHP() *int            { return &p.hp }
func (p *player) combatMaxHP() int          { return MaxHP }
func (p *player) combatDead() bool          { return p.dead() }
func (p *player) runtimeCast() *castRuntime   { return &p.castRuntime }
func (p *player) runtimeSwing() *swingRuntime { return &p.swingRuntime }

func (n *npc) combatID() mnet.PlayerID   { return n.id }
func (n *npc) combatPos() Point          { return n.pos }
func (n *npc) combatHP() *int            { return &n.hp }
func (n *npc) combatMaxHP() int          { return n.maxHP }
func (n *npc) combatDead() bool          { return n.dead() }
func (n *npc) runtimeCast() *castRuntime   { return &n.castRuntime }
func (n *npc) runtimeSwing() *swingRuntime { return &n.swingRuntime }

func (p *player) casting() bool { return p.castRuntime.casting() }

func (n *npc) casting() bool { return n.castRuntime.casting() }

func playerCombatant(c combatant) *player {
	p, _ := c.(*player)
	return p
}
