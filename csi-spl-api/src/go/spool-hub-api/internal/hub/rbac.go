package hub

import (
	"context"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Tenant roles and permissions (specs/025). The hub checks a PERMISSION at
// every human entry point, for the (human, active tenant) pair humanTenant
// resolved (specs/026); the role -> permission rows live in the DB (rdb 0021).

// Authorizer answers one human's standing in one tenant. rbac.Authorizer
// (store-backed, cached role table) is the production one; rbac.Fixed is
// the seam for rigs whose humans come from Options.SessionID.
type Authorizer interface {
	Access(ctx context.Context, humanID, tenant string) (rbac.Access, error)
	Roles(ctx context.Context, tenant string) (map[string]rbac.Role, error)
}

// defaultAuthorizer is the store-backed authorizer, nil when the store keeps
// no humans (then every human check denies: fail closed).
func defaultAuthorizer(st store.Store) Authorizer {
	h, ok := st.(store.Humans)
	if !ok {
		return nil
	}
	return &rbac.Authorizer{Src: store.RBACSource{H: h}}
}

// errNoAuthorizer: the hub has no authorizer, so a human is denied.
var errNoAuthorizer = errors.New("hub: no authorizer")

func (s *Server) access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	if s.o.Authorizer == nil {
		return rbac.Access{}, errNoAuthorizer
	}
	return s.o.Authorizer.Access(ctx, hum, tenant)
}

// allowed reports perm for hum in tenant. hum "" is the anonymous door-off
// guest (lde): allowed, as before 025; with the door on it is a deny.
func (s *Server) allowed(ctx context.Context, hum, tenant, perm string) bool {
	if hum == "" {
		return s.o.ViewDoor == ViewDoorOff
	}
	a, err := s.access(ctx, hum, tenant)
	return err == nil && a.Can(perm)
}

// forbiddenBody is a 403 that names the missing permission (025 FR-005).
type forbiddenBody struct {
	Error      string `json:"error"`
	Detail     string `json:"detail"`
	Permission string `json:"permission,omitempty"`
}

func writeForbidden(w http.ResponseWriter, perm, detail string) {
	writeJSON(w, http.StatusForbidden, forbiddenBody{Error: "forbidden", Detail: detail, Permission: perm})
}

// permit writes 403 unless hum may perm in tenant.
func (s *Server) permit(w http.ResponseWriter, r *http.Request, tenant, hum, perm string) bool {
	if s.allowed(r.Context(), hum, tenant, perm) {
		return true
	}
	writeForbidden(w, perm, "your role in this tenant does not grant "+perm)
	return false
}

// ---- GET /v1/view/me (025 FR-006) --------------------------------------------

type meBody struct {
	HumanID     *string  `json:"human_id"`
	TenantID    string   `json:"tenant_id"`
	Role        *string  `json:"role"`
	TenantOwner *bool    `json:"tenant_owner"`
	Permissions []string `json:"permissions"` // null = door-off guest (no RBAC)
	// SPL-1034 (rdb 0073): the person's own Channels order in this tenant;
	// null = never set (or a door-off guest).
	ChannelOrder []string `json:"channel_order"`
}

func (s *Server) handleViewMe(w http.ResponseWriter, r *http.Request) {
	r = r.WithContext(store.WithMemo(r.Context())) // a read: one membership lookup
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	out := meBody{TenantID: t.ID}
	if hum != "" {
		a, err := s.access(r.Context(), hum, t.ID)
		if err != nil {
			writeForbidden(w, rbac.TopicsRead, "no role in this tenant")
			return
		}
		out.HumanID, out.Role, out.TenantOwner, out.Permissions = &hum, &a.Role, &a.TenantOwner, a.List()
		out.ChannelOrder = s.channelOrder(r.Context(), t.ID, hum)
	}
	writeJSON(w, http.StatusOK, out)
}

// ---- members API (025 FR-007) ------------------------------------------------

const (
	inviteTTLDefault = 7 * 24 * time.Hour
	inviteTTLMax     = 30 * 24 * time.Hour
	membersMaxBody   = 4 << 10
)

// membersActor resolves the caller, checks perm, and answers the caller's
// access, the tenant's roles and the humans store; false = answered.
func (s *Server) membersActor(w http.ResponseWriter, r *http.Request, perm string) (store.Tenant, rbac.Access, map[string]rbac.Role, store.Humans, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	fail := func() (store.Tenant, rbac.Access, map[string]rbac.Role, store.Humans, bool) {
		return store.Tenant{}, rbac.Access{}, nil, nil, false
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return fail()
	}
	h, isH := s.o.Store.(store.Humans)
	if hum == "" || !isH {
		// Member management needs a signed-in member, door or no door.
		writeForbidden(w, perm, "managing members needs a member session")
		return fail()
	}
	a, err := s.access(r.Context(), hum, t.ID)
	if err != nil || !a.Can(perm) {
		writeForbidden(w, perm, "your role in this tenant does not grant "+perm)
		return fail()
	}
	roles, err := s.o.Authorizer.Roles(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "roles unavailable")
		return fail()
	}
	return t, a, roles, h, true
}

