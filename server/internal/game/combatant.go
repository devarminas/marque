package game

import mnet "github.com/devarminas/marque/server/internal/net"

// combatant is the shared fighter surface for players and NPCs: pose, HP,
// swing lock, and cast runtime. Cast resolve and effect application drive
// through this type so enemy skills do not fork a second effect path.
type combatant interface {
	combatID() mnet.PlayerID
	combatPos() Point
	combatHP() *int
	combatMaxHP() int
	combatDead() bool
	castState() *castState
	swingState() *swingState
}

type castState struct {
	ability    string
	locomotion string
	target     mnet.PlayerID
	progress   int
	total      int
	cost       int
}

func (c *castState) casting() bool { return c.ability != "" }

func (c *castState) clear() {
	*c = castState{}
}

type swingState struct {
	target   mnet.PlayerID
	progress int
}

func (s *swingState) clear() {
	*s = swingState{}
}
