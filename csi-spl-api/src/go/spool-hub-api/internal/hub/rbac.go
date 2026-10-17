package hub

import (
	"context"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
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

// access is the human's standing in tenant, read once per request when a
// message write route opened the request memo (privacy.go, perf E07).
func (s *Server) access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	if s.o.Authorizer == nil {
		return rbac.Access{}, errNoAuthorizer
	}
	mm := s.requestMemo(ctx)
	if a, err, ok := mm.access(tenant, hum); ok {
		return a, err
	}
	a, err := s.o.Authorizer.Access(ctx, hum, tenant)
	if err == nil && s.demoFenced(a, tenant) { // specs/077: demo_user only in the open demo workspace
		a, err = rbac.Access{}, rbac.ErrNotMember
	}
	mm.putAccess(tenant, hum, a, err)
	return a, err
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
	HumanID  *string `json:"human_id"`
	TenantID string  `json:"tenant_id"`
	Role     *string `json:"role"`
	// Roles is the member's whole role set, the primary (Role) first (025
	// §10.2 rule 6); null = door-off guest.
	Roles       []string `json:"roles"`
	TenantOwner *bool    `json:"tenant_owner"`
	Permissions []string `json:"permissions"` // null = door-off guest (no RBAC)
	// SPL-1034 (rdb 0073): the person's own Channels order in this tenant;
	// null = never set (or a door-off guest).
	ChannelOrder []string `json:"channel_order"`
	// ActAs is set only when THIS session is an act-as clone (specs/054): it
	// tells the WUI to show the "Acting as X — Stop" banner. null otherwise.
	ActAs *actAsMe `json:"act_as"`
	// TopicArchivePolicy is the workspace "Who can archive topics" setting in
	// force (CLE-77819): everyone | admins | starter. The WUI reads it to
	// decide whether a topic card's menu offers Archive. It rides the cached
	// tenant row, so it costs no extra round trip (TestRoundTripsPerRequest).
	TopicArchivePolicy string `json:"topic_archive_policy,omitempty"`
}

// actAsMe is the act-as state of a clone session (specs/054).
type actAsMe struct {
	TargetHum  string `json:"target_hum"`
	TargetName string `json:"target_name"`
	ExpiresAt  string `json:"expires_at"`
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
		out.Roles = append([]string{}, a.Roles...)
		out.TopicArchivePolicy = s.archivePolicy(t)
		out.ChannelOrder = s.channelOrder(r.Context(), t.ID, hum)
		// Only an act-as session pays the clone lookup (its Provider marks it);
		// a normal /v1/view/me adds no round trip (TestRoundTripsPerRequest).
		if s.o.Auth != nil {
			if sess, ok := s.o.Auth.SessionFromRequest(r); ok && sess.Provider == auth.ProviderActAs {
				out.ActAs = s.actAsMe(r.Context(), t.ID, hum)
			}
		}
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
	return t, a, memberRoles(roles), h, true
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

// coversSet is 025 §10.2 rule 4: the actor covers a role set when it covers
// every role of it, perms(⋃set) ⊆ perms(actor); the tenant owner covers
// everyone. A role the tenant cannot see grants nothing.
func coversSet(a rbac.Access, roles map[string]rbac.Role, set []string) bool {
	for _, id := range set {
		if !a.Covers(roles[id]) {
			return false
		}
	}
	return true
}

// targetRole answers the member's current primary role and applies §3.4
// rule 2 over the member's whole role set (targetRoles).
func (s *Server) targetRole(w http.ResponseWriter, r *http.Request, h store.Humans, t store.Tenant, a rbac.Access, roles map[string]rbac.Role) (string, string, bool) {
	target, set, ok := s.targetRoles(w, r, h, t, a, roles)
	if !ok {
		return "", "", false
	}
	return target, set[0], true
}

// targetRoles answers the member's current role set, the primary first, and
// applies §3.4 rule 2 over it (025 §10.2 rule 4): a role held as a
// non-primary one counts as much as the primary.
func (s *Server) targetRoles(w http.ResponseWriter, r *http.Request, h store.Humans, t store.Tenant, a rbac.Access, roles map[string]rbac.Role) (string, []string, bool) {
	target := r.PathValue("human_id")
	if !humanIDRe.MatchString(target) {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return "", nil, false
	}
	set, err := s.memberRolesAny(r.Context(), h, t.ID, target)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return "", nil, false
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "member lookup failed")
		return "", nil, false
	}
	if !coversSet(a, roles, set) {
		writeForbidden(w, "", "your role cannot manage a member whose roles are "+strings.Join(set, ", "))
		return "", nil, false
	}
	return target, set, true
}

