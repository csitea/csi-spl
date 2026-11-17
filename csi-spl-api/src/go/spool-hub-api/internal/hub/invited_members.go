package hub

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"slices"
	"strings"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Invited members (spec 025 section 13, SPL-5706). Owner HUM-10, t1
// 028ac340: "Once invited, the members of a workspace must become actual
// members of the workspace but just be inactive", and an invitee can be added
// to a channel from its properties.
//
// An OPEN workspace invite (unaccepted, unexpired) IS the inactive member: no
// new row and no HUM-* id. So an invitee reads and posts nothing by
// construction, sign-in activates it (acceptInviteTx), a revoke removes it
// and an expired invite is no member any more. The channel add of an invitee
// is the pending row of section 11 (rdb 0231), the one mechanism.
//
// GET /v1/view/members/invited lists them to a member of the workspace (the
// person gate of the member card: a cookie session, no Bearer, no act-as).
// Each row carries an opaque id (inviteID), so the picker and the channel
// list work where the address is masked: the address shows exactly where a
// member card shows one, and is masked (j…@example.com) in the demo to
// everyone but a members.invite holder (inviteViewFor). The roster is
// unchanged.
//
// In a name-only workspace (MemberCardNameOnlyWorkspaces, t1 by default) an
// invitee carries no address and no domain for anyone, the inviter and an
// admin included (spec 154 section 12.6, SPL-5830; owner HUM-10, msg
// 10b28abb: "Dear future spool-hub user"): the label is "" with masked true,
// and the WUI shows its own words for an invitee with no name. An invite
// carries no name, so every open invitee there is one; once they sign in they
// are a member and show by first and last name.

// invitedRow is one inactive member as the caller sees it.
type invitedRow struct {
	ID        string `json:"id"`
	Label     string `json:"label"` // the address, its masked form, or "" (name-only)
	Masked    bool   `json:"masked"`
	InvitedOn string `json:"invited_on"`
	ExpiresAt string `json:"expires_at"`
}

// channelInviteeRow is one pending address of a channel's members list.
type channelInviteeRow struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Masked bool   `json:"masked"`
}

func (s *Server) routeInvitedMembers(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/members/invited", s.handleInvitedMembers)
	mux.HandleFunc("OPTIONS /v1/view/members/invited", s.gcalPreflight("GET"))
}

func (s *Server) handleInvitedMembers(w http.ResponseWriter, r *http.Request) {
	t, hum, ok := s.personCaller(w, r, "invited_members")
	if !ok {
		return
	}
	if !s.allowed(r.Context(), hum, t.ID, rbac.TopicsRead) {
		writeErr(w, http.StatusForbidden, "not_member", "not a member of this workspace")
		return
	}
	ins, err := s.openInvites(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", "invited_members").Str("tenant", t.ID).Msg("invited members")
		writeErr(w, http.StatusInternalServerError, "internal", "invites unavailable")
		return
	}
	view := s.inviteViewFor(r.Context(), t.ID, hum)
	out := make([]invitedRow, 0, len(ins))
	for _, in := range ins {
		label, masked := inviteLabel(in.Email, view)
		out = append(out, invitedRow{ID: s.inviteID(t.ID, in.Email), Label: label, Masked: masked,
			InvitedOn: rfc(in.CreatedAt), ExpiresAt: rfc(in.ExpiresAt)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"invited": out})
}

// openInvites is tenant's unaccepted, unexpired invites, oldest first; none
// on a store without a member directory.
func (s *Server) openInvites(ctx context.Context, tenant string) ([]store.PendingInvite, error) {
	d, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		return nil, nil
	}
	ins, err := d.ListInvites(ctx, tenant)
	if err != nil {
		return nil, err
	}
	now := s.o.Now()
	open := make([]store.PendingInvite, 0, len(ins))
	for _, in := range ins {
		if now.Before(in.ExpiresAt) {
			open = append(open, in)
		}
	}
	return open, nil
}

// inviteEmailByID is the address of tenant's open invite whose inviteID is
// id, or "" when none matches.
func (s *Server) inviteEmailByID(ctx context.Context, tenant, id string) string {
	ins, err := s.openInvites(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("invite by id")
		return ""
	}
	for _, in := range ins {
		if s.inviteID(tenant, in.Email) == id {
			return in.Email
		}
	}
	return ""
}

