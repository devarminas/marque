package statestream

import (
	"fmt"
	"math"
	"strings"

	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

const (
	FullAfter = 32
	FactTicks = 8
)

const (
	DefaultCellSize = 32.0
	DefaultRadius   = 2
	DefaultBudget   = 1100
)

var DefaultWeights = Weights{Base: 1, Near: 8, Target: 16, Party: 8}

type Weights struct {
	Base, Near, Target, Party int
}

type Config struct {
	CellSize     float64
	Radius       int
	Budget       int
	SealOverhead int
	Weights      Weights
}

func DefaultConfig() Config {
	return Config{
		CellSize: DefaultCellSize,
		Radius:   DefaultRadius,
		Budget:   DefaultBudget,
		Weights:  DefaultWeights,
	}
}

const sectionHeader = 7

func MaxBudget(sealOverhead int) int {
	return transport.MaxDatagram - transport.HeaderSize - sealOverhead
}

func MinBudget() int { return sectionHeader + maxEntityCost + maxSideCost }

func (c Config) validate() error {
	switch {
	case !(c.CellSize > 0) || math.IsInf(c.CellSize, 0):
		return fmt.Errorf("statestream: CellSize %v is not a positive finite size", c.CellSize)
	case c.Radius < 0:
		return fmt.Errorf("statestream: Radius %d below 0", c.Radius)
	case c.SealOverhead < 0:
		return fmt.Errorf("statestream: SealOverhead %d below 0", c.SealOverhead)
	case c.Budget < MinBudget() || c.Budget > MaxBudget(c.SealOverhead):
		return fmt.Errorf("statestream: Budget %d outside %d to %d", c.Budget, MinBudget(), MaxBudget(c.SealOverhead))
	case c.Weights.Base < 1 || c.Weights.Near < 0 || c.Weights.Target < 0 || c.Weights.Party < 0:
		return fmt.Errorf("statestream: Weights %+v need Base at least 1 and no negative weight", c.Weights)
	}
	return nil
}

func itemCost(n int) int {
	if n < 0x80 {
		return 1 + n
	}
	return 2 + n
}

var maxEntityCost = func() int {
	long := strings.Repeat("x", 32)
	most := codec.Some(long)
	t := must(wire.TransformFields{}.Build())
	v := must(wire.VitalsFields{Hp: math.MaxUint32, MaxHp: math.MaxUint32, Mana: math.MaxUint32, MaxMana: math.MaxUint32}.Build())
	g := must(wire.GearFields{Helmet: most, Chest: most, Trousers: most, Feet: most, LeftHand: most, RightHand: most}.Build())
	casting := must(wire.CastingFields{Ability: long, Start: math.MaxUint32, Ticks: math.MaxUint16}.Build())
	c := must(wire.CastBarFields{Casting: codec.Some(casting)}.Build())
	l := must(wire.LookFields{Kind: long}.Build())
	m := must(wire.EntityFields{
		Id:        wire.PlayerId{Index: math.MaxUint32, Gen: math.MaxUint32},
		Transform: codec.Some(t),
		Vitals:    codec.Some(v),
		Gear:      codec.Some(g),
		Cast:      codec.Some(c),
		Look:      codec.Some(l),
	}.Build())
	return itemCost(len(must(m.Append(nil))))
}()

var maxSideCost = func() int {
	far := wire.PlayerId{Index: math.MaxUint32, Gen: math.MaxUint32}
	gone := must(wire.GoneFields{Id: far}.Build())
	phase := must(wire.CastPhaseFields{
		Tick:    math.MaxUint32,
		Caster:  far,
		Ability: strings.Repeat("x", 32),
		Step:    wire.CastStepResolve,
		Target:  codec.Some[wire.CombatantId](far),
		Amount:  math.MaxUint32,
	}.Build())
	return itemCost(max(len(must(gone.Append(nil))), len(must(phase.Append(nil)))))
}()

func must[T any](v T, err error) T {
	if err != nil {
		panic(fmt.Sprintf("statestream: %v", err))
	}
	return v
}
