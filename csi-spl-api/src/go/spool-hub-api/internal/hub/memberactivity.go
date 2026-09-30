package hub

import (
	"context"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// memberActivityAppender records an audit event about a member (rdb 0091,
// CLE-77799). *store.Postgres satisfies it; the memory store does not, so an
// append is a best-effort no-op there.
type memberActivityAppender interface {
	AppendMemberActivity(ctx context.Context, a store.MemberActivity) error
}

// memberActivityLister reads one member's audit trail, newest first.
type memberActivityLister interface {
	ListMemberActivity(ctx context.Context, tenant, subject string) ([]store.MemberActivity, error)
}

// recordMemberActivity appends one audit row, best-effort: a failure is logged
// and swallowed so it never fails the operation it audits (the Activity log is
// a convenience for admins, not a compliance ledger). A store without the
// append (the memory store, an old build) is a silent no-op.
func (s *Server) recordMemberActivity(ctx context.Context, a store.MemberActivity) {
	ap, ok := s.o.Store.(memberActivityAppender)
	if !ok {
		return
	}
	if a.CreatedAt.IsZero() {
		a.CreatedAt = s.o.Now().UTC()
	}
	if err := ap.AppendMemberActivity(ctx, a); err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", a.TenantID).Str("subject", a.SubjectHum).Str("kind", a.Kind).Msg("member_activity append failed")
	}
}

// activityEvent is one row of GET /v1/members/{human_id}/activity. `by` is the
// actor (the admin) for membership events, empty for the member's own auth
// events; `ip` is a /24-masked address on auth rows only.
type activityEvent struct {
	At     string `json:"at"`
	Kind   string `json:"kind"`
	Detail string `json:"detail,omitempty"`
	By     string `json:"by,omitempty"`
	IP     string `json:"ip,omitempty"`
}

// handleMemberActivity is GET /v1/members/{human_id}/activity — one member's
// audit trail (membership + auth events), newest first (CLE-77799, owner topic
// 1fc29f99). Readable by the tenant's admins/owners (audit.read) OR by the
// member themself. The act-as trail is read separately (GET /v1/audit/clones)
// and merged by the WUI.
func (s *Server) handleMemberActivity(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	subject := r.PathValue("human_id")
	if subject != hum && !s.allowed(r.Context(), hum, t.ID, rbac.AuditRead) {
		writeForbidden(w, rbac.AuditRead, "your role in this tenant does not grant "+rbac.AuditRead)
		return
	}
	lister, ok := s.o.Store.(memberActivityLister)
	if !ok {
		writeJSON(w, http.StatusOK, []activityEvent{})
		return
	}
	rows, err := lister.ListMemberActivity(r.Context(), t.ID, subject)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "activity")
		return
	}
	out := make([]activityEvent, 0, len(rows))
	for _, a := range rows {
		out = append(out, activityEvent{At: a.CreatedAt.UTC().Format(time.RFC3339), Kind: a.Kind, Detail: a.Detail, By: a.ActorHum, IP: a.IP})
	}
	writeJSON(w, http.StatusOK, out)
}
