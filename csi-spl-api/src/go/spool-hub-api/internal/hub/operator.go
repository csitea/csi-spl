package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/invitemail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator invite surface (CLE-77780, owner 2026-09-30): the box operator
// creates an invite and sends its invitation email FROM the hub on Cloud Run,
// so no box ever dials SMTP (the home IPv6 egress that timed out for 70 s).
// These routes carry no member session; they are authorised by a Google ID
// token minted by the env's service account (never the owner account), whose
// verified email must be in OperatorEmails. Everything else — the resend gap
// and cap, the role FK, the tenant existence — is the same store path the WUI
// admin uses, so the two cannot diverge.

// OperatorVerify validates a bearer token and returns the caller's verified
// email (lower-cased), or an error. In production it is a Google ID token
// check (idtoken.Validate) wired in cmd/spool; tests pass a seam.
type OperatorVerify func(ctx context.Context, token, audience string) (email string, err error)

// OperatorMailer sends an invite's mail and returns the full result
// (message_id, delivered) so the operator route and the shell proof can show
// delivered:true without reading Cloud Run logs.
type OperatorMailer func(ctx context.Context, tenant, email, locale string) (invitemail.Result, error)

// operatorEnabled reports whether the operator routes will act; when off they
// answer 404 so a probe cannot tell a disabled hub from a missing path.
func (s *Server) operatorEnabled() bool {
	return len(s.o.OperatorEmails) > 0 && s.o.OperatorVerify != nil
}

// operatorAuth authorises an operator call: a Bearer id token whose verified
// email is in OperatorEmails. It writes the error itself and returns ok=false.
func (s *Server) operatorAuth(w http.ResponseWriter, r *http.Request) (string, bool) {
	w.Header().Set("Cache-Control", "no-store")
	if !s.operatorEnabled() {
		writeErr(w, http.StatusNotFound, "not_found", "operator routes are not enabled on this hub")
		return "", false
	}
	tok, ok := strings.CutPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ")
	if !ok || strings.TrimSpace(tok) == "" {
		writeErr(w, http.StatusUnauthorized, "no_token", "operator route needs Authorization: Bearer <id token>")
		return "", false
	}
	email, err := s.o.OperatorVerify(r.Context(), strings.TrimSpace(tok), s.o.OperatorAudience)
	if err != nil {
		s.o.Log.Warn().Err(err).Msg("operator.token_rejected")
		writeErr(w, http.StatusUnauthorized, "bad_token", "operator token rejected")
		return "", false
	}
	email = strings.ToLower(strings.TrimSpace(email))
	for _, allowed := range s.o.OperatorEmails {
		if strings.EqualFold(strings.TrimSpace(allowed), email) {
			return email, true
		}
	}
	s.o.Log.Warn().Str("email", email).Msg("operator.not_allowlisted")
	writeErr(w, http.StatusForbidden, "not_operator", "this identity is not an operator of this hub")
	return "", false
}

// operatorMail sends (or resends) the invite mail through OperatorMailer and
// never fails the request on a relay refusal — the invite stands, the outcome
// is reported. "not_configured" when the hub has no relay.
func (s *Server) operatorMail(ctx context.Context, tenant, email, locale string) invitemail.Result {
	if s.o.OperatorMail == nil {
		return invitemail.Result{Outcome: "not_configured"}
	}
	if locale == "" {
		if ts, ok := s.o.Store.(store.TenantSettings); ok {
			if cfg, err := ts.TenantConfig(ctx, tenant); err == nil {
				locale = cfg.DefaultLocale
			}
		}
	}
	res, err := s.o.OperatorMail(ctx, tenant, email, locale)
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("operator.invite_mail_failed")
		if res.Outcome == "" {
			res.Outcome = invitemail.SendFailed
		}
	}
	return res
}

// validOperatorInvitedBy accepts a HUM-* id or a store admitted-by marker;
// "" defaults to AdmittedOperator.
func validOperatorInvitedBy(v string) (string, bool) {
	v = strings.TrimSpace(v)
	switch v {
	case "":
		return store.AdmittedOperator, true
	case store.AdmittedOperator, store.AdmittedBootstrap:
		return v, true
	}
	if humanIDRe.MatchString(v) {
		return v, true
	}
	return "", false
}

