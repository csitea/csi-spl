package hub

import (
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The member card (spec 154 section 12, SPL-5431; owner HUM-10, t1 30f935b4
// msg 4329fec1: "for the people who are in the workspace, once added to the
// workspace, at least their email and their names should be visible to all
// of the other people in the workspace"; corrected by 028ac340: not in t1).
//
// GET /v1/view/members/{id}/card answers one member's display name and
// address (humans.email) to another member of the SAME workspace:
//   - the caller is a person (personCaller: a cookie session, no Bearer, no
//     act-as, no live clone, no agent seat; else 403 person_only);
//   - the caller holds a live seat in the session's workspace (not
//     suspended, not disabled, access not ended; else 403 not_member);
//   - the target is a member of that workspace, read by ListMembers under
//     its tenant scope (RLS), so another workspace's member is 404 not_found,
//     as is a channel guest or a technical human, which that read leaves out.
// In the demo workspace the card carries no address (specs/077 FR-007: a
// visitor sees the others only by pseudonym; TestDemoVisitorsSeeOnlyPseudonyms).
// Nor in a name-only workspace, Options.MemberCardNameOnlyWorkspaces, t1 by
// default (section 12.4; owner HUM-10, t1 028ac340: "In the T1 workspace only
// the first name and the last name from a contact should be visible. Nothing
// else should be visible."): there the card is the id and the name, email null.
// Never gated by members.invite: every member reads it. The roster
// (/v1/view/roster) stays without the address, since a view token and an
// agent read it. The address is never logged; the answer is no-store.

type memberCardBody struct {
	HumanID     string  `json:"human_id"`
	DisplayName *string `json:"display_name"` // null = none chosen
	Email       *string `json:"email"`        // null = none on file
}

func (s *Server) routeMemberCard(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/members/{id}/card", s.handleMemberCard)
	mux.HandleFunc("OPTIONS /v1/view/members/{id}/card", s.gcalPreflight("GET"))
}

func (s *Server) handleMemberCard(w http.ResponseWriter, r *http.Request) {
	t, hum, ok := s.personCaller(w, r, "member_card")
	if !ok {
		return
	}
	d, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no member directory")
		return
	}
	ms, err := d.ListMembers(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", "member_card").Str("tenant", t.ID).Msg("member card")
		writeErr(w, http.StatusInternalServerError, "internal", "members unavailable")
		return
	}
	now := s.o.Now().UTC()
	target := r.PathValue("id")
	var me, them *store.Member
	for i := range ms {
		switch ms[i].HumanID {
		case hum:
			me = &ms[i]
		case target:
			them = &ms[i]
		}
	}
	if target == hum {
		them = me
	}
	if me == nil || me.Disabled || me.Suspended || (!me.AccessUntil.IsZero() && !now.Before(me.AccessUntil)) {
		writeErr(w, http.StatusForbidden, "not_member", "not a member of this workspace")
		return
	}
	if them == nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such member in this workspace")
		return
	}
	card := memberCard(*them)
	if s.o.DemoWorkspace != "" && t.ID == s.o.DemoWorkspace {
		card.Email = nil // specs/077 FR-007: a demo visitor is a pseudonym, never an address
	}
	if slices.Contains(s.o.MemberCardNameOnlyWorkspaces, t.ID) {
		card.Email = nil // spec 154 12.4: t1 shows the name only
	}
	writeJSON(w, http.StatusOK, card)
}

func memberCard(m store.Member) memberCardBody {
	out := memberCardBody{HumanID: m.HumanID}
	if n := strings.TrimSpace(m.DisplayName); n != "" {
		out.DisplayName = &n
	}
	if e := strings.TrimSpace(m.Email); e != "" {
		out.Email = &e
	}
	return out
}
