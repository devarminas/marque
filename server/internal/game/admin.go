package game

import (
	"fmt"
	"strings"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	EvAdmin         = "admin"
	EvAdminRejected = "admin_rejected"
)

type AdminACL struct {
	DevAdmin bool
	Players  map[mnet.PlayerID]struct{}
}

func (a AdminACL) Allowed(id mnet.PlayerID) bool {
	if a.DevAdmin {
		return true
	}
	if a.Players == nil {
		return false
	}
	_, ok := a.Players[id]
	return ok
}

// AdminHandler runs on the world goroutine after ACL and parse succeed.
type AdminHandler func(w *World, p *player, args []string) (reply string, err *mnet.RejectError)

type AdminRegistry struct {
	cmds map[string]AdminHandler
}

func NewAdminRegistry() *AdminRegistry {
	return &AdminRegistry{cmds: make(map[string]AdminHandler)}
}

func (r *AdminRegistry) Register(name string, h AdminHandler) {
	if r == nil {
		panic("game: Register on nil AdminRegistry")
	}
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		panic("game: admin command name is empty")
	}
	if h == nil {
		panic(fmt.Sprintf("game: nil handler for admin command %q", name))
	}
	if _, exists := r.cmds[name]; exists {
		panic(fmt.Sprintf("game: duplicate admin command %q", name))
	}
	r.cmds[name] = h
}

func (r *AdminRegistry) Lookup(name string) (AdminHandler, bool) {
	if r == nil {
		return nil, false
	}
	h, ok := r.cmds[strings.ToLower(name)]
	return h, ok
}

func ParseAdminLine(line string) (name string, args []string, err *mnet.RejectError) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return "", nil, &mnet.RejectError{
			Reason:      mnet.ReasonUsage,
			Detail:      "usage: /<command> [args...]",
			Re:          mnet.MsgAdmin,
			Disposition: mnet.ReplyError,
		}
	}
	if strings.HasPrefix(trimmed, "/") {
		trimmed = strings.TrimSpace(trimmed[1:])
	}
	if trimmed == "" {
		return "", nil, &mnet.RejectError{
			Reason:      mnet.ReasonUsage,
			Detail:      "usage: /<command> [args...]",
			Re:          mnet.MsgAdmin,
			Disposition: mnet.ReplyError,
		}
	}
	fields := strings.Fields(trimmed)
	return strings.ToLower(fields[0]), fields[1:], nil
}

func (w *World) SetAdminACL(acl AdminACL) {
	w.adminACL = acl
}

func (w *World) SetAdminRegistry(r *AdminRegistry) {
	w.adminCmds = r
}

func (w *World) admin(p *player, msg mnet.Admin, seq mnet.Seq) {
	name, args, parseErr := ParseAdminLine(msg.Line)
	fields := gamelog.Fields{
		"player": p.id,
		"line":   msg.Line,
	}
	if name != "" {
		fields["cmd"] = name
	}
	w.log.Event(w.tick, EvAdmin, withSeq(fields, seq))

	if parseErr != nil {
		w.refuse(p, parseErr)
		return
	}
	if !w.adminACL.Allowed(p.id) {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUnauthorized,
			Detail:      "admin: unauthorized",
			Re:          mnet.MsgAdmin,
			Disposition: mnet.ReplyError,
		})
		return
	}
	h, ok := w.adminCmds.Lookup(name)
	if !ok {
		w.refuse(p, &mnet.RejectError{
			Reason:      mnet.ReasonUsage,
			Detail:      fmt.Sprintf("usage: unknown command %q", name),
			Re:          mnet.MsgAdmin,
			Disposition: mnet.ReplyError,
		})
		return
	}
	reply, herr := h(w, p, args)
	if herr != nil {
		if herr.Re == "" {
			herr.Re = mnet.MsgAdmin
		}
		if herr.Disposition != mnet.ReplyErrorAndClose {
			herr.Disposition = mnet.ReplyError
		}
		w.refuse(p, herr)
		return
	}
	if reply != "" {
		w.send(p, mnet.Error{Re: mnet.MsgAdmin, Msg: reply})
	}
}
