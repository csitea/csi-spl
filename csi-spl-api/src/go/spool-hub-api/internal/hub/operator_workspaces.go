package hub

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Workspace CRUD by the operator workspace (spec 074 phase 1; owner HUM-10,
// t1 aa35699c): one workspace of the instance (tenants.is_operator, rdb 0116;
// Options.OperatorTenant, the cnf, only while no row is flagged - see
// operatorTenant) is the only place to manage the
// others, and "only the admin of the spool-hub could perform any spool-hub
// instance specific changes, like add or remove tenants - he has to be admin,
// not biz owner". So every route below needs a member SESSION whose active
// workspace is the operator workspace AND whose role there is exactly admin.
// The biz_owner, every other role, and the admin of any other workspace get
// 403. These are session routes beside the id-token invite routes of
// operator.go; they share the /v1/operator prefix, not the auth.
//
// Create, rename, settings and billing go through the store calls the shell
// actions use (CreateTenant, SetTenantConfig, SetBillingStatus, PutInvite);
// the list and suspend / archive are store.OperatorWorkspaces (rdb 0115).
// DELETE is soft: suspend + archive; nothing is purged. Every call writes one
// operator_audit row: who, what, when, which workspace.

// tokenWorkspaceSuspended is the 403 token of a suspended workspace's doors.
const tokenWorkspaceSuspended = "workspace_suspended"

// permOperatorAdmin names the grant in an operator 403 body. It is a role
// rule (admin of the operator workspace), not a row of the permission table.
const permOperatorAdmin = "operator.workspaces"

// operatorAuditLimit is how many audit rows GET /v1/operator/workspaces/{id} shows.
const operatorAuditLimit = 50

// opActor is the caller of an operator workspace route. tenant is the
// operator workspace (the caller's active one).
type opActor struct {
	tenant, hum string
	ws          store.OperatorWorkspaces
}

// operatorTenant is the operator workspace in force (spec 074 phase 1b, owner
// D1 "in the db"): the row tenants.is_operator flags (rdb 0116, cached by the
// store), else Options.OperatorTenant (the cnf) while no row is flagged or
// the store keeps no flag; "" = the operator routes are off.
func (s *Server) operatorTenant(ctx context.Context) (string, error) {
	if f, ok := s.o.Store.(store.OperatorFlag); ok {
		id, err := f.OperatorTenant(ctx)
		if err != nil || id != "" {
			return id, err
		}
	}
	return s.o.OperatorTenant, nil
}

// ClaimOperatorWorkspace flags the cnf operator workspace in the database
// while no row is flagged (rdb 0116), once at hub start. It never moves an
// existing flag; it answers the operator workspace now in force.
func (s *Server) ClaimOperatorWorkspace(ctx context.Context) (string, error) {
	f, ok := s.o.Store.(store.OperatorFlag)
	if s.o.OperatorTenant == "" || !ok {
		return s.operatorTenant(ctx)
	}
	if _, err := f.ClaimOperatorTenant(ctx, s.o.OperatorTenant); err != nil {
		return "", err
	}
	return s.operatorTenant(ctx)
}

// operatorActor authorises a workspace route; false = answered.
func (s *Server) operatorActor(w http.ResponseWriter, r *http.Request) (opActor, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return opActor{}, false
	}
	if op == "" {
		writeErr(w, http.StatusNotFound, "not_found", "this hub names no operator workspace")
		return opActor{}, false
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return opActor{}, false
	}
	if hum == "" || t.ID != op {
		writeForbidden(w, permOperatorAdmin, "only an admin of the operator workspace manages workspaces")
		return opActor{}, false
	}
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || a.Role != rbac.Admin {
		writeForbidden(w, permOperatorAdmin, "only an admin of the operator workspace manages workspaces")
		return opActor{}, false
	}
	ws, ok := s.o.Store.(store.OperatorWorkspaces)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no workspace list")
		return opActor{}, false
	}
	return opActor{tenant: t.ID, hum: hum, ws: ws}, true
}

