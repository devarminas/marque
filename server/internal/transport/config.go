package transport

import "fmt"

// Defaults for the local, unmeasured knobs. ARM-362 measures them.
const (
	DefaultTickBudget          = 4800
	DefaultBacklogLimit        = 1024
	DefaultResendAfter  uint64 = 200_000
)

// Config holds what one side chooses for itself. Nothing here has to match
// the peer except SchemaHash and the Seal.
type Config struct {
	// SchemaHash goes in every header; a datagram carrying another hash is
	// refused. Production passes wire.SchemaHash.
	SchemaHash uint64
	// TickBudget caps the bytes one Flush emits, keepalives aside.
	TickBudget int
	// BacklogLimit is how many reliable messages may be queued and not yet
	// acknowledged. One more closes the connection as SlowClient.
	BacklogLimit int
	// ResendAfter is how long an unacknowledged fragment waits, in
	// microseconds, before it is due again.
	ResendAfter uint64
	Seal        Seal
}

func DefaultConfig(schemaHash uint64) Config {
	return Config{
		SchemaHash:   schemaHash,
		TickBudget:   DefaultTickBudget,
		BacklogLimit: DefaultBacklogLimit,
		ResendAfter:  DefaultResendAfter,
		Seal:         Plain{},
	}
}

func (c Config) validate() error {
	switch {
	case c.TickBudget < MaxDatagram:
		return fmt.Errorf("transport: TickBudget %d below MaxDatagram", c.TickBudget)
	case c.BacklogLimit < 1:
		return fmt.Errorf("transport: BacklogLimit %d below 1", c.BacklogLimit)
	case c.ResendAfter == 0:
		return fmt.Errorf("transport: ResendAfter is zero")
	case c.Seal == nil:
		return fmt.Errorf("transport: Seal is nil")
	}
	return nil
}
