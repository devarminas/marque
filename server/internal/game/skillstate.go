package game

import (
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// Tuning: ARM-211 (kill/quest). Gather amount stays in nodes.go as SkillXPGather.
const (
	SkillXPKill  = 20
	SkillXPQuest = 50
)

func (w *World) grantClassSkillXP(p *player, amount int64) {
	if amount <= 0 || w.classes == nil {
		return
	}
	res := classdef.ClassOf(w.wornKinds(p), w.classes)
	if res.Class == nil {
		return
	}
	w.grantSkillXP(p, res.Class.Skill, amount)
}

func (w *World) grantSkillXP(p *player, skill string, amount int64) {
	if skill == "" || amount <= 0 || w.classes == nil {
		return
	}
	if _, ok := w.classes.GetSkill(skill); !ok {
		return
	}
	if p.skillXP == nil {
		p.skillXP = make(map[string]int64)
	}
	xp := p.skillXP[skill] + amount
	p.skillXP[skill] = xp
	w.log.Event(w.tick, EvSkillXP, gamelog.Fields{
		"player": p.id,
		"skill":  skill,
		"xp":     xp,
		"level":  w.classes.LevelFor(skill, xp),
	})
	w.sendSkills(p)
}

func (w *World) classMessage(p *player) mnet.Class {
	value := w.classValue(p)
	out := mnet.Class{Player: p.id, Class: value.ID}
	for _, slot := range value.MissingSlots {
		out.Missing.Slots = append(out.Missing.Slots, mnet.NamedSlot{Slot: slot.Slot, Kind: slot.Kind})
	}
	out.Missing.Tools = value.MissingTools
	return out
}

func (w *World) sendClass(p *player) {
	w.emitOwner(p, w.classValue(p))
	msg := w.classMessage(p)
	w.log.Event(w.tick, EvClass, gamelog.Fields{
		"player": p.id,
		"class":  msg.Class,
	})
	w.send(p, msg)
}

func (w *World) skillsMessage(p *player) mnet.Skills {
	out := mnet.Skills{Player: p.id}
	for _, skill := range w.skillsValue(p).Skills {
		out.Skills = append(out.Skills, mnet.SkillXP{ID: skill.ID, XP: skill.XP, Level: int(skill.Level)})
	}
	return out
}

func (w *World) sendSkills(p *player) {
	if w.classes == nil {
		return
	}
	w.emitOwner(p, w.skillsValue(p))
	w.send(p, w.skillsMessage(p))
}
