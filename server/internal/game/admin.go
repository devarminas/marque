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

	adminPrefixOK    = "ok: "
	adminPrefixDeny  = "deny: "
	adminPrefixUsage = "usage: "
	adminPrefixError = "error: "

	adminResultOK    = "ok"
	adminResultDeny  = "deny"
	adminResultError = "error"
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
			Detail:      "/<command> [args...]",
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
			Detail:      "/<command> [args...]",
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
	if parseErr != nil {
		w.refuseAdmin(p, parseErr, adminPrefixUsage+parseErr.Detail)
		w.auditAdmin(p, name, args, seq, parseErr)
		return
	}
	if !w.adminACL.Allowed(p.id) {
		rej := &mnet.RejectError{
			Reason:      mnet.ReasonUnauthorized,
			Detail:      "unauthorized",
			Re:          mnet.MsgAdmin,
			Disposition: mnet.ReplyError,
		}
		w.refuseAdmin(p, rej, adminPrefixDeny+"unauthorized")
		w.auditAdmin(p, name, args, seq, rej)
		return
	}
	h, ok := w.adminCmds.Lookup(name)
	if !ok {
		detail := fmt.Sprintf("unknown command %q", name)
		rej := &mnet.RejectError{
			Reason:      mnet.ReasonUsage,
			Detail:      detail,
			Re:          mnet.MsgAdmin,
			Disposition: mnet.ReplyError,
		}
		w.refuseAdmin(p, rej, adminPrefixUsage+detail)
		w.auditAdmin(p, name, args, seq, rej)
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
		w.refuseAdmin(p, herr, formatAdminHandlerError(herr))
		w.auditAdmin(p, name, args, seq, herr)
		return
	}
	w.auditAdmin(p, name, args, seq, nil)
	if reply != "" {
		w.sendAdminReply(p, adminPrefixOK+reply)
	}
}

func (w *World) auditAdmin(p *player, cmd string, args []string, seq mnet.Seq, rejection *mnet.RejectError) {
	if args == nil {
		args = []string{}
	}
	fields := gamelog.Fields{
		"player": p.id,
		"cmd":    cmd,
		"args":   args,
		"result": adminAuditResult(rejection),
	}
	if rejection != nil {
		fields["reason"] = string(rejection.Reason)
		if rejection.Detail != "" {
			fields["detail"] = rejection.Detail
		}
	}
	w.log.Event(w.tick, EvAdmin, withSeq(fields, seq))
}

func adminAuditResult(rejection *mnet.RejectError) string {
	if rejection == nil {
		return adminResultOK
	}
	if rejection.Reason == mnet.ReasonUnauthorized {
		return adminResultDeny
	}
	return adminResultError
}

func (w *World) refuseAdmin(p *player, rejection *mnet.RejectError, replyText string) {
	if rejection.Disposition == mnet.Ignore {
		fields := gamelog.Fields{
			"player": p.id,
			"reason": string(rejection.Reason),
			"detail": rejection.Detail,
		}
		if rejection.Re != "" {
			fields["re"] = rejection.Re
		}
		w.log.Event(w.tick, EvIntentIgnored, fields)
		return
	}
	w.sendAdminReply(p, replyText)
	if rejection.Disposition == mnet.ReplyErrorAndClose {
		p.conn.CloseAfterFlush(mnet.DisconnectProtocol)
	}
}

func (w *World) sendAdminReply(p *player, text string) {
	w.send(p, mnet.AdminReply{Text: text})
}

func formatAdminHandlerError(err *mnet.RejectError) string {
	detail := strings.TrimSpace(err.Detail)
	detail = strings.TrimPrefix(detail, adminPrefixOK)
	detail = strings.TrimPrefix(detail, adminPrefixDeny)
	detail = strings.TrimPrefix(detail, adminPrefixUsage)
	detail = strings.TrimPrefix(detail, adminPrefixError)
	detail = strings.TrimSpace(detail)
	switch err.Reason {
	case mnet.ReasonUnauthorized:
		if detail == "" {
			detail = "unauthorized"
		}
		return adminPrefixDeny + detail
	case mnet.ReasonUsage:
		if detail == "" {
			detail = "/<command> [args...]"
		}
		return adminPrefixUsage + detail
	default:
		if detail == "" {
			detail = "command failed"
		}
		return adminPrefixError + detail
	}
}