// audit writes one operator_audit row; a failed write is logged, the action stands.
func (s *Server) opAudit(r *http.Request, a opActor, target, action string, detail map[string]any) {
	err := a.ws.AppendOperatorAudit(r.Context(), store.OperatorAudit{At: s.o.Now().UTC(), TenantID: target,
		ActorTenant: a.tenant, ActorHum: a.hum, Action: action, Detail: detail})
	ev := s.o.Log.Info()
	if err != nil {
		ev = s.o.Log.Error().Err(err)
	}
	ev.Str("tenant", target).Str("by", a.hum).Str("action", action).Msg("operator.workspace")
}

type workspaceBody struct {
	ID            string  `json:"id"`
	DisplayName   string  `json:"display_name"`
	BillingStatus string  `json:"billing_status"`
	PlanID        string  `json:"plan_id"`
	CreatedAt     *string `json:"created_at"`
	SuspendedAt   *string `json:"suspended_at"`
	ArchivedAt    *string `json:"archived_at"`
	Operator      bool    `json:"operator"`
}

func rfcOrNil(t time.Time) *string {
	if t.IsZero() {
		return nil
	}
	v := rfc(t)
	return &v
}

// workspaceJSON renders ws; op is the operator workspace (opActor.tenant).
func (s *Server) workspaceJSON(ws store.Workspace, op string) workspaceBody {
	return workspaceBody{ID: ws.ID, DisplayName: ws.DisplayName, BillingStatus: ws.BillingStatus, PlanID: ws.PlanID,
		CreatedAt: rfcOrNil(ws.CreatedAt), SuspendedAt: rfcOrNil(ws.SuspendedAt), ArchivedAt: rfcOrNil(ws.ArchivedAt),
		Operator: ws.ID == op}
}

// GET /v1/operator/workspaces: every workspace of the instance.
func (s *Server) handleOperatorWorkspaces(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	list, err := a.ws.ListWorkspaces(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "workspaces not listed")
		return
	}
	out := make([]workspaceBody, 0, len(list))
	for _, ws := range list {
		out = append(out, s.workspaceJSON(ws, a.tenant))
	}
	s.opAudit(r, a, a.tenant, store.AuditList, map[string]any{"count": len(out)})
	writeJSON(w, http.StatusOK, map[string]any{"workspaces": out})
}

// workspaceTarget reads {id} and the workspace row; false = answered.
func (s *Server) workspaceTarget(w http.ResponseWriter, r *http.Request, a opActor) (store.Workspace, bool) {
	id := r.PathValue("id")
	if !msg.ValidTenantID(id) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "id must be a valid workspace slug")
		return store.Workspace{}, false
	}
	ws, err := a.ws.GetWorkspace(r.Context(), id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "workspace not read")
	default:
		return ws, true
	}
	return store.Workspace{}, false
}

// GET /v1/operator/workspaces/{id}: one workspace and its operator audit trail.
func (s *Server) handleOperatorWorkspace(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	ws, ok := s.workspaceTarget(w, r, a)
	if !ok {
		return
	}
	s.opAudit(r, a, ws.ID, store.AuditRead, nil)
	trail, err := a.ws.OperatorAuditOf(r.Context(), ws.ID, operatorAuditLimit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "audit not read")
		return
	}
	rows := make([]map[string]any, 0, len(trail))
	for _, x := range trail {
		rows = append(rows, map[string]any{"at": rfc(x.At), "actor_tenant": x.ActorTenant,
			"actor_hum": x.ActorHum, "action": x.Action, "detail": x.Detail})
	}
	writeJSON(w, http.StatusOK, map[string]any{"workspace": s.workspaceJSON(ws, a.tenant), "audit": rows})
}

