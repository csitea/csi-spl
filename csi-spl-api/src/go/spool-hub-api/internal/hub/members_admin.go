package hub

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The admin's Users page (specs/025 FR-012): list the tenant's
// members and pending invites, revoke an invite. Invite, role change and
// removal are the FR-007 routes in rbac.go. Every route re-checks the
// permission per request; the WUI hiding the section is convenience only.

// InviteMailer mails the invitation of a stored (tenant, email) invite and
// answers the invitemail outcome ("sent", "logged", "rate_limited", ...). locale is the
// inviter's WUI locale ("" = the hub default).
type InviteMailer func(ctx context.Context, tenant, email, locale string) (string, error)

type memberRow struct {
	HumanID     string `json:"human_id"`
	DisplayName string `json:"display_name"`
	Email       string `json:"email"`
	Role        string `json:"role"`
	Since       string `json:"since"`
	Disabled    bool   `json:"disabled"`
	// Suspended: disabled in this tenant only (specs/046, rdb 0074).
	Suspended bool    `json:"suspended"`
	LastSeen  *string `json:"last_seen"` // null = never switched into the tenant
	You       bool    `json:"you"`
	// Manageable: the caller's role covers this member's (025 §3.4 rule 2)
	// and it is not the caller. The hub re-checks on every write.
	Manageable bool `json:"manageable"`
	// Provenance of the invite this member accepted (CLE-77778, rdb 0084):
	// who ordered it, that human's display name, via which agent, and when.
	// All "" / null when the member did not come through an invite.
	OrderedBy     string  `json:"ordered_by"`
	OrderedByName string  `json:"ordered_by_name"`
	OrderedVia    string  `json:"ordered_via"`
	InvitedOn     *string `json:"invited_on"`
}

type inviteRow struct {
	Email     string `json:"email"`
	Role      string `json:"role"`
	InvitedBy string `json:"invited_by"`
	CreatedAt string `json:"created_at"`
	ExpiresAt string `json:"expires_at"`
	Expired   bool   `json:"expired"`
	MailCount int    `json:"mail_count"`
	// Provenance (CLE-77778, rdb 0084): who ordered this invite, that human's
	// display name, and via which agent. "" when unknown (historic operator).
	OrderedBy     string `json:"ordered_by"`
	OrderedByName string `json:"ordered_by_name"`
	OrderedVia    string `json:"ordered_via"`
}

type roleRow struct {
	ID        string `json:"id"`
	Grantable bool   `json:"grantable"` // the caller may give this role (§3.4 rule 1)
}

type membersBody struct {
	TenantID string      `json:"tenant_id"`
	You      string      `json:"you"`
	Members  []memberRow `json:"members"`
	Invites  []inviteRow `json:"invites"`
	Roles    []roleRow   `json:"roles"`
}

func (s *Server) directory(w http.ResponseWriter, h store.Humans) (store.MemberDirectory, bool) {
	d, ok := h.(store.MemberDirectory)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no member directory")
	}
	return d, ok
}

// GET /v1/members: members.invite (the admin's only permission, owner
// 2026-09-25), so the list and the Users entry go together.
func (s *Server) handleMemberList(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	d, ok := s.directory(w, h)
	if !ok {
		return
	}
	ms, err := d.ListMembers(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "members unavailable")
		return
	}
	ins, err := d.ListInvites(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "invites unavailable")
		return
	}
	now := s.o.Now().UTC()
	out := membersBody{TenantID: t.ID, You: a.HumanID, Members: []memberRow{}, Invites: []inviteRow{}, Roles: []roleRow{}}
	for _, m := range ms {
		row := memberRow{HumanID: m.HumanID, DisplayName: m.DisplayName, Email: m.Email,
			Role: m.Role, Since: rfc(m.Since), Disabled: m.Disabled, Suspended: m.Suspended, You: m.HumanID == a.HumanID,
			Manageable: m.HumanID != a.HumanID && a.Covers(roles[m.Role]),
			OrderedBy:  m.OrderedBy, OrderedByName: m.OrderedByName, OrderedVia: m.OrderedVia}
		if !m.LastSeen.IsZero() {
			at := rfc(m.LastSeen)
			row.LastSeen = &at
		}
		if !m.InvitedOn.IsZero() {
			at := rfc(m.InvitedOn)
			row.InvitedOn = &at
		}
		out.Members = append(out.Members, row)
	}
	for _, in := range ins {
		out.Invites = append(out.Invites, inviteRow{Email: in.Email, Role: in.Role, InvitedBy: in.InvitedBy,
			CreatedAt: rfc(in.CreatedAt), ExpiresAt: rfc(in.ExpiresAt), Expired: !now.Before(in.ExpiresAt), MailCount: in.MailCount,
			OrderedBy: in.OrderedBy, OrderedByName: in.OrderedByName, OrderedVia: in.OrderedVia})
	}
	// System roles in the spec's order, then any tenant role by id.
	seen := map[string]bool{}
	for _, id := range rbac.RoleIDs {
		if rr, ok := roles[id]; ok {
			out.Roles = append(out.Roles, roleRow{ID: id, Grantable: a.Covers(rr)})
			seen[id] = true
		}
	}
	var extra []string
	for id := range roles {
		if !seen[id] {
			extra = append(extra, id)
		}
	}
	sort.Strings(extra)
	for _, id := range extra {
		out.Roles = append(out.Roles, roleRow{ID: id, Grantable: a.Covers(roles[id])})
	}
	writeJSON(w, http.StatusOK, out)
}

// DELETE /v1/members/invites?email=<address>: revoke a pending invite.
func (s *Server) handleInviteRevoke(w http.ResponseWriter, r *http.Request) {
	t, a, _, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	d, ok := s.directory(w, h)
	if !ok {
		return
	}
	email := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("email")))
	if email == "" || len(email) > 320 || !strings.Contains(email, "@") {
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
		return
	}
	switch err := d.RevokeInvite(r.Context(), t.ID, email); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no pending invite for that address")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invite not revoked")
	default:
		s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Msg("member.invite_revoked")
		w.WriteHeader(http.StatusNoContent)
	}
}

// notSelf refuses a caller removing its own membership (CLE-34969: another
// admin does it, so nobody locks themselves out by a misclick). A self role
// change stays allowed (a biz_owner stepping down); the last-owner and
// last-admin guards keep the tenant manageable.
func notSelf(w http.ResponseWriter, a rbac.Access, target string) bool {
	if target == a.HumanID {
		writeErr(w, http.StatusConflict, "self", "you cannot remove yourself; ask another admin")
		return false
	}
	return true
}

// mailInvite sends the invitation of a just-stored invite; the invite
// stands whatever the mail does ("not_configured" when the hub has no relay).
func (s *Server) mailInvite(r *http.Request, tenant, email string) string {
	if s.o.InviteMail == nil {
		return "not_configured"
	}
	loc := r.Header.Get("X-Locale")
	if ts, ok := s.o.Store.(store.TenantSettings); ok && loc == "" {
		// specs/046 §4.5: the tenant's default locale when the admin sent none
		if cfg, err := ts.TenantConfig(r.Context(), tenant); err == nil {
			loc = cfg.DefaultLocale
		}
	}
	out, err := s.o.InviteMail(r.Context(), tenant, email, loc)
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("member.invite_mail_failed")
		if out == "" {
			out = "send_failed"
		}
	}
	return out
}
