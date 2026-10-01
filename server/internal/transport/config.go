package transport

import "fmt"

const (
	DefaultTickBudget          = 4800
	DefaultBacklogLimit        = 1024
	DefaultBacklogBytes        = 4 * MaxMessage
	MaxBacklogLimit            = 65536 - WindowMessages
	DefaultResendAfter  uint64 = 200_000
)

type Config struct {
	SchemaHash uint64
	TickBudget int
	BacklogLimit int
	BacklogBytes int
	ResendAfter uint64
}

func DefaultConfig(schemaHash uint64) Config {
	return Config{
		SchemaHash:   schemaHash,
		TickBudget:   DefaultTickBudget,
		BacklogLimit: DefaultBacklogLimit,
		BacklogBytes: DefaultBacklogBytes,
		ResendAfter:  DefaultResendAfter,
	}
}

func (c Config) validate() error {
	switch {
	case c.TickBudget < MaxDatagram:
		return fmt.Errorf("transport: TickBudget %d below MaxDatagram", c.TickBudget)
	case c.BacklogLimit < 1 || c.BacklogLimit > MaxBacklogLimit:
		return fmt.Errorf("transport: BacklogLimit %d outside 1 to %d", c.BacklogLimit, MaxBacklogLimit)
	case c.BacklogBytes < 1:
		return fmt.Errorf("transport: BacklogBytes %d below 1", c.BacklogBytes)
	case c.ResendAfter == 0:
		return fmt.Errorf("transport: ResendAfter is zero")
	}
	return nil
}
