package game

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func NewDefaultAdminRegistry() *AdminRegistry {
	r := NewAdminRegistry()
	RegisterDefaultAdminCommands(r)
	return r
}

func RegisterDefaultAdminCommands(r *AdminRegistry) {
	r.Register("give", adminGive)
	r.Register("tp", adminTP)
	r.Register("spawn", adminSpawn)
	r.Register("heal", adminHeal)
}

func adminGive(w *World, p *player, args []string) (string, *mnet.RejectError) {
	if len(args) < 1 || len(args) > 3 {
		return "", adminUsage("/give <item_id> [qty] [player]")
	}
	kind := strings.TrimSpace(args[0])
	if kind == "" {
		return "", adminUsage("/give <item_id> [qty] [player]")
	}
	if !w.items.KnownItemKind(kind) {
		return "", adminFail(mnet.ReasonUnknownItem, fmt.Sprintf("unknown kind %q", kind))
	}
	qty := 1
	target := p
	switch len(args) {
	case 2:
		n, err := strconv.Atoi(args[1])
		if err != nil || n < 1 {
			return "", adminUsage("/give <item_id> [qty] [player]")
		}
		qty = n
	case 3:
		n, err := strconv.Atoi(args[1])
		if err != nil || n < 1 {
			return "", adminUsage("/give <item_id> [qty] [player]")
		}
		qty = n
		var rerr *mnet.RejectError
		target, rerr = w.adminPlayer(args[2])
		if rerr != nil {
			return "", rerr
		}
	}
	kinds := make([]string, qty)
	for i := range kinds {
		kinds[i] = kind
	}
	if err := w.items.GrantInventoryKinds(target.id, kinds); err != nil {
		if errors.Is(err, ErrInventoryFull) {
			return "", adminFail(mnet.ReasonInventoryFull, "inventory full")
		}
		return "", adminFail(mnet.ReasonProtocolError, "give failed")
	}
	w.sendInventory(target)
	if target.id == p.id {
		return fmt.Sprintf("gave %d %s", qty, kind), nil
	}
	return fmt.Sprintf("gave %d %s to %d", qty, kind, target.id), nil
}

func adminTP(w *World, p *player, args []string) (string, *mnet.RejectError) {
	switch len(args) {
	case 1:
		target, rerr := w.adminPlayer(args[0])
		if rerr != nil {
			return "", rerr
		}
		w.adminCopyPose(p, target)
		return fmt.Sprintf("teleported to %d", target.id), nil
	case 2:
		x, errX := strconv.ParseFloat(args[0], 64)
		z, errZ := strconv.ParseFloat(args[1], 64)
		if errX != nil || errZ != nil {
			return "", adminUsage("/tp <x> <z> | /tp <player>")
		}
		if reason, detail := w.checkCoordinates(x, z); reason != "" {
			return "", adminFail(reason, detail)
		}
		w.adminSetPose(p, x, z)
		return fmt.Sprintf("teleported to %.3f %.3f", x, z), nil
	default:
		return "", adminUsage("/tp <x> <z> | /tp <player>")
	}
}

func adminSpawn(w *World, p *player, args []string) (string, *mnet.RejectError) {
	if len(args) != 1 && len(args) != 3 {
		return "", adminUsage("/spawn <npc_kind> [x z]")
	}
	kind := strings.ToLower(strings.TrimSpace(args[0]))
	faction, maxHP, ok := adminNPCArchetype(kind)
	if !ok {
		return "", adminUsage(fmt.Sprintf("unknown npc_kind %q", kind))
	}
	x, z := p.pos.X+1, p.pos.Z
	if len(args) == 3 {
		var errX, errZ error
		x, errX = strconv.ParseFloat(args[1], 64)
		z, errZ = strconv.ParseFloat(args[2], 64)
		if errX != nil || errZ != nil {
			return "", adminUsage("/spawn <npc_kind> [x z]")
		}
	}
	if err := w.seedNPCAt(kind, faction, x, z, maxHP, ""); err != nil {
		if reason, detail := w.checkCoordinates(x, z); reason != "" {
			return "", adminFail(reason, detail)
		}
		return "", adminFail(mnet.ReasonProtocolError, err.Error())
	}
	return fmt.Sprintf("spawned %s at %.3f %.3f", kind, x, z), nil
}

func adminHeal(w *World, p *player, args []string) (string, *mnet.RejectError) {
	if len(args) > 1 {
		return "", adminUsage("/heal [player]")
	}
	target := p
	if len(args) == 1 {
		var rerr *mnet.RejectError
		target, rerr = w.adminPlayer(args[0])
		if rerr != nil {
			return "", rerr
		}
	}
	target.hp = MaxHP
	target.mana = MaxMana
	w.broadcastHP(target)
	w.broadcastMana(target)
	if target.id == p.id {
		return "healed", nil
	}
	return fmt.Sprintf("healed %d", target.id), nil
}

func (w *World) adminSetPose(p *player, x, z float64) {
	p.clearSteer()
	p.pos = Point{X: x, Z: z}
	p.y = w.groundYAt(x, z, p.y)
	p.vy = 0
	w.broadcastPose(p)
}

func (w *World) adminCopyPose(dst, src *player) {
	dst.clearSteer()
	dst.pos = src.pos
	dst.y = src.y
	dst.vy = 0
	w.broadcastPose(dst)
}

func (w *World) adminPlayer(raw string) (*player, *mnet.RejectError) {
	id, err := strconv.ParseUint(raw, 10, 32)
	if err != nil || id == 0 {
		return nil, adminUsage("player must be a positive id")
	}
	target, ok := w.players[mnet.PlayerID(id)]
	if !ok {
		return nil, adminFail(mnet.ReasonUnknownPlayer, fmt.Sprintf("no such player %d", id))
	}
	return target, nil
}

func adminNPCArchetype(kind string) (faction string, maxHP int, ok bool) {
	switch kind {
	case KindDummy:
		return FactionHostile, DummyMaxHP, true
	case KindImp:
		return FactionHostile, ImpMaxHP, true
	case KindQuestGiver, KindImpQuestGiver:
		return FactionNeutral, MaxHP, true
	default:
		return "", 0, false
	}
}

func adminUsage(detail string) *mnet.RejectError {
	return &mnet.RejectError{
		Reason:      mnet.ReasonUsage,
		Detail:      detail,
		Re:          mnet.MsgAdmin,
		Disposition: mnet.ReplyError,
	}
}

func adminFail(reason mnet.RejectReason, detail string) *mnet.RejectError {
	return &mnet.RejectError{
		Reason:      reason,
		Detail:      detail,
		Re:          mnet.MsgAdmin,
		Disposition: mnet.ReplyError,
	}
}
