package intents

import (
	"errors"
	"github.com/devarminas/marque/server/internal/eventstream"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/wire"
	"math"
)

var ErrMotionBaseline = errors.New("intents: invalid owner motion baseline")

func ValidateOwnerMotion(m wire.OwnerMotion) error {
	values := []float32{m.X(), m.Y(), m.Z(), m.Vy(), m.Dx(), m.Dz(), m.HalfExtent(), m.GroundY()}
	for _, v := range values {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
			return ErrMotionBaseline
		}
	}
	he := m.HalfExtent()
	if m.Stream() == 0 || m.Epoch() == 0 || m.Player().Index == 0 || m.Player().Gen == 0 || m.MapId() == "" || he <= 0 || he > 4096 || math.Abs(float64(m.X())) > float64(he) || math.Abs(float64(m.Z())) > float64(he) || math.Abs(float64(m.Y())) > 4096 || math.Abs(float64(m.GroundY())) > 4096 || math.Abs(float64(m.Vy())) > 4096 || math.Hypot(float64(m.Dx()), float64(m.Dz())) > 1.0000002 {
		return ErrMotionBaseline
	}
	if m.CastEnd() != 0 && m.CastEnd() < m.Tick() {
		return ErrMotionBaseline
	}
	if m.Mode() != wire.MotionModeFree && m.CastEnd() <= m.Tick() {
		return ErrMotionBaseline
	}
	return nil
}
func OwnerMotion(world *game.World, sessions *eventstream.Sessions, id eventstream.SessionID, epoch eventstream.Epoch) (wire.OwnerMotion, error) {
	progress, err := sessions.InputCursor(id, epoch)
	if err != nil {
		return wire.OwnerMotion{}, err
	}
	snap, err := world.OwnerMotion(progress.Player)
	if err != nil {
		return wire.OwnerMotion{}, err
	}
	return encodeOwnerMotion(snap, uint64(progress.Stream), epoch, progress.Seq)
}
func OwnerMotionFromFrame(frame game.StateFrame, player game.PlayerHandle, stream eventstream.StreamID, epoch eventstream.Epoch) (wire.OwnerMotion, error) {
	for _, snap := range frame.OwnerMotion {
		if snap.Player == player && snap.Tick == frame.Tick {
			return encodeOwnerMotion(snap, uint64(stream), epoch, snap.InputSeq)
		}
	}
	return wire.OwnerMotion{}, game.ErrOwner
}
func encodeOwnerMotion(snap game.MotionSnapshot, stream uint64, epoch eventstream.Epoch, inputSeq uint32) (wire.OwnerMotion, error) {
	s := snap.State
	m, err := (wire.OwnerMotionFields{Stream: stream, Epoch: uint64(epoch), Player: wire.PlayerId{Index: snap.Player.Index, Gen: snap.Player.Gen}, Tick: snap.Tick, InputSeq: inputSeq, X: float32(s.X), Y: float32(s.Y), Z: float32(s.Z), Vy: float32(s.VY), Dx: float32(s.DX), Dz: float32(s.DZ), Grounded: snap.Grounded, Mode: wire.MotionMode(snap.Policy.Mode + 1), CastEnd: snap.Policy.EndTick, MapId: snap.MapID, MapRevision: snap.MapRevision, HalfExtent: float32(snap.HalfExtent), GroundY: float32(snap.GroundY), TickIntervalUs: snap.TickIntervalUS}).Build()
	if err != nil {
		return wire.OwnerMotion{}, err
	}
	if err = ValidateOwnerMotion(m); err != nil {
		return wire.OwnerMotion{}, err
	}
	return m, nil
}