// createWorkspaceReq is POST /v1/operator/workspaces.
type createWorkspaceReq struct {
	ID              string `json:"id"`
	DisplayName     string `json:"display_name"`
	BillingStatus   string `json:"billing_status"`
	RootPubKey      string `json:"root_pubkey"`
	FirstAdminEmail string `json:"first_admin_email"`
	FirstAdminRole  string `json:"first_admin_role"`
	NoMail          bool   `json:"no_mail"`
}

// check validates the request and answers the root key pair to store: the
// caller's public key, or a fresh pair whose private half is answered once.
func (c *createWorkspaceReq) check() (ed25519.PublicKey, ed25519.PrivateKey, string, string) {
	c.FirstAdminEmail = strings.ToLower(strings.TrimSpace(c.FirstAdminEmail))
	if c.BillingStatus == "" {
		c.BillingStatus = billing.StatusManual // as do_spl_tenant_create
	}
	if c.FirstAdminRole == "" {
		c.FirstAdminRole = rbac.Admin
	}
	switch {
	case !msg.ValidTenantID(c.ID):
		return nil, nil, "bad_tenant", "id must be a valid workspace slug (^[a-z0-9][a-z0-9-]{0,31}$, not reserved)"
	case !billing.ValidStatus(c.BillingStatus):
		return nil, nil, "bad_billing_status", "billing_status must be active|grace|unpaid|internal|manual"
	case len(c.DisplayName) > store.MaxTenantDisplayName:
		return nil, nil, "bad_display_name", "display_name is too long"
	case c.FirstAdminEmail != "" && (len(c.FirstAdminEmail) > 320 || !strings.Contains(c.FirstAdminEmail, "@")):
		return nil, nil, "bad_email", "first_admin_email must be an address"
	case !slices.Contains(rbac.RoleIDs, rbac.Legacy(c.FirstAdminRole)):
		return nil, nil, "bad_role", "first_admin_role must be one of " + strings.Join(rbac.RoleIDs, "|")
	}
	if c.RootPubKey == "" {
		pub, priv, err := ed25519.GenerateKey(nil)
		if err != nil {
			return nil, nil, "internal", "root key not generated"
		}
		return pub, priv, "", ""
	}
	pub, err := base64.StdEncoding.DecodeString(c.RootPubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, nil, "bad_root_pubkey", "root_pubkey must be a base64 32-byte ed25519 key"
	}
	return pub, nil, "", ""
}

// POST /v1/operator/workspaces: create a workspace (409 when the id exists),
// optionally invite its first admin. A generated root private key is in the
// 201 body ONCE and is never stored or logged (the shell action's contract).
func (s *Server) handleOperatorWorkspaceCreate(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	var req createWorkspaceReq
	if !decodeMembers(w, r, &req) {
		return
	}
	pub, priv, tok, detail := req.check()
	if tok != "" {
		writeErr(w, http.StatusBadRequest, tok, detail)
		return
	}
	if _, err := a.ws.GetWorkspace(r.Context(), req.ID); err == nil {
		writeErr(w, http.StatusConflict, "exists", "a workspace with that id exists")
		return
	}
	if err := s.o.Store.CreateTenant(r.Context(), store.Tenant{ID: req.ID, RootPubKey: pub, BillingStatus: req.BillingStatus}); err != nil {
		code, tk := http.StatusInternalServerError, "internal"
		if errors.Is(err, store.ErrConflict) {
			code, tk = http.StatusConflict, "exists"
		}
		writeErr(w, code, tk, "workspace not created")
		return
	}
	if req.DisplayName != "" {
		s.setWorkspaceConfig(r, req.ID, store.TenantConfigPatch{DisplayName: &req.DisplayName})
	}
	out := map[string]any{}
	if priv != nil {
		out["root_private_key"] = base64.StdEncoding.EncodeToString(priv)
	}
	if req.FirstAdminEmail != "" {
		out["invite"] = s.inviteFirstAdmin(r, a, req)
	}
	ws, _ := a.ws.GetWorkspace(r.Context(), req.ID)
	out["workspace"] = s.workspaceJSON(ws, a.tenant)
	s.opAudit(r, a, req.ID, store.AuditCreate, map[string]any{"billing_status": req.BillingStatus,
		"display_name": req.DisplayName, "first_admin_email": req.FirstAdminEmail, "key_generated": priv != nil})
	writeJSON(w, http.StatusCreated, out)
}

