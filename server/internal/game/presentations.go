package game

import mnet "github.com/devarminas/marque/server/internal/net"

type PresentationValue interface{ presentationValue() }
type SwingValue struct {
	Attacker, Target CombatantHandle
	Weapon           string
	Amount           int
	Crit, Miss       bool
}

func (SwingValue) presentationValue() {}

type CastPhase uint8

const (
	CastBegin CastPhase = iota + 1
	CastResolve
	CastCancel
)

type CastPhaseValue struct {
	Caster   CombatantHandle
	Ability  string
	Target   CombatantHandle
	Phase    CastPhase
	Amount   int
	Effect   string
	Cooldown int
}

func (CastPhaseValue) presentationValue() {}

type GatherStartValue struct {
	Player PlayerHandle
	Node   NodeHandle
}

func (GatherStartValue) presentationValue() {}

type Presentation struct {
	Tick  uint32
	Value PresentationValue
}

func (w *World) emitPresentation(value PresentationValue) {
	if w.transaction != nil {
		w.transaction.Presentations = append(w.transaction.Presentations, Presentation{w.transaction.Tick, value})
	}
}
func combatantIndex(h CombatantHandle) mnet.PlayerID {
	switch id := h.(type) {
	case PlayerHandle:
		return mnet.PlayerID(id.Index)
	case NPCHandle:
		return mnet.PlayerID(id.Index)
	case nil:
		return 0
	default:
		panic("game: invalid combatant handle")
	}
}
func (w *World) presentSwing(value SwingValue) {
	w.emitPresentation(value)
	w.broadcast(mnet.Swing{ID: combatantIndex(value.Attacker), Target: combatantIndex(value.Target), Weapon: value.Weapon, Amount: value.Amount, Crit: value.Crit, Miss: value.Miss}, nil)
}
func (w *World) presentCast(value CastPhaseValue) {
	w.emitPresentation(value)
	phase := mnet.CastPhaseBegin
	switch value.Phase {
	case CastResolve:
		phase = mnet.CastPhaseResolve
	case CastCancel:
		phase = mnet.CastPhaseCancel
	}
	w.broadcast(mnet.CastPhase{ID: combatantIndex(value.Caster), Target: combatantIndex(value.Target), Ability: value.Ability, Phase: phase, Amount: value.Amount, Effect: value.Effect, Cooldown: value.Cooldown}, nil)
}
func (w *World) presentGather(value GatherStartValue) {
	w.emitPresentation(value)
	w.broadcast(mnet.GatherStarted{ID: mnet.PlayerID(value.Player.Index), Node: mnet.NodeID(value.Node.Index)}, nil)
}