// memberRolesAny is the member's role set, the primary first, for a
// suspended or lapsed member too (memberRoleAny's reach): such a member holds
// no live role, so its set comes from the member directory. ErrNotFound: not
// a member. A store with neither set answers the primary alone.
func (s *Server) memberRolesAny(ctx context.Context, h store.Humans, tenant, humanID string) ([]string, error) {
	primary, err := s.memberRoleAny(ctx, h, tenant, humanID)
	if err != nil {
		return nil, err
	}
	set, err := h.MemberRoles(ctx, humanID, tenant)
	if err == nil && len(set) > 0 {
		return set, nil
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	if d, ok := h.(store.MemberDirectory); ok {
		ms, err := d.ListMembers(ctx, tenant)
		if err != nil {
			return nil, err
		}
		for _, m := range ms {
			if m.HumanID == humanID && len(m.Roles) > 0 {
				return m.Roles, nil
			}
		}
	}
	return []string{primary}, nil
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
	case errors.Is(err, store.ErrBadRole):
		writeErr(w, http.StatusBadRequest, "bad_role", "the role set is empty, its primary is not in it, or it holds demo_user / channel_guest next to another role")
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
		// NoMail stores the invite without sending its mail (CLE-77780, owner
		// 2026-09-30: no mail goes out on the owner's behalf without a click).
		// The admin then sends it explicitly from the Users pane.
		NoMail bool `json:"no_mail"`
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
	// CLE-77778: the WUI/API admin invite records the signed-in admin as the
	// orderer too (ordered_via stays empty — there is no agent in this path).
	in := store.Invite{TenantID: t.ID, Email: body.Email, Role: role, InvitedBy: a.HumanID,
		ExpiresAt: now.Add(ttl), OrderedBy: a.HumanID}
	switch err := h.PutInvite(r.Context(), in, now); {
	case errors.Is(err, store.ErrUnknownRole):
		writeErr(w, http.StatusBadRequest, "bad_role", "not a role of this tenant")
	case err != nil && strings.Contains(err.Error(), "invite email"):
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invite not stored")
	default:
		email := strings.ToLower(strings.TrimSpace(body.Email))
		mailed := "not_sent"
		if !body.NoMail {
			mailed = s.mailInvite(r, t.ID, email)
		}
		s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("role", role).Str("mail", mailed).Bool("no_mail", body.NoMail).Msg("member.invited")
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
	// CLE-77799: the durable per-person audit row for the Activity log.
	s.recordMemberActivity(r.Context(), store.MemberActivity{TenantID: t.ID, SubjectHum: target, ActorHum: a.HumanID, Kind: "role_changed", Detail: role})
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": t.ID, "human_id": target, "role": role, "roles": []string{role}})
}

// membersMaxRoles bounds one role set in a request body.
const membersMaxRoles = 32

// PUT /v1/members/{human_id}/roles {roles[], primary?, from_roles?} (025
// §10.2 rule 6, data-model §4): sets the member's whole role set. The actor
// must cover the member's current set and every role of the new one (§10.2
// rule 4); the store keeps the last owner and the last admin over sets and
// checks from_roles (409 role_changed). primary "" keeps the current primary
// when the set holds it.
func (s *Server) handleMemberRoles(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersRoles)
	if !ok {
		return
	}
	var body struct {
		Roles     []string `json:"roles"`
		Primary   string   `json:"primary"`
		FromRoles []string `json:"from_roles"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if len(body.Roles) == 0 || len(body.Roles) > membersMaxRoles {
		writeErr(w, http.StatusBadRequest, "bad_role", "roles must name 1..32 roles")
		return
	}
	target, _, ok := s.targetRoles(w, r, h, t, a, roles)
	if !ok {
		return
	}
	set := make([]string, 0, len(body.Roles))
	for _, want := range body.Roles {
		role, ok := grantable(w, a, roles, want, "")
		if !ok {
			return
		}
		set = append(set, role)
	}
	primary := rbac.Legacy(strings.TrimSpace(body.Primary))
	if primary != "" && !slices.Contains(set, primary) {
		writeErr(w, http.StatusBadRequest, "bad_role", "primary "+primary+" is not in roles")
		return
	}
	if err := h.SetMemberRoles(r.Context(), t.ID, target, set, primary, body.FromRoles); err != nil {
		writeMemberErr(w, err)
		return
	}
	got, err := s.memberRolesAny(r.Context(), h, t.ID, target)
	if err != nil || len(got) == 0 {
		s.o.Log.Warn().Err(err).Str("tenant", t.ID).Str("member", target).Msg("member.roles_reread_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "roles written; reload to read them")
		return
	}
	detail := strings.Join(got, ",")
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("member", target).Str("roles", detail).Msg("member.roles_changed")
	// CLE-77799: the durable per-person audit row for the Activity log.
	s.recordMemberActivity(r.Context(), store.MemberActivity{TenantID: t.ID, SubjectHum: target, ActorHum: a.HumanID, Kind: "role_changed", Detail: detail})
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": t.ID, "human_id": target, "role": got[0], "roles": got})
}

// DELETE /v1/members/{human_id}
func (s *Server) handleMemberRemove(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	target, cur, ok := s.targetRole(w, r, h, t, a, roles)
	if !ok || !notSelf(w, a, target) {
		return
	}
	banned, err := s.removeOrBan(r.Context(), h, t.ID, target, cur, a.HumanID)
	if errors.Is(err, store.ErrRealmCopy) {
		// specs/119 8.1: never a leaver without a receipt; the member stays.
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("member", target).Msg("member.receipt_failed")
		writeErr(w, http.StatusServiceUnavailable, "receipt_failed", "the leaver's hours receipt was not taken; the member stays, retry")
		return
	}
	if err != nil {
		writeMemberErr(w, err)
		return
	}
	detail := ""
	if banned {
		detail = "banned"
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("member", target).Bool("banned", banned).Msg("member.removed")
	// CLE-77799: the durable per-person audit row for the Activity log.
	s.recordMemberActivity(r.Context(), store.MemberActivity{TenantID: t.ID, SubjectHum: target, ActorHum: a.HumanID, Kind: "removed", Detail: detail})
	w.WriteHeader(http.StatusNoContent)
}

// removeOrBan removes target. In the demo workspace a demo_user's removal is
// a ban (specs/077 3.6, T016 part B): the store also lists the account and
// address digests of its identities, which the open admission then refuses.
// true = banned. A removal takes the leaver's receipt first (specs/119 8.1
// row 1); a failed copy is store.ErrRealmCopy and nothing is removed. A demo
// stay is synthetic and takes none.
func (s *Server) removeOrBan(ctx context.Context, h store.Humans, tenant, target, role, by string) (bool, error) {
	if b, ok := h.(store.DemoBans); ok && role == rbac.DemoUser && s.o.DemoWorkspace != "" && tenant == s.o.DemoWorkspace {
		return true, b.BanMember(ctx, tenant, target, by, s.o.Now())
	}
	if err := s.copyReceipt(ctx, tenant, target); err != nil {
		return false, err
	}
	return false, h.RemoveMember(ctx, tenant, target)
}

// copyReceipt takes target's receipt of tenant before it leaves (specs/119
// 8.1, 8.2). An act-as clone (specs/054) is synthetic and takes none; so
// does a member id that is no person. A store without the realm copies
// nothing.
func (s *Server) copyReceipt(ctx context.Context, tenant, target string) error {
	c, ok := s.o.Store.(store.RealmReceiptCopier)
	if !ok || !store.RealmPerson(target) {
		return nil
	}
	if cr, ok := s.o.Store.(cloneReader); ok {
		if _, err := cr.Clone(ctx, tenant, target); err == nil {
			return nil
		}
	}
	_, err := c.CopyRealmReceipts(ctx, tenant, target, store.RealmDueRemoved, s.o.Now())
	return err
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
	mux.HandleFunc("GET /v1/audit/clones", s.handleAuditClones)                   // specs/054
	mux.HandleFunc("GET /v1/members/{human_id}/activity", s.handleMemberActivity) // CLE-77799
	mux.HandleFunc("POST /v1/members/invites", s.handleMemberInvite)
	mux.HandleFunc("DELETE /v1/members/invites", s.handleInviteRevoke)
	mux.HandleFunc("PUT /v1/members/{human_id}/role", s.handleMemberRole)
	mux.HandleFunc("PUT /v1/members/{human_id}/roles", s.handleMemberRoles) // 025 §10.2 rule 6
	mux.HandleFunc("DELETE /v1/members/{human_id}", s.handleMemberRemove)
	mux.HandleFunc("POST /v1/members/{human_id}/password-reset", s.handleMemberPasswordReset) // t1 ea0af569
	mux.HandleFunc("GET /v1/members/{human_id}/emails", s.handleSignInEmails)                 // t1 f265541a
	mux.HandleFunc("POST /v1/members/{human_id}/emails", s.handleSignInEmailAdd)              // t1 f265541a
	mux.HandleFunc("DELETE /v1/members/{human_id}/emails", s.handleSignInEmailRemove)         // t1 f265541a
	mux.HandleFunc("OPTIONS /v1/members", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/invites", s.membersPreflight)
	s.routeDemo(mux) // specs/077: the demo membership, GET /v1/demo (404 while off)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}/role", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}/roles", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}/password-reset", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}/emails", s.membersPreflight)
}
