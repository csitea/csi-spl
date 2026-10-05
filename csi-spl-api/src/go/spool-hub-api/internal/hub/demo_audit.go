package hub

import (
	"context"
	"net/http"
	"strconv"
	"sync/atomic"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Demo post audit (specs/077 FR-011, T025; owner HUM-10, t1 4979bb24: "there
// must be audit of what kind of prompts they have been running"). Every post
// (send or reply, to a channel, a DM or an agent) and every edit a demo_user
// makes is appended to rdb 0131 demo_post_audit with the identity that made
// it, BEFORE the message is stored or delivered. FAIL-CLOSED: a post whose
// audit row cannot be written is refused 503 audit_unavailable and never
// reaches a channel or an agent, so an unaudited demo prompt cannot exist.
// Each failure is one error log line "demo audit write failed" (the log
// metric) carrying the running count, which GET /v1/demo/audit also shows.
//
// Read: GET /v1/demo/audit, owner roles only: the tenant owner (biz_owner)
// of the demo workspace, or an admin of the operator workspace (spec 074),
// each from a session active in that workspace. Every other role, a
// demo_user included, gets 403.

// refusalAuditUnavailable refuses a demo post whose audit row was not written.
const refusalAuditUnavailable = "audit_unavailable"

// permDemoAudit names the grant in a 403 body: a role rule, not a row of
// the permission table.
const permDemoAudit = "demo.audit"

// demoAuditFailures counts failed audit writes since the hub started.
var demoAuditFailures atomic.Int64

// demoAuditPost audits a demo_user's send or reply m in channel ("" = a DM)
// as the (token, status, detail) triple of the hub's checks: "" = go on.
// Anybody but a demo_user in the demo workspace is not audited.
func (s *Server) demoAuditPost(ctx context.Context, tenant, member, channel string, m *msg.Message) (string, int, string) {
	return s.demoAudit(ctx, store.DemoAudit{TenantID: tenant, Action: store.DemoAuditPost, HumanID: member,
		MsgID: m.MsgID, TaskID: m.TaskID, Channel: channel, To: m.To, Body: m.Body})
}

// demoAuditEdit audits a demo_user's edit of e to body.
func (s *Server) demoAuditEdit(ctx context.Context, tenant, member string, e store.EditableMessage, body string) (string, int, string) {
	return s.demoAudit(ctx, store.DemoAudit{TenantID: tenant, Action: store.DemoAuditEdit, HumanID: member,
		MsgID: e.MsgID, TaskID: e.TaskID, Channel: e.Channel, To: e.ToID, Body: body})
}

func (s *Server) demoAudit(ctx context.Context, e store.DemoAudit) (string, int, string) {
	if !s.isDemoVisitor(ctx, e.TenantID, e.HumanID) {
		return "", 0, ""
	}
	da, ok := s.o.Store.(store.DemoAuditor)
	var err error
	if ok {
		e.At = s.o.Now().UTC()
		err = da.AppendDemoAudit(ctx, e)
	}
	if ok && err == nil {
		return "", 0, ""
	}
	n := demoAuditFailures.Add(1)
	s.o.Log.Error().Err(err).Bool("store_audits", ok).Int64("failures", n).Str("tenant", e.TenantID).
		Str("member", e.HumanID).Str("msg_id", e.MsgID).Str("action", e.Action).Msg("demo audit write failed")
	return refusalAuditUnavailable, http.StatusServiceUnavailable, "the demo audit is unavailable: the post was not sent"
}

// demoAuditRow is one row of GET /v1/demo/audit.
type demoAuditRow struct {
	ID        int64  `json:"id"`
	At        string `json:"at"`
	Action    string `json:"action"`
	HumanID   string `json:"human_id"`
	Pseudonym string `json:"pseudonym"`
	Provider  string `json:"provider"`
	Subject   string `json:"subject"`
	Email     string `json:"email"`
	MsgID     string `json:"msg_id"`
	TaskID    string `json:"task_id"`
	Channel   string `json:"channel"`
	To        string `json:"to"`
	Body      string `json:"body"`
}

// GET /v1/demo/audit?limit=<1..500, default 100>&before=<id>: the demo
// workspace's audit, newest first; next_before pages back.
func (s *Server) handleDemoAudit(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if s.o.DemoWorkspace == "" {
		writeErr(w, http.StatusNotFound, "not_found", "the demo is off")
		return
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if !s.demoAuditReader(r.Context(), t.ID, hum) {
		writeForbidden(w, permDemoAudit, "only the demo workspace's owner or an operator admin reads the demo audit")
		return
	}
	da, ok := s.o.Store.(store.DemoAuditor)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no demo audit")
		return
	}
	limit, before := queryInt(r, "limit", 100), int64(queryInt(r, "before", 0))
	rows, err := da.DemoAuditRows(r.Context(), s.o.DemoWorkspace, before, limit)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "the demo audit was not read", err)
		return
	}
	out := make([]demoAuditRow, 0, len(rows))
	for _, e := range rows {
		out = append(out, demoAuditRow{e.ID, rfc(e.At), e.Action, e.HumanID, e.Pseudonym, e.Provider, e.Subject,
			e.Email, e.MsgID, e.TaskID, e.Channel, e.To, e.Body})
	}
	body := map[string]any{"workspace": s.o.DemoWorkspace, "rows": out, "write_failures": demoAuditFailures.Load()}
	if len(rows) > 0 {
		body["next_before"] = rows[len(rows)-1].ID
	}
	writeJSON(w, http.StatusOK, body)
}

// demoAuditReader: hum, active in tenant, is the demo workspace's tenant
// owner or an admin of the operator workspace.
func (s *Server) demoAuditReader(ctx context.Context, tenant, hum string) bool {
	if hum == "" {
		return false
	}
	a, err := s.access(ctx, hum, tenant)
	if err != nil {
		return false
	}
	if tenant == s.o.DemoWorkspace {
		return a.TenantOwner
	}
	op, err := s.operatorTenant(ctx)
	return err == nil && op != "" && tenant == op && a.Role == rbac.Admin
}

// queryInt is the query value key as an int, def when absent or not a number.
func queryInt(r *http.Request, key string, def int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil {
		return def
	}
	return v
}