// setWorkspaceConfig applies a settings patch; the error is logged and answered.
func (s *Server) setWorkspaceConfig(r *http.Request, id string, p store.TenantConfigPatch) error {
	ts, ok := s.o.Store.(store.TenantSettings)
	if !ok {
		return errors.New("store keeps no workspace settings")
	}
	err := ts.SetTenantConfig(r.Context(), id, p)
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", id).Msg("operator.workspace_config")
	}
	return err
}

// inviteFirstAdmin stores (and mails) the invite of the new workspace's first
// member through the same PutInvite path as the members API.
func (s *Server) inviteFirstAdmin(r *http.Request, a opActor, req createWorkspaceReq) map[string]any {
	h, ok := s.o.Store.(store.Humans)
	if !ok {
		return map[string]any{"status": "unsupported"}
	}
	now := s.o.Now().UTC()
	in := store.Invite{TenantID: req.ID, Email: req.FirstAdminEmail, Role: rbac.Legacy(req.FirstAdminRole),
		InvitedBy: a.hum, ExpiresAt: now.Add(inviteTTLDefault)}
	if err := h.PutInvite(r.Context(), in, now); err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", req.ID).Msg("operator.workspace_invite_failed")
		return map[string]any{"status": "not_stored", "email": req.FirstAdminEmail}
	}
	mailed := "not_sent"
	if !req.NoMail {
		mailed = s.mailInvite(r, req.ID, req.FirstAdminEmail)
	}
	return map[string]any{"status": "invited", "email": req.FirstAdminEmail, "role": in.Role,
		"expires_at": rfc(in.ExpiresAt), "mail": mailed}
}

// patchWorkspaceReq is PATCH /v1/operator/workspaces/{id}; an absent field
// keeps its value.
type patchWorkspaceReq struct {
	DisplayName        *string `json:"display_name"`
	BillingStatus      *string `json:"billing_status"`
	Suspended          *bool   `json:"suspended"`
	DefaultLocale      *string `json:"default_locale"`
	TopicArchivePolicy *string `json:"topic_archive_policy"`
}

func (p patchWorkspaceReq) config() (store.TenantConfigPatch, bool) {
	c := store.TenantConfigPatch{DisplayName: p.DisplayName, DefaultLocale: p.DefaultLocale,
		TopicArchivePolicy: p.TopicArchivePolicy}
	return c, c.DisplayName != nil || c.DefaultLocale != nil || c.TopicArchivePolicy != nil
}

// PATCH /v1/operator/workspaces/{id}: rename, billing, settings, suspend /
// resume. The operator workspace cannot suspend itself (409 self).
func (s *Server) handleOperatorWorkspacePatch(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	var req patchWorkspaceReq
	if !decodeMembers(w, r, &req) {
		return
	}
	ws, ok := s.workspaceTarget(w, r, a)
	if !ok || !s.patchWorkspace(w, r, a, ws, req) {
		return
	}
	ws, _ = a.ws.GetWorkspace(r.Context(), ws.ID)
	writeJSON(w, http.StatusOK, map[string]any{"workspace": s.workspaceJSON(ws, a.tenant)})
}

