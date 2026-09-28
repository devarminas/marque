package game

import (
	"sort"

	mnet "github.com/devarminas/marque/server/internal/net"
)

type cooldowns struct {
	readyAt map[string]int64
}

func (c *cooldowns) ready(ability string, tick int64) bool {
	return c.remaining(ability, tick) == 0
}

func (c *cooldowns) start(ability string, ticks int, tick int64) {
	if ticks <= 0 {
		return
	}
	if c.readyAt == nil {
		c.readyAt = make(map[string]int64)
	}
	c.readyAt[ability] = tick + int64(ticks)
}

func (c *cooldowns) remaining(ability string, tick int64) int {
	readyAt := c.readyAt[ability]
	if readyAt <= tick {
		return 0
	}
	return int(readyAt - tick)
}

func (c *cooldowns) snapshot(tick int64) []mnet.Cooldown {
	out := make([]mnet.Cooldown, 0, len(c.readyAt))
	abilities := make([]string, 0, len(c.readyAt))
	for ability := range c.readyAt {
		abilities = append(abilities, ability)
	}
	sort.Strings(abilities)
	for _, ability := range abilities {
		if remaining := c.remaining(ability, tick); remaining > 0 {
			out = append(out, mnet.Cooldown{Ability: ability, Remaining: remaining})
		}
	}
	return out
}
