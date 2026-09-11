package game

import (
	"fmt"
	"math"
	mrand "math/rand/v2"

	"github.com/devarminas/marque/server/internal/gamelog"
)

const (
	CampStarterTownImps = "starter_town_imps"

	ImpCampRadius          = 4.0
	ImpCampPoolMax         = 5
	ImpCampDeathTimerTicks = 40
	ImpCampJitterTicks     = 20

	EvNPCDespawned = "npc_despawned"
)

// CampContent is authored camp spawn data. The invisible sphere is an authoring
// metaphor only: center + radius place members; clients never see a sphere mesh.
type CampContent struct {
	ID              string
	Center          Point
	Radius          float64
	Kind            string
	PoolMax         int
	DeathTimerTicks int64
	JitterTicks     int64
}

// StarterTownImpCamp is the single M11 starter-town Imp pool.
var StarterTownImpCamp = CampContent{
	ID:              CampStarterTownImps,
	Center:          Point{X: ImpCampX, Z: ImpCampZ},
	Radius:          ImpCampRadius,
	Kind:            KindImp,
	PoolMax:         ImpCampPoolMax,
	DeathTimerTicks: ImpCampDeathTimerTicks,
	JitterTicks:     ImpCampJitterTicks,
}

type camp struct {
	content CampContent
	pending []int64
}

func (w *World) SeedImpCamp() error {
	return w.seedCamp(StarterTownImpCamp)
}

func (w *World) seedCamp(content CampContent) error {
	if err := validateCampContent(content); err != nil {
		return err
	}
	c := &camp{content: content}
	w.camps = append(w.camps, c)
	for range content.PoolMax {
		if err := w.spawnCampMember(c); err != nil {
			return err
		}
	}
	return nil
}

func validateCampContent(c CampContent) error {
	if c.ID == "" {
		return fmt.Errorf("seed camp: id must not be empty")
	}
	if c.Kind == "" {
		return fmt.Errorf("seed camp %q: kind must not be empty", c.ID)
	}
	if c.PoolMax < 1 {
		return fmt.Errorf("seed camp %q: pool max %d must be >= 1", c.ID, c.PoolMax)
	}
	if c.Radius < 0 {
		return fmt.Errorf("seed camp %q: radius %v must be >= 0", c.ID, c.Radius)
	}
	if c.DeathTimerTicks < 0 {
		return fmt.Errorf("seed camp %q: death timer %d must be >= 0", c.ID, c.DeathTimerTicks)
	}
	if c.JitterTicks < 0 {
		return fmt.Errorf("seed camp %q: jitter %d must be >= 0", c.ID, c.JitterTicks)
	}
	if reason, detail := (&World{mapCfg: VillageMap}).checkCoordinates(c.Center.X, c.Center.Z); reason != "" {
		return fmt.Errorf("seed camp %q at (%v, %v): %s", c.ID, c.Center.X, c.Center.Z, detail)
	}
	return nil
}

func (w *World) spawnCampMember(c *camp) error {
	if w.campLiveCount(c) >= c.content.PoolMax {
		return nil
	}
	pos := w.pointInCamp(c.content)
	if c.content.Kind != KindImp {
		return fmt.Errorf("seed camp %q: unsupported kind %q", c.content.ID, c.content.Kind)
	}
	if err := w.seedNPCAt(c.content.Kind, FactionHostile, pos.X, pos.Z, ImpMaxHP, c.content.ID); err != nil {
		return err
	}
	n := w.npcs[w.npcOrder[len(w.npcOrder)-1]]
	n.home = pos
	return nil
}

func (w *World) pointInCamp(c CampContent) Point {
	if c.Radius == 0 {
		return c.Center
	}
	r := c.Radius * math.Sqrt(w.float64())
	theta := w.float64() * 2 * math.Pi
	return Point{
		X: c.Center.X + r*math.Cos(theta),
		Z: c.Center.Z + r*math.Sin(theta),
	}
}

func (w *World) campLiveCount(c *camp) int {
	n := 0
	for _, id := range w.npcOrder {
		npc := w.npcs[id]
		if npc != nil && npc.camp == c.content.ID && !npc.dead() {
			n++
		}
	}
	return n
}

func (w *World) campByID(id string) *camp {
	if id == "" {
		return nil
	}
	for _, c := range w.camps {
		if c.content.ID == id {
			return c
		}
	}
	return nil
}

func (w *World) scheduleCampRespawn(c *camp) {
	delay := c.content.DeathTimerTicks
	if c.content.JitterTicks > 0 {
		delay += int64(w.intN(int(c.content.JitterTicks) + 1))
	}
	due := w.tick + delay
	i := len(c.pending)
	for i > 0 && c.pending[i-1] > due {
		i--
	}
	c.pending = append(c.pending, 0)
	copy(c.pending[i+1:], c.pending[i:])
	c.pending[i] = due
}

func (w *World) respawnCamps() {
	for _, c := range w.camps {
		for len(c.pending) > 0 {
			if c.pending[0] > w.tick {
				break
			}
			if w.campLiveCount(c) >= c.content.PoolMax {
				break
			}
			c.pending = c.pending[1:]
			if err := w.spawnCampMember(c); err != nil {
				panic(fmt.Sprintf("game: camp %q respawn: %v", c.content.ID, err))
			}
		}
	}
}

func (w *World) float64() float64 {
	if w.rng != nil {
		return w.rng.Float64()
	}
	return mrand.Float64()
}

func (w *World) intN(n int) int {
	if n <= 0 {
		return 0
	}
	if w.rng != nil {
		return w.rng.IntN(n)
	}
	return mrand.IntN(n)
}

func (w *World) noteCampDespawn(n *npc) {
	if n.camp == "" {
		return
	}
	w.log.Event(w.tick, EvNPCDespawned, gamelog.Fields{
		"npc":  n.id,
		"kind": n.kind,
		"camp": n.camp,
		"x":    n.pos.X,
		"z":    n.pos.Z,
	})
	if c := w.campByID(n.camp); c != nil {
		w.scheduleCampRespawn(c)
	}
}