// inviteView is how much of an invitee's address a caller reads.
type inviteView int

const (
	inviteShown  inviteView = iota // the whole address
	inviteMasked                   // j…@example.com
	inviteHidden                   // nothing: no address, no domain
)

// inviteViewFor is how hum reads an invitee's address in tenant: hidden in
// a name-only workspace to everyone, whatever their role (spec 154 section
// 12.6); masked in the demo except to a members.invite holder (it lists
// invites); else shown, the rule of the member card.
func (s *Server) inviteViewFor(ctx context.Context, tenant, hum string) inviteView {
	if slices.Contains(s.o.MemberCardNameOnlyWorkspaces, tenant) {
		return inviteHidden
	}
	demo := s.o.DemoWorkspace != "" && tenant == s.o.DemoWorkspace
	if !demo || (hum != "" && s.allowed(ctx, hum, tenant, rbac.MembersInvite)) {
		return inviteShown
	}
	return inviteMasked
}

// inviteID is the opaque handle of tenant's invite to email: "INV-" and 16
// hex of an HMAC-SHA256 under the hub's InviteIDKey, stable while the invite
// lives and the same on every instance, never the address itself. Keyed
// (R7 W2): an unkeyed hash let a masked caller, who knows the tenant, the
// first letter and the domain, confirm a guessed address offline.
func (s *Server) inviteID(tenant, email string) string {
	return inviteIDWith(s.inviteIDKey(), tenant, email)
}

// inviteIDWith is inviteID under key.
func inviteIDWith(key []byte, tenant, email string) string {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(tenant + "\x00" + strings.ToLower(email)))
	return "INV-" + hex.EncodeToString(m.Sum(nil)[:8])
}

// processInviteKey is the random InviteIDKey of a hub with no session key:
// ids then hold for this process only, and are never unkeyed.
var processInviteKey = sync.OnceValue(func() []byte {
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		panic("invite id key: " + err.Error())
	}
	return k
})

// inviteIDKey is Options.InviteIDKey, or the per-process key without one.
func (s *Server) inviteIDKey() []byte {
	if len(s.o.InviteIDKey) > 0 {
		return s.o.InviteIDKey
	}
	return processInviteKey()
}

// isInviteID reports whether v has inviteID's shape.
func isInviteID(v string) bool {
	if len(v) != 20 || !strings.HasPrefix(v, "INV-") {
		return false
	}
	_, err := hex.DecodeString(v[4:])
	return err == nil
}

// inviteLabel is email as view shows it: whole, masked (the first letter of
// the local part, an ellipsis and the domain, j…@example.com), or hidden ("",
// masked: the caller names the invitee in its own words).
func inviteLabel(email string, view inviteView) (string, bool) {
	switch view {
	case inviteShown:
		return email, false
	case inviteHidden:
		return "", true
	}
	at := strings.LastIndex(email, "@")
	if at <= 0 {
		return "…", true
	}
	first := []rune(email[:at])[0]
	return string(first) + "…" + email[at:], true
}

// channelInviteeRows is a channel's pending addresses as hum sees them: the
// plain list (invited, spec 025 section 11) and the rows with their ids
// (invitees), both as inviteViewFor shows them ("" in a name-only workspace).
func (s *Server) channelInviteeRows(ctx context.Context, tenant, hum string, emails []string) ([]string, []channelInviteeRow) {
	view := s.inviteViewFor(ctx, tenant, hum)
	labels := make([]string, 0, len(emails))
	rows := make([]channelInviteeRow, 0, len(emails))
	for _, e := range emails {
		label, masked := inviteLabel(e, view)
		labels = append(labels, label)
		rows = append(rows, channelInviteeRow{ID: s.inviteID(tenant, e), Label: label, Masked: masked})
	}
	return labels, rows
}

// oneOf counts the non-empty values.
func oneOf(vs ...string) int {
	n := 0
	for _, v := range vs {
		if v != "" {
			n++
		}
	}
	return n
}