// patchWorkspace applies req to ws and audits each change; false = answered.
func (s *Server) patchWorkspace(w http.ResponseWriter, r *http.Request, a opActor, ws store.Workspace, req patchWorkspaceReq) bool {
	if req.BillingStatus != nil && !billing.ValidStatus(*req.BillingStatus) {
		writeErr(w, http.StatusBadRequest, "bad_billing_status", "billing_status must be active|grace|unpaid|internal|manual")
		return false
	}
	if req.Suspended != nil && *req.Suspended && ws.ID == a.tenant {
		writeErr(w, http.StatusConflict, "self", "the operator workspace cannot suspend itself")
		return false
	}
	if cfg, set := req.config(); set {
		if err := s.setWorkspaceConfig(r, ws.ID, cfg); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_settings", "settings not saved: "+err.Error())
			return false
		}
	}
	if req.BillingStatus != nil {
		if err := s.o.Store.SetBillingStatus(r.Context(), ws.ID, *req.BillingStatus); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "billing status not saved")
			return false
		}
	}
	s.opAudit(r, a, ws.ID, store.AuditUpdate, patchDetail(req))
	if req.Suspended == nil {
		return true
	}
	return s.setWorkspaceState(w, r, a, ws.ID, *req.Suspended, false)
}

// patchDetail is the audit detail of a PATCH: the fields it carried.
func patchDetail(req patchWorkspaceReq) map[string]any {
	d := map[string]any{}
	if req.DisplayName != nil {
		d["display_name"] = *req.DisplayName
	}
	if req.BillingStatus != nil {
		d["billing_status"] = *req.BillingStatus
	}
	if req.Suspended != nil {
		d["suspended"] = *req.Suspended
	}
	if req.DefaultLocale != nil {
		d["default_locale"] = *req.DefaultLocale
	}
	if req.TopicArchivePolicy != nil {
		d["topic_archive_policy"] = *req.TopicArchivePolicy
	}
	return d
}

// setWorkspaceState suspends, resumes or archives one workspace and audits
// it; false = answered.
func (s *Server) setWorkspaceState(w http.ResponseWriter, r *http.Request, a opActor, id string, suspended, archive bool) bool {
	err := a.ws.SetWorkspaceState(r.Context(), id, suspended, archive, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrWorkspaceStateUnavailable):
		writeErr(w, http.StatusServiceUnavailable, "not_migrated", "suspend and archive need rdb 0115 on this database")
		return false
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
		return false
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "workspace state not saved")
		return false
	}
	action := store.AuditResume
	switch {
	case archive:
		action = store.AuditArchive
	case suspended:
		action = store.AuditSuspend
	}
	s.opAudit(r, a, id, action, nil)
	return true
}

// DELETE /v1/operator/workspaces/{id}: a SOFT delete - suspend + archive.
// Every row stays and PATCH {"suspended":false} brings it back. There is no
// hard purge: ?purge is refused (400) rather than ignored.
func (s *Server) handleOperatorWorkspaceDelete(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	if r.URL.Query().Has("purge") {
		writeErr(w, http.StatusBadRequest, "no_purge", "a hard purge is not offered; DELETE archives (soft)")
		return
	}
	ws, ok := s.workspaceTarget(w, r, a)
	if !ok {
		return
	}
	if ws.ID == a.tenant {
		writeErr(w, http.StatusConflict, "self", "the operator workspace cannot archive itself")
		return
	}
	if !s.setWorkspaceState(w, r, a, ws.ID, true, true) {
		return
	}
	ws, _ = a.ws.GetWorkspace(r.Context(), ws.ID)
	writeJSON(w, http.StatusOK, map[string]any{"workspace": s.workspaceJSON(ws, a.tenant)})
}

func (s *Server) operatorWorkspacesPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeOperatorWorkspaces(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/workspaces", s.handleOperatorWorkspaces)
	mux.HandleFunc("POST /v1/operator/workspaces", s.handleOperatorWorkspaceCreate)
	mux.HandleFunc("GET /v1/operator/workspaces/{id}", s.handleOperatorWorkspace)
	mux.HandleFunc("PATCH /v1/operator/workspaces/{id}", s.handleOperatorWorkspacePatch)
	mux.HandleFunc("DELETE /v1/operator/workspaces/{id}", s.handleOperatorWorkspaceDelete)
	mux.HandleFunc("OPTIONS /v1/operator/workspaces", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/workspaces/{id}", s.operatorWorkspacesPreflight)
}
