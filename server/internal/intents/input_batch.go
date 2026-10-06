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

func AdmitInputBatch(sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, batch []wire.Input) ([]game.Command, error) {
	if len(batch) > MaxInputBatch {
		return nil, ErrInputBatch
	}
	progress, err := sessions.InputCursor(id, epoch)
	if err != nil {
		return nil, err
	}
	eligible := make([]wire.Input, 0, len(batch))
	for _, sample := range batch {
		if sample.Seq() == 0 {
			return nil, eventstream.ErrSequence
		}
		if sample.Seq() == math.MaxUint32 {
			return nil, eventstream.ErrExhausted
		}
		if sample.Seq() > progress.Seq {
			eligible = append(eligible, sample)
		}
	}
	slices.SortFunc(eligible, func(a, b wire.Input) int { return cmp.Compare(a.Seq(), b.Seq()) })
	for i := 1; i < len(eligible); i++ {
		a, b := eligible[i-1], eligible[i]
		if a.Seq() == b.Seq() && (a.Dx() != b.Dx() || a.Dz() != b.Dz() || a.Jump() != b.Jump()) {
			return nil, ErrInputBatch
		}
	}
	commands := make([]game.Command, 0, len(eligible))
	for _, sample := range eligible {
		command, err := AdmitInput(sessions, id, epoch, sample)
		if err != nil {
			return nil, err
		}
		if command != nil {
			commands = append(commands, command)
		}
	}
	return commands, nil
}

func ApplyInputBatch(world *game.World, sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch, batch []wire.Input) error {
	commands, err := AdmitInputBatch(sessions, id, epoch, batch)
	if err != nil {
		return err
	}
	for _, command := range commands {
		c := command.(game.InputCommand)
		if err := world.ApplyInput(c.Player, c.Origin, c.DX, c.DZ, c.Jump); err != nil {
			return err
		}
	}
	return nil
}
