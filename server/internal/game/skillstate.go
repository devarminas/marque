package game

import (
	"sort"

	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func (w *World) classMessage(p *player) mnet.Class {
	out := mnet.Class{Player: p.id}
	if w.classes == nil {
		return out
	}
	res := classdef.ClassOf(w.wornKinds(p), w.classes)
	if res.Class == nil {
		if len(res.Missing) > 0 {
			out.Missing.Slots, out.Missing.Tools = classdef.WireMissing(res.Missing, WornSlots)
		}
		return out
	}
	out.Class = res.Class.ID
	return out
}

func (w *World) sendClass(p *player) {
	msg := w.classMessage(p)
	w.log.Event(w.tick, EvClass, gamelog.Fields{
		"player": p.id,
		"class":  msg.Class,
	})
	w.send(p, msg)
}

func (w *World) skillsMessage(p *player) mnet.Skills {
	out := mnet.Skills{Player: p.id}
	if w.classes == nil {
		return out
	}
	ids := w.classes.SkillIDs()
	sort.Strings(ids)
	for _, id := range ids {
		out.Skills = append(out.Skills, mnet.SkillXP{
			ID:    id,
			XP:    p.skillXP[id],
			Level: w.classes.LevelFor(id, p.skillXP[id]),
		})
	}
	return out
}

func (w *World) sendSkills(p *player) {
	if w.classes == nil {
		return
	}
	w.send(p, w.skillsMessage(p))
}