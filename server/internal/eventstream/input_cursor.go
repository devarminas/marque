package eventstream

import "github.com/devarminas/marque/server/internal/game"

type InputProgress struct {
	Player game.PlayerHandle
	Stream StreamID
	Seq    uint32
}

func (ss *Sessions) InputCursor(id SessionID, epoch Epoch) (InputProgress, error) {
	s, err := ss.bound(id, epoch)
	if err != nil {
		return InputProgress{}, err
	}
	return InputProgress{Player: s.player, Stream: s.stream, Seq: s.lastInput}, nil
}
