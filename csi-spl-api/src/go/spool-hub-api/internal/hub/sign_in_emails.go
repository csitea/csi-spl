package hub

import (
	"errors"
	"net/http"
	"net/mail"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A member's sign-in emails (owner HUM-10, t1 f265541a). msg cca0746d: "Only
// the admin of a workspace can add other emails to other users, but before
// they can use them, they must authenticate with them against the cloud
// provider."; msg 39420f52: "the users should be able to provide emails by
// themselves, but those emails cannot be used for logging in unless they
// have at least once logged in via the public provider. They should be told
// about this logic." store/sign_in_emails.go holds the rules; these routes
// are the doors:
//
//	GET    /v1/members/{human_id}/emails          the member, or an admin of this workspace
//	POST   /v1/members/{human_id}/emails {email}  the member or an admin: add as PENDING
//	DELETE /v1/members/{human_id}/emails?email=   the member or an admin: remove a pending or extra address
//
// "Admin" is members.invite in THIS workspace (the admin's permission, owner
// 2026-09-25), the target a member of it (404 otherwise: existence never
// leaks) whose role the caller covers. "The member" is the session's own
// human, never an act-as clone or a demo visitor. No mail is sent: the address turns ACTIVE
// only when a provider sign-in proves it, and the add answers state plus a
// reason code the WUI explains (pending_until_provider_sign_in,
// already_active). The member list keeps showing humans.email only.

// Reason codes of the add answer, for the WUI's explanation.
const (
	reasonPendingProvider = "pending_until_provider_sign_in"
	reasonAlreadyActive   = "already_active"
)

func (s *Server) signInEmailStore(w http.ResponseWriter) (store.SignInEmails, bool) {
	e, ok := s.o.Store.(store.SignInEmails)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no sign-in emails")
	}
	return e, ok
}

// GET: the member reads their own list; anyone else needs members.invite
// here and the target a member of this workspace.
func (s *Server) handleSignInEmails(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	target := r.PathValue("human_id")
	if hum == "" || target != hum {
		if _, _, _, _, ok := s.membersActor(w, r, rbac.MembersInvite); !ok {
			return
		}
		h, isH := s.o.Store.(store.Humans)
		if !isH || !humanIDRe.MatchString(target) {
			writeErr(w, http.StatusNotFound, "not_found", "no such member")
			return
		}
		if _, err := s.memberRoleAny(r.Context(), h, t.ID, target); err != nil {
			writeErr(w, http.StatusNotFound, "not_found", "no such member")
			return
		}
	}
	e, ok := s.signInEmailStore(w)
	if !ok {
		return
	}
	list, err := e.SignInEmails(r.Context(), target)
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"human_id": target, "emails": list})
}

// signInEmailTarget is the self or admin + target check of the two writes.
func (s *Server) signInEmailTarget(w http.ResponseWriter, r *http.Request) (store.Tenant, string, string, store.SignInEmails, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return t, "", "", nil, false
	}
	if target := r.PathValue("human_id"); hum != "" && target == hum {
		// A demo visitor keeps a pseudonym and no account of its own
		// (specs/077): no addresses either.
		if acc, err := s.access(r.Context(), hum, t.ID); err != nil || acc.Role == rbac.DemoUser {
			writeForbidden(w, "", "a demo visitor has no sign-in emails")
			return t, "", "", nil, false
		}
		// An act-as clone is a technical human nobody signs in as: an
		// address on it would make it one (specs/054).
		if s.o.Auth != nil {
			if sess, ok := s.o.Auth.SessionFromRequest(r); ok && sess.Provider == auth.ProviderActAs {
				writeErr(w, http.StatusForbidden, "act_as", "an act-as session does not change sign-in emails")
				return t, "", "", nil, false
			}
		}
		e, ok := s.signInEmailStore(w)
		return t, hum, hum, e, ok
	}
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return t, "", "", nil, false
	}
	target, _, ok := s.targetRole(w, r, h, t, a, roles)
	if !ok {
		return t, "", "", nil, false
	}
	e, ok := s.signInEmailStore(w)
	return t, a.HumanID, target, e, ok
}

// signInAddress lower-cases and checks a bare address; "" = 400 written.
func signInAddress(w http.ResponseWriter, raw string) string {
	email := strings.ToLower(strings.TrimSpace(raw))
	a, err := mail.ParseAddress(email)
	if len(email) < 3 || len(email) > 320 || err != nil || a.Address != email || a.Name != "" {
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
		return ""
	}
	return email
}

func (s *Server) handleSignInEmailAdd(w http.ResponseWriter, r *http.Request) {
	t, by, target, e, ok := s.signInEmailTarget(w, r)
	if !ok {
		return
	}
	var body struct {
		Email string `json:"email"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	email := signInAddress(w, body.Email)
	if email == "" {
		return
	}
	state, err := e.AddPendingEmail(r.Context(), target, email, t.ID, by, s.o.Now())
	switch {
	case errors.Is(err, store.ErrEmailTaken):
		// No hint of whose it is, and no merge.
		writeErr(w, http.StatusConflict, "email_taken", "this address belongs to another account")
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return
	case errors.Is(err, store.ErrTechnicalHuman):
		writeErr(w, http.StatusConflict, "technical", "an agent or a clone has no sign-in emails")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "address not added")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", by).Str("member", target).Str("state", state).Msg("member.sign_in_email_added")
	reason := reasonPendingProvider
	if state == store.EmailActive {
		reason = reasonAlreadyActive
	}
	writeJSON(w, http.StatusOK, map[string]any{"human_id": target, "email": email, "state": state, "reason": reason})
}

func (s *Server) handleSignInEmailRemove(w http.ResponseWriter, r *http.Request) {
	t, by, target, e, ok := s.signInEmailTarget(w, r)
	if !ok {
		return
	}
	email := signInAddress(w, r.URL.Query().Get("email"))
	if email == "" {
		return
	}
	switch err := e.RemoveSignInEmail(r.Context(), target, email); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such address on this member")
	case errors.Is(err, store.ErrLastSignIn):
		writeErr(w, http.StatusConflict, "last_sign_in", "this is the member's last way to sign in")
	case errors.Is(err, store.ErrMainEmail):
		writeErr(w, http.StatusConflict, "main_email", "the member's main address is not removed here")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "address not removed")
	default:
		s.o.Log.Info().Str("tenant", t.ID).Str("by", by).Str("member", target).Msg("member.sign_in_email_removed")
		w.WriteHeader(http.StatusNoContent)
	}
}