// grantable resolves a requested role and applies 025 §3.4 rule 1.
func grantable(w http.ResponseWriter, a rbac.Access, roles map[string]rbac.Role, want, def string) (string, bool) {
	role := rbac.Legacy(strings.TrimSpace(want))
	if role == "" {
		role = def
	}
	r, ok := roles[role]
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_role", "role "+role+" is not a role of this tenant")
		return "", false
	}
	if !a.Covers(r) {
		writeForbidden(w, "", "your role cannot grant "+role+" (it grants permissions yours lacks)")
		return "", false
	}
	return role, true
}

// targetRole answers the member's current role and applies §3.4 rule 2.
func (s *Server) targetRole(w http.ResponseWriter, r *http.Request, h store.Humans, t store.Tenant, a rbac.Access, roles map[string]rbac.Role) (string, string, bool) {
	target := r.PathValue("human_id")
	if !humanIDRe.MatchString(target) {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return "", "", false
	}
	cur, err := s.memberRoleAny(r.Context(), h, t.ID, target)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return "", "", false
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "member lookup failed")
		return "", "", false
	}
	if !a.Covers(roles[cur]) {
		writeForbidden(w, "", "your role cannot manage a member whose role is "+cur)
		return "", "", false
	}
	return target, cur, true
}

func decodeMembers(w http.ResponseWriter, r *http.Request, v any) bool {
	// application/json only, like keys and native auth: a
	// text/plain body is a "simple" cross-site form post that needs no
	// preflight, and it can carry valid JSON - so without this gate only the
	// session cookie's SameSite=Lax stood between another site and an invite.
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, membersMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body is not the expected JSON object")
		return false
	}
	return true
}

func writeMemberErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
	case errors.Is(err, store.ErrLastAdmin):
		writeErr(w, http.StatusConflict, "last_admin", "the tenant's last admin cannot be removed or demoted")
	case errors.Is(err, store.ErrLastOwner):
		writeErr(w, http.StatusConflict, "last_owner", "the tenant's last owner cannot be removed or demoted")
	case errors.Is(err, store.ErrRoleChanged):
		writeErr(w, http.StatusConflict, "role_changed", "the member's role changed; reload and retry")
	case errors.Is(err, store.ErrUnknownRole):
		writeErr(w, http.StatusBadRequest, "bad_role", "not a role of this tenant")
	default:
		writeErr(w, http.StatusInternalServerError, "internal", "member not changed")
	}
}

// POST /v1/members/invites {email, role?, ttl_hours?}
func (s *Server) handleMemberInvite(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	var body struct {
		Email    string `json:"email"`
		Role     string `json:"role"`
		TTLHours int    `json:"ttl_hours"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	role, ok := grantable(w, a, roles, body.Role, store.RoleDefault)
	if !ok {
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
	in := store.Invite{TenantID: t.ID, Email: body.Email, Role: role, InvitedBy: a.HumanID, ExpiresAt: now.Add(ttl)}
	switch err := h.PutInvite(r.Context(), in, now); {
	case errors.Is(err, store.ErrUnknownRole):
		writeErr(w, http.StatusBadRequest, "bad_role", "not a role of this tenant")
	case err != nil && strings.Contains(err.Error(), "invite email"):
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invite not stored")
	default:
		email := strings.ToLower(strings.TrimSpace(body.Email))
		mailed := s.mailInvite(r, t.ID, email)
		s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("role", role).Str("mail", mailed).Msg("member.invited")
		writeJSON(w, http.StatusCreated, map[string]any{"tenant_id": t.ID, "email": email,
			"role": role, "invited_by": a.HumanID, "expires_at": rfc(in.ExpiresAt), "mail": mailed})
	}
}

// PUT /v1/members/{human_id}/role {role, from_role?}
func (s *Server) handleMemberRole(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersRoles)
	if !ok {
		return
	}
	var body struct {
		Role     string `json:"role"`
		FromRole string `json:"from_role"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if strings.TrimSpace(body.Role) == "" {
		writeErr(w, http.StatusBadRequest, "bad_role", "role is required")
		return
	}
	target, _, ok := s.targetRole(w, r, h, t, a, roles)
	if !ok {
		return
	}
	role, ok := grantable(w, a, roles, body.Role, "")
	if !ok {
		return
	}
	if err := h.SetMemberRole(r.Context(), t.ID, target, role, body.FromRole); err != nil {
		writeMemberErr(w, err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("member", target).Str("role", role).Msg("member.role_changed")
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": t.ID, "human_id": target, "role": role})
}

// DELETE /v1/members/{human_id}
func (s *Server) handleMemberRemove(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	target, _, ok := s.targetRole(w, r, h, t, a, roles)
	if !ok || !notSelf(w, a, target) {
		return
	}
	if err := h.RemoveMember(r.Context(), t.ID, target); err != nil {
		writeMemberErr(w, err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("member", target).Msg("member.removed")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) membersPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeMembers(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/me", s.handleViewMe)
	mux.HandleFunc("GET /v1/members", s.handleMemberList)
	mux.HandleFunc("POST /v1/members/invites", s.handleMemberInvite)
	mux.HandleFunc("DELETE /v1/members/invites", s.handleInviteRevoke)
	mux.HandleFunc("PUT /v1/members/{human_id}/role", s.handleMemberRole)
	mux.HandleFunc("DELETE /v1/members/{human_id}", s.handleMemberRemove)
	mux.HandleFunc("OPTIONS /v1/members", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/invites", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}/role", s.membersPreflight)
}
