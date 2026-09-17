package game

import "github.com/devarminas/marque/server/internal/npcdef"

const (
	AttrBaseline = 10
	HPPerCON     = 10
	ManaPerINT   = 10
)

// attributes are the thin primary stats. Derived values:
//
//	MaxHP     = 10 * CON          (min 1)
//	MaxMana   = 10 * INT          (min 0)
//	AP        = (STR - 10) / 2    (integer; may be negative)
//	SP        = (INT - 10) / 2    (integer; may be negative)
//	Armor     = max(0, (DEX - 10) / 2)  subtracted from whites; hit floor 1
//	CritChance = max(0, DEX - 10)       percent chance to double a white before armor
type attributes struct {
	STR int
	DEX int
	CON int
	INT int
}

func defaultPlayerAttrs() attributes {
	return attributes{STR: AttrBaseline, DEX: AttrBaseline, CON: AttrBaseline, INT: AttrBaseline}
}

func attrsFromArchetype(a npcdef.Archetype) attributes {
	return attributes{STR: a.STR, DEX: a.DEX, CON: a.CON, INT: a.INT}
}

func (a attributes) maxHP() int {
	if a.CON < 1 {
		return 1
	}
	return HPPerCON * a.CON
}

func (a attributes) maxMana() int {
	if a.INT < 0 {
		return 0
	}
	return ManaPerINT * a.INT
}

func (a attributes) AP() int { return (a.STR - AttrBaseline) / 2 }

func (a attributes) SP() int { return (a.INT - AttrBaseline) / 2 }

func (a attributes) Armor() int {
	v := (a.DEX - AttrBaseline) / 2
	if v < 0 {
		return 0
	}
	return v
}

func (a attributes) CritChance() int {
	v := a.DEX - AttrBaseline
	if v < 0 {
		return 0
	}
	return v
}
