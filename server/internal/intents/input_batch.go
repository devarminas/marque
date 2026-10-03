package intents

import (
	"cmp"
	"errors"
	"github.com/devarminas/marque/server/internal/eventstream"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/wire"
	"math"
	"slices"
)

const MaxInputBatch = 256

var ErrInputBatch = errors.New("intents: input batch capacity or conflicting newly eligible samples")

func ApplyInputBatch(world *game.World, sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, batch []wire.Input) error {
	if len(batch) > MaxInputBatch {
		return ErrInputBatch
	}
	progress, err := sessions.InputCursor(id, epoch)
	if err != nil {
		return err
	}
	eligible := make([]wire.Input, 0, len(batch))
	for _, sample := range batch {
		if sample.Seq() == 0 {
			return eventstream.ErrSequence
		}
		if sample.Seq() == math.MaxUint32 {
			return eventstream.ErrExhausted
		}
		if sample.Seq() > progress.Seq {
			eligible = append(eligible, sample)
		}
	}
	slices.SortFunc(eligible, func(a, b wire.Input) int { return cmp.Compare(a.Seq(), b.Seq()) })
	for i := 1; i < len(eligible); i++ {
		a, b := eligible[i-1], eligible[i]
		if a.Seq() == b.Seq() && (a.Dx() != b.Dx() || a.Dz() != b.Dz() || a.Jump() != b.Jump()) {
			return ErrInputBatch
		}
	}
	for _, sample := range eligible {
		if err := ApplyInput(world, sessions, id, epoch, sample); err != nil {
			return err
		}
	}
	return nil
}