// POST /v1/operator/invites {tenant, email, role?, ttl_hours?, invited_by?,
// ordered_by?, ordered_via?, locale?, no_mail?}: create (or replace) the
// invite and mail it from the hub. 201 with the mail outcome.
func (s *Server) handleOperatorInvite(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	var body struct {
		Tenant     string `json:"tenant"`
		Email      string `json:"email"`
		Role       string `json:"role"`
		TTLHours   int    `json:"ttl_hours"`
		InvitedBy  string `json:"invited_by"`
		OrderedBy  string `json:"ordered_by"`
		OrderedVia string `json:"ordered_via"`
		Locale     string `json:"locale"`
		NoMail     bool   `json:"no_mail"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if !msg.ValidTenantID(body.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	if email == "" || len(email) > 320 || !strings.Contains(email, "@") {
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
		return
	}
	h, ok := s.o.Store.(store.Humans)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no invites")
		return
	}
	role := rbac.Legacy(strings.TrimSpace(body.Role))
	if role == "" {
		role = store.RoleDefault
	}
	invitedBy, ok := validOperatorInvitedBy(body.InvitedBy)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_invited_by", "invited_by must be a HUM-* id, 'operator' or 'bootstrap'")
		return
	}
	orderedBy := strings.TrimSpace(body.OrderedBy)
	if orderedBy != "" && !humanIDRe.MatchString(orderedBy) {
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be a HUM-* id")
		return
	}
	ttl := time.Duration(body.TTLHours) * time.Hour
	switch {
	case body.TTLHours == 0:
		ttl = inviteTTLDefault
	case body.TTLHours < 0 || ttl > inviteTTLMax:
		writeErr(w, http.StatusBadRequest, "bad_json", "ttl_hours must be 1..720")
		return
	}
	now := s.o.Now().UTC()
	in := store.Invite{TenantID: body.Tenant, Email: email, Role: role, InvitedBy: invitedBy,
		ExpiresAt: now.Add(ttl), OrderedBy: orderedBy, OrderedVia: strings.TrimSpace(body.OrderedVia)}
	switch err := h.PutInvite(r.Context(), in, now); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "tenant does not exist")
	case errors.Is(err, store.ErrUnknownRole):
		writeErr(w, http.StatusBadRequest, "bad_role", "not a role of this tenant")
	case err != nil && strings.Contains(err.Error(), "invite email"):
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invite not stored")
	default:
		out := map[string]any{"tenant_id": body.Tenant, "email": email, "role": role,
			"invited_by": invitedBy, "expires_at": rfc(in.ExpiresAt), "status": "invited"}
		if body.NoMail {
			out["mail"] = invitemail.Result{Outcome: "skipped_no_mail"}
		} else {
			out["mail"] = s.operatorMail(r.Context(), body.Tenant, email, strings.TrimSpace(body.Locale))
		}
		s.o.Log.Info().Str("tenant", body.Tenant).Str("role", role).Str("invited_by", invitedBy).
			Bool("no_mail", body.NoMail).Msg("operator.invited")
		writeJSON(w, http.StatusCreated, out)
	}
}

// POST /v1/operator/invites/mail {tenant, email, locale?}: (re)send the mail
// of an existing open invite from the hub. 200 with the mail outcome (the gap
// and cap are enforced in the store, so an accepted/expired/rate-limited invite
// just carries that outcome).
func (s *Server) handleOperatorInviteMail(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	var body struct {
		Tenant string `json:"tenant"`
		Email  string `json:"email"`
		Locale string `json:"locale"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if !msg.ValidTenantID(body.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	if email == "" || len(email) > 320 || !strings.Contains(email, "@") {
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
		return
	}
	res := s.operatorMail(r.Context(), body.Tenant, email, strings.TrimSpace(body.Locale))
	s.o.Log.Info().Str("tenant", body.Tenant).Str("outcome", res.Outcome).Msg("operator.invite_mail")
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": body.Tenant, "mail": res})
}

// DELETE /v1/operator/invites?tenant=<t>&email=<addr>: revoke a pending invite
// from the hub. 204 on success, 404 when there is no pending invite.
func (s *Server) handleOperatorInviteRevoke(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	tenant := strings.TrimSpace(r.URL.Query().Get("tenant"))
	if !msg.ValidTenantID(tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return
	}
	email := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("email")))
	if email == "" || len(email) > 320 || !strings.Contains(email, "@") {
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
		return
	}
	d, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no member directory")
		return
	}
	switch err := d.RevokeInvite(r.Context(), tenant, email); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no pending invite for that address")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invite not revoked")
	default:
		s.o.Log.Info().Str("tenant", tenant).Msg("operator.invite_revoked")
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) routeOperator(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/invites", s.handleOperatorInvite)
	mux.HandleFunc("POST /v1/operator/invites/mail", s.handleOperatorInviteMail)
	mux.HandleFunc("DELETE /v1/operator/invites", s.handleOperatorInviteRevoke)
}
