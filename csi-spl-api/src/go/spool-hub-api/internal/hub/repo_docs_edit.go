package hub

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/repodocs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Editable Repo Docs (spec 075 repo-edit §10 API; task T08): a member, or an
// agent for its requester, saves a repo doc to the env's docs bucket as an
// overlay and queues its push; the worker (repodocs.Worker, T10) pushes it.
//
//	PUT  /v1/docs/{path}                 save (If-Match: <base blob>; agent: X-Spool-Requester)
//	POST /v1/docs/author-notice          the member's consent to their published identity (§4.2)
//	GET  /v1/docs/edits?mine=1|path=     the workspace's edits, newest first
//	POST /v1/docs/edits/{id}/retry       a failed edit back to the queue
//	GET  /v1/docs/edits/{id}/conflict    {base, theirs, mine} of a conflict
//
// GET /v1/docs/{path} (docs.go) serves the newest live overlay, and
// tree.json gains the overlay-only paths and an editable flag per file.
// Options.RepoEdit nil (cnf env.docs.repo_edit.enabled false), no docs
// bucket, or a store without the queue: every route here 404s and the read
// route serves the bucket as before.

// MaxRepoDoc caps one saved doc (spec §5.1: the workspace docs cap).
const MaxRepoDoc = MaxWorkspaceDoc

// Headers of the edit routes.
const (
	RequesterHeader = "X-Spool-Requester" // an agent's requester (§4.3)
	DocBaseHeader   = "X-Spool-Doc-Base"  // the blob a served text is based on
	DocEditHeader   = "X-Spool-Doc-Edit"  // the edit a served overlay is
)

// RepoEdit is cnf env.docs.repo_edit as the routes read it (config.Hub
// DocsEdit*). Repo reads master for the conflict view and for a base saved
// against a head newer than the published tree; nil = neither.
type RepoEdit struct {
	Env               string
	Deny              []string
	BlockedWorkspaces []string
	CoalesceAfter     time.Duration
	CoalesceMax       time.Duration
	MinMemberAge      time.Duration
	RateMemberHour    int
	RateAgentHour     int
	RateWorkspaceDay  int
	RateEnvDay        int
	Repo              RepoReader

	once   sync.Once
	policy *repodocs.Policy
}

func (re *RepoEdit) editable(p string, tree map[string]bool) (bool, string) {
	re.once.Do(func() { re.policy = repodocs.NewPolicy(re.Deny) })
	return re.policy.Editable(p, tree)
}

// RepoReader is the GitHub side the routes read (github.Client).
type RepoReader interface {
	HeadBlob(ctx context.Context, path string) (github.Head, error)
	Blob(ctx context.Context, sha string) ([]byte, error)
}

var _ RepoReader = (*github.Client)(nil)

// repoDocStore is the store the routes need (store.Postgres; the memory
// store has no queue, so a hub on it keeps the routes off).
type repoDocStore interface {
	InsertRepoDocEdit(ctx context.Context, e store.RepoDocEdit, coalesceAfter, coalesceMax time.Duration, now time.Time) (store.RepoDocEdit, []string, error)
	GetRepoDocEdit(ctx context.Context, tenant, editID string) (store.RepoDocEdit, error)
	ListRepoDocEdits(ctx context.Context, tenant string, f store.RepoDocEditFilter) ([]store.RepoDocEdit, error)
	RetryRepoDocEdit(ctx context.Context, tenant, editID string, now time.Time) (store.RepoDocEdit, error)
	RepoDocEditRates(ctx context.Context, tenant, humanID, agentID string, now time.Time) (store.RepoDocRates, error)
	RepoDocEditsEnvDay(ctx context.Context, since time.Time) (int, error)
	GetRepoDocAuthor(ctx context.Context, tenant, humanID string) (store.RepoDocAuthor, error)
	AckRepoDocAuthorNotice(ctx context.Context, tenant, humanID, gitName, gitEmail string, now time.Time) error
	HasRepoDocAuthorNotice(ctx context.Context, tenant, humanID, gitName, gitEmail string) (bool, error)
	LookupRepoDocKnownAuthor(ctx context.Context, email string) (store.RepoDocKnownAuthor, error)
	RepoDocPerson(ctx context.Context, tenant, humanID string) (store.RepoDocPerson, error)
	RepoDocSeatHuman(ctx context.Context, tenant, box string) (string, error)
	RepoDocOverlays(ctx context.Context, path string) ([]store.RepoDocEdit, error)
}

var _ repoDocStore = (*store.Postgres)(nil)

// repoEdit is the queue store when editing is on.
func (s *Server) repoEdit() (repoDocStore, bool) {
	if s.o.RepoEdit == nil || s.o.Docs == nil {
		return nil, false
	}
	st, ok := s.o.Store.(repoDocStore)
	return st, ok
}

func (s *Server) routeRepoDocsEdit(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/docs/{path...}", s.handlePutRepoDoc)
	mux.HandleFunc("POST /v1/docs/author-notice", s.handleRepoDocAuthorNotice)
	mux.HandleFunc("GET /v1/docs/edits", s.handleListRepoDocEdits)
	mux.HandleFunc("POST /v1/docs/edits/{id}/retry", s.handleRetryRepoDocEdit)
	mux.HandleFunc("GET /v1/docs/edits/{id}/conflict", s.handleRepoDocConflict)
}

// docsPreflight answers OPTIONS on every /v1/docs/ route.
func (s *Server) docsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT, POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, If-Match, X-Locale, "+RequesterHeader)
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// repoDocCaller is who calls an edit route: the member (or the agent's
// requester) and, for an agent, its seat.
type repoDocCaller struct {
	t     store.Tenant
	hum   string
	agent string
}

// Who an agent may name, and whether a route needs a requester.
const (
	callerMember    = iota // a member session only
	callerRequester        // a member, or an agent naming a valid requester (§4.3)
	callerSeat             // a member, or an agent as itself
)

// repoDocCaller resolves the caller of an edit route, or writes the refusal.
// perm is what a member's role must hold. The door and the permission come
// before the switch: a demo_user (no docs.write) is refused 403 whether
// editing is on or off (TestDemoRouteWalk), and a caller who may edit gets
// 404 repo_edit_off while it is off.
func (s *Server) repoDocCaller(w http.ResponseWriter, r *http.Request, perm string, mode int) (repoDocCaller, repoDocStore, bool) {
	s.allowOrigin(w, r)
	var c repoDocCaller
	st, on := s.repoEdit()
	off := func() (repoDocCaller, repoDocStore, bool) {
		writeErr(w, http.StatusNotFound, "repo_edit_off", "editing repo docs is off on this hub")
		return c, nil, false
	}
	if _, box, _, ok := s.bearerAny(r); ok && box != WUIBox {
		if mode == callerMember {
			writeForbidden(w, perm, "this route needs a signed-in member session")
			return c, nil, false
		}
		t, seat, ok := s.tokenTenant(w, r)
		if !ok {
			return c, nil, false
		}
		if !agentDocs(rbac.DocsWrite) {
			writeForbidden(w, rbac.DocsWrite, "agents are not granted "+rbac.DocsWrite)
			return c, nil, false
		}
		c = repoDocCaller{t: t, agent: seat}
		if !on {
			return off()
		}
		if mode == callerRequester {
			hum, err := repodocs.CheckRequester(r.Context(), repoDocDir{s, st}, t.ID, seat, r.Header.Get(RequesterHeader))
			if !s.repoDocRefused(w, err) {
				return c, nil, false
			}
			c.hum = hum
		}
		return c, st, true
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return c, nil, false
	}
	if hum == "" {
		writeForbidden(w, perm, "repo docs edits need a signed-in member session or an agent token")
		return c, nil, false
	}
	if !s.permit(w, r, t.ID, hum, perm) {
		return c, nil, false
	}
	if !on {
		return off()
	}
	return repoDocCaller{t: t, hum: hum}, st, true
}

// repoDocRefused writes err (a repodocs.Refusal, else a 503) and reports
// whether there was none.
func (s *Server) repoDocRefused(w http.ResponseWriter, err error) bool {
	if err == nil {
		return true
	}
	var ref *repodocs.Refusal
	if errors.As(err, &ref) {
		writeErr(w, ref.Status, ref.Reason, ref.Detail)
		return false
	}
	writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
	return false
}

// repoDocDir is repodocs.Directory over the store and the hub's RBAC.
type repoDocDir struct {
	s  *Server
	st repoDocStore
}

func (d repoDocDir) Person(ctx context.Context, tenant, humanID string) (repodocs.Person, error) {
	p, err := d.st.RepoDocPerson(ctx, tenant, humanID)
	if errors.Is(err, store.ErrNotFound) {
		return repodocs.Person{HumanID: humanID}, nil
	}
	if err != nil {
		return repodocs.Person{}, err
	}
	_, aerr := d.s.access(ctx, humanID, tenant)
	return repodocs.Person{HumanID: humanID, Member: aerr == nil && !p.MemberSince.IsZero(),
		DisplayName: p.DisplayName, Email: p.Email, EmailVerified: p.EmailVerified}, nil
}

func (d repoDocDir) Mapping(ctx context.Context, tenant, humanID string) (repodocs.Mapping, bool, error) {
	a, err := d.st.GetRepoDocAuthor(ctx, tenant, humanID)
	if errors.Is(err, store.ErrNotFound) {
		return repodocs.Mapping{}, false, nil
	}
	if err != nil {
		return repodocs.Mapping{}, false, err
	}
	return repodocs.Mapping{GitName: a.GitName, GitEmail: a.GitEmail, Verified: !a.VerifiedAt.IsZero(),
		AllowAgents: a.AllowAgents}, true, nil
}

func (d repoDocDir) KnownAuthor(ctx context.Context, email string) (string, string, bool, error) {
	a, err := d.st.LookupRepoDocKnownAuthor(ctx, email)
	if errors.Is(err, store.ErrNotFound) {
		return "", "", false, nil
	}
	return a.GitName, a.GitEmail, err == nil, err
}

func (d repoDocDir) HasNotice(ctx context.Context, tenant, humanID, gitName, gitEmail string) (bool, error) {
	return d.st.HasRepoDocAuthorNotice(ctx, tenant, humanID, gitName, gitEmail)
}

func (d repoDocDir) Can(ctx context.Context, tenant, humanID, perm string) (bool, error) {
	a, err := d.s.access(ctx, humanID, tenant)
	return err == nil && a.Can(perm), nil
}

func (d repoDocDir) SeatHuman(ctx context.Context, tenant, seat string) (string, error) {
	return d.st.RepoDocSeatHuman(ctx, tenant, seat)
}

// docsTree is the published tree.json: path -> git blob sha (spec §8; the
// publish writes blob per file, T03). A bucket with no index is empty.
func (s *Server) docsTree(ctx context.Context) (map[string]string, error) {
	out := map[string]string{}
	rc, err := s.o.Docs.Get(ctx, DocsIndex)
	if errors.Is(err, blob.ErrNotFound) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	var idx struct {
		Files []struct {
			Path string `json:"path"`
			Blob string `json:"blob"`
		} `json:"files"`
	}
	if err := json.NewDecoder(io.LimitReader(rc, 16<<20)).Decode(&idx); err != nil {
		return nil, err
	}
	for _, f := range idx.Files {
		out[f.Path] = f.Blob
	}
	return out, nil
}

func treePaths(tree map[string]string) map[string]bool {
	out := make(map[string]bool, len(tree))
	for p := range tree {
		out[p] = true
	}
	return out
}

// liveOverlay is the edit whose overlay GET /v1/docs/{path} serves to hum of
// tenant: the newest of the path while queued, pushing or pushed; a conflict
// only to its own editor (or requester), whose text it is. nil: the main key.
func liveOverlay(rows []store.RepoDocEdit, tenant, hum string) *store.RepoDocEdit {
	if len(rows) == 0 {
		return nil
	}
	e := rows[0]
	switch e.Status {
	case store.RepoDocQueued, store.RepoDocPushing, store.RepoDocPushed:
		return &e
	case store.RepoDocConflict:
		if e.TenantID == tenant && e.HumanID == hum {
			return &e
		}
	}
	return nil
}

// pushedBase is the blob master holds for a pushed edit that was not merged:
// its own text. A re-save of that text bases on it, not on the blob from
// before the push, whose merge would add the pushed lines a second time and
// conflict with master (075 repo-edit, the T13 proof on dev).
func pushedBase(e store.RepoDocEdit, r io.Reader) (string, bool) {
	if e.Status != store.RepoDocPushed || e.MergedWith != "" {
		return "", false
	}
	b, err := io.ReadAll(io.LimitReader(r, MaxRepoDoc+1))
	if err != nil || len(b) > MaxRepoDoc {
		return "", false
	}
	return repodocs.GitBlobSHA(b), true
}

// serveRepoDoc serves p with the edit headers: its live overlay, else the
// published key. ok false: neither exists (the caller answers 404).
func (s *Server) serveRepoDoc(w http.ResponseWriter, r *http.Request, st repoDocStore, tenant, hum, p string) (bool, error) {
	ctx := r.Context()
	rows, err := st.RepoDocOverlays(ctx, p)
	if err != nil {
		return false, err
	}
	key, base, edit := p, "", ""
	if e := liveOverlay(rows, tenant, hum); e != nil {
		if rc, err := s.o.Docs.Get(ctx, e.OverlayKey); err == nil {
			key, base, edit = e.OverlayKey, e.BaseBlob, e.EditID
			if pb, ok := pushedBase(*e, rc); ok {
				base = pb
			}
			rc.Close()
		}
	}
	if edit == "" {
		tree, err := s.docsTree(ctx)
		if err != nil {
			return false, err
		}
		base = tree[p]
	}
	rc, err := s.o.Docs.Get(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer rc.Close()
	h := w.Header()
	docHeaders(h, "text/markdown; charset=utf-8")
	h.Set(DocBaseHeader, base)
	if edit != "" {
		h.Set(DocEditHeader, edit)
	}
	h.Set("Access-Control-Expose-Headers", DocBaseHeader+", "+DocEditHeader)
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
	return true, nil
}

// serveRepoDocsTree is tree.json with an "editable" flag on every file,
// "overlay" on the files a live edit serves, and the overlay-only (new)
// paths appended (spec §7 step 2). Every other field passes through.
func (s *Server) serveRepoDocsTree(w http.ResponseWriter, r *http.Request, st repoDocStore, tenant, hum string) error {
	ctx := r.Context()
	var idx map[string]any
	rc, err := s.o.Docs.Get(ctx, DocsIndex)
	switch {
	case errors.Is(err, blob.ErrNotFound):
		idx = map[string]any{}
	case err != nil:
		return err
	default:
		err = json.NewDecoder(io.LimitReader(rc, 16<<20)).Decode(&idx)
		rc.Close()
		if err != nil {
			return err
		}
	}
	files, _ := idx["files"].([]any)
	tree := map[string]bool{}
	for _, f := range files {
		if m, ok := f.(map[string]any); ok {
			if p, ok := m["path"].(string); ok {
				tree[p] = true
			}
		}
	}
	rows, err := st.RepoDocOverlays(ctx, "")
	if err != nil {
		return err
	}
	live := map[string]bool{}
	for _, e := range rows {
		if liveOverlay([]store.RepoDocEdit{e}, tenant, hum) != nil {
			live[e.Path] = true
		}
	}
	for _, f := range files {
		if m, ok := f.(map[string]any); ok {
			p, _ := m["path"].(string)
			m["editable"], _ = s.o.RepoEdit.editable(p, tree)
			if live[p] {
				m["overlay"] = true
			}
		}
	}
	for _, e := range rows {
		if live[e.Path] && !tree[e.Path] {
			ok, _ := s.o.RepoEdit.editable(e.Path, tree)
			files = append(files, map[string]any{"path": e.Path, "title": "", "overlay": true, "editable": ok})
		}
	}
	if files == nil {
		files = []any{}
	}
	idx["files"] = files
	docHeaders(w.Header(), "application/json; charset=utf-8")
	writeJSON(w, http.StatusOK, idx)
	return nil
}

var blobSHARe = regexp.MustCompile(`^[0-9a-f]{40}$`)

// docBaseOf is the If-Match base blob, quotes and a weak prefix dropped.
func docBaseOf(r *http.Request) string {
	v := strings.TrimSpace(r.Header.Get("If-Match"))
	v = strings.TrimPrefix(v, "W/")
	return strings.ToLower(strings.Trim(v, `"`))
}

// knownBase reports whether base is a text p may be saved against: the
// published blob, "" for a path not published yet, the base of the path's
// live overlay, the blob of a pushed overlay's text (pushedBase), or master's
// head blob (a conflict resolved against head).
func (s *Server) knownBase(ctx context.Context, st repoDocStore, p, base string, tree map[string]string) (bool, error) {
	pub, published := tree[p]
	switch {
	case base == "":
		return !published, nil
	case !blobSHARe.MatchString(base):
		return false, nil
	case published && base == pub:
		return true, nil
	}
	rows, err := st.RepoDocOverlays(ctx, p)
	if err != nil {
		return false, err
	}
	for _, e := range rows {
		if e.BaseBlob == base {
			return true, nil
		}
		if e.Status != store.RepoDocPushed || e.MergedWith != "" {
			continue
		}
		if rc, err := s.o.Docs.Get(ctx, e.OverlayKey); err == nil {
			pb, ok := pushedBase(e, rc)
			rc.Close()
			if ok && pb == base {
				return true, nil
			}
		}
	}
	if s.o.RepoEdit.Repo == nil {
		return false, nil
	}
	head, err := s.o.RepoEdit.Repo.HeadBlob(ctx, p)
	if err != nil {
		return false, err
	}
	return head.Blob == base, nil
}

// readDocsKey is one docs bucket object; nil when absent.
func (s *Server) readDocsKey(ctx context.Context, key string) ([]byte, error) {
	rc, err := s.o.Docs.Get(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(io.LimitReader(rc, 2*MaxRepoDoc))
}

// RepoDocAuthorBody is the identity a save commits under (the 428 answer,
// and the consent's body).
type RepoDocAuthorBody struct {
	GitName      string `json:"git_name"`
	GitEmail     string `json:"git_email"`
	AuthorSource string `json:"author_source,omitempty"`
}

type repoDocNoticeBody struct {
	Error  string `json:"error"`
	Detail string `json:"detail"`
	RepoDocAuthorBody
}

// RepoDocSaved is the PUT answer.
type RepoDocSaved struct {
	EditID     string            `json:"edit_id"`
	Status     string            `json:"status"`
	Path       string            `json:"path"`
	Base       string            `json:"base"`
	Superseded []string          `json:"superseded"`
	Author     RepoDocAuthorBody `json:"author"`
}

type repoDocRejected struct {
	Error  string         `json:"error"`
	Detail string         `json:"detail"`
	Hits   []repodocs.Hit `json:"hits"`
}

func (s *Server) handlePutRepoDoc(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("path")
	c, st, ok := s.repoDocCaller(w, r, rbac.DocsWrite, callerRequester)
	if !ok {
		return
	}
	tree, data, ok := s.repoDocSaveInput(w, r, c, p)
	if !ok {
		return
	}
	author, ok := s.repoDocSaveAuthor(w, r, st, c)
	if !ok {
		return
	}
	base := docBaseOf(r)
	if !s.repoDocSaveChecks(w, r, st, c, p, base, tree, data) {
		return
	}
	if !s.repoDocSaveConsented(w, r, st, c, author) {
		return
	}
	s.repoDocSaveWrite(w, r, st, c, p, base, data, author)
}

// repoDocSaveInput is the published tree and the body of a save to p, after
// the operator brake, the path policy (§5.2) and the size cap.
func (s *Server) repoDocSaveInput(w http.ResponseWriter, r *http.Request, c repoDocCaller, p string) (map[string]string, []byte, bool) {
	if slices.Contains(s.o.RepoEdit.BlockedWorkspaces, c.t.ID) {
		writeErr(w, http.StatusForbidden, "workspace_blocked", "saves from this workspace are blocked by the operator")
		return nil, nil, false
	}
	tree, err := s.docsTree(r.Context())
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "docs store unavailable", err)
		return nil, nil, false
	}
	if ok, why := s.o.RepoEdit.editable(p, treePaths(tree)); !ok {
		writeErr(w, http.StatusForbidden, "path_denied", why)
		return nil, nil, false
	}
	data, err := readAllCapped(w, r, MaxRepoDoc)
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("a doc is at most %d bytes", MaxRepoDoc))
		return nil, nil, false
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_body", "the doc body did not arrive")
		return nil, nil, false
	}
	return tree, data, true
}

// repoDocSaveAuthor is the identity the save commits under (§4.1), once the
// author has been a member for min_member_age (§5.1).
func (s *Server) repoDocSaveAuthor(w http.ResponseWriter, r *http.Request, st repoDocStore, c repoDocCaller) (repodocs.Author, bool) {
	ctx, re := r.Context(), s.o.RepoEdit
	author, err := repodocs.ResolveAuthor(ctx, repoDocDir{s, st}, c.t.ID, c.hum)
	if !s.repoDocRefused(w, err) {
		return author, false
	}
	if re.MinMemberAge > 0 {
		pp, err := st.RepoDocPerson(ctx, c.t.ID, c.hum)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
			return author, false
		}
		if pp.MemberSince.IsZero() || s.o.Now().Sub(pp.MemberSince) < re.MinMemberAge {
			writeErr(w, http.StatusForbidden, "member_too_new",
				fmt.Sprintf("a member saves repo docs after %s in the workspace", re.MinMemberAge))
			return author, false
		}
	}
	return author, true
}

// repoDocSaveChecks are the base (409), the text gates on the new lines
// (422) and the rate caps (429).
func (s *Server) repoDocSaveChecks(w http.ResponseWriter, r *http.Request, st repoDocStore, c repoDocCaller, p, base string, tree map[string]string, data []byte) bool {
	ctx := r.Context()
	if ok, err := s.knownBase(ctx, st, p, base, tree); err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the base of this doc could not be checked", err)
		return false
	} else if !ok {
		writeErr(w, http.StatusConflict, "base_unknown", "If-Match must name the blob the editor opened (the doc's "+DocBaseHeader+")")
		return false
	}
	old, err := s.readDocsKey(ctx, p)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "docs store unavailable", err)
		return false
	}
	if hits := repodocs.Gate(old, data); len(hits) > 0 {
		writeJSON(w, http.StatusUnprocessableEntity, repoDocRejected{Error: "rejected_text",
			Detail: fmt.Sprintf("%s rule %q on line %d", hits[0].Kind, hits[0].Rule, hits[0].Line), Hits: hits})
		return false
	}
	if why, err := s.repoDocRateLimited(ctx, st, c, s.o.Now()); err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
		return false
	} else if why != "" {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", why)
		return false
	}
	return true
}

// repoDocSaveConsented answers 428 author_notice_required (§4.2) while the
// author has not consented to this identity; nothing is written before.
func (s *Server) repoDocSaveConsented(w http.ResponseWriter, r *http.Request, st repoDocStore, c repoDocCaller, author repodocs.Author) bool {
	need, err := repodocs.NeedsNotice(r.Context(), repoDocDir{s, st}, c.t.ID, c.hum, author)
	if !s.repoDocRefused(w, err) {
		return false
	}
	if !need {
		return true
	}
	detail := "confirm the published author identity once (POST /v1/docs/author-notice), then save again"
	if c.agent != "" {
		detail = "the requester confirms the published author identity once in Docs -> My edits, then the agent saves again"
	}
	writeJSON(w, http.StatusPreconditionRequired, repoDocNoticeBody{Error: repodocs.ReasonAuthorNoticeRequired,
		Detail: detail, RepoDocAuthorBody: RepoDocAuthorBody{author.Name, author.Email, author.Source}})
	return false
}

// repoDocSaveWrite writes the overlay, then queues the row (§3: a 200 means
// both); a row that fails after the overlay leaves an orphan the worker's
// 30-day sweep drops.
func (s *Server) repoDocSaveWrite(w http.ResponseWriter, r *http.Request, st repoDocStore, c repoDocCaller, p, base string, data []byte, author repodocs.Author) {
	re := s.o.RepoEdit
	id := uuid.NewString()
	key := repodocs.OverlayPrefix + p + "/" + id + ".md"
	ctx := context.WithoutCancel(r.Context()) // a save the client left still lands whole
	if _, err := s.o.Docs.PutReader(ctx, key, bytes.NewReader(data)); err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "docs store unavailable", err)
		return
	}
	sum := sha256.Sum256(data)
	kind := "member"
	if c.agent != "" {
		kind = "agent"
	}
	row, superseded, err := st.InsertRepoDocEdit(ctx, store.RepoDocEdit{EditID: id, TenantID: c.t.ID, HumanID: c.hum,
		ActorKind: kind, AgentID: c.agent, Path: p, BaseBlob: base, OverlayKey: key, TextSHA256: hex.EncodeToString(sum[:]),
		AuthorName: author.Name, AuthorEmail: author.Email, AuthorSource: author.Source}, re.CoalesceAfter, re.CoalesceMax, s.o.Now())
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs queue unavailable", err)
		return
	}
	s.o.Log.Info().Str("audit", "repo_doc.save").Str("tenant", c.t.ID).Str("human", c.hum).Str("agent", c.agent).
		Str("path", p).Str("edit_id", id).Str("base", base).Strs("superseded", superseded).Msg("repo doc saved")
	if superseded == nil {
		superseded = []string{}
	}
	writeJSON(w, http.StatusOK, RepoDocSaved{EditID: row.EditID, Status: row.Status, Path: p, Base: base,
		Superseded: superseded, Author: RepoDocAuthorBody{author.Name, author.Email, author.Source}})
}

// repoDocRateLimited names the first cap of spec §5.1 a save would pass, ""
// for none: the member's (an agent's edits count to the requester) and the
// agent's per hour, the workspace's and the env's per day. 0 = no cap.
func (s *Server) repoDocRateLimited(ctx context.Context, st repoDocStore, c repoDocCaller, now time.Time) (string, error) {
	re := s.o.RepoEdit
	rt, err := st.RepoDocEditRates(ctx, c.t.ID, c.hum, c.agent, now)
	if err != nil {
		return "", err
	}
	switch {
	case re.RateMemberHour > 0 && rt.MemberHour >= re.RateMemberHour:
		return fmt.Sprintf("member: %d saves per hour", re.RateMemberHour), nil
	case c.agent != "" && re.RateAgentHour > 0 && rt.AgentHour >= re.RateAgentHour:
		return fmt.Sprintf("agent: %d saves per hour", re.RateAgentHour), nil
	case re.RateWorkspaceDay > 0 && rt.WorkspaceDay >= re.RateWorkspaceDay:
		return fmt.Sprintf("workspace: %d saves per day", re.RateWorkspaceDay), nil
	}
	if re.RateEnvDay > 0 {
		n, err := st.RepoDocEditsEnvDay(ctx, now.Add(-24*time.Hour))
		if err != nil {
			return "", err
		}
		if n >= re.RateEnvDay {
			return fmt.Sprintf("env: %d saves per day", re.RateEnvDay), nil
		}
	}
	return "", nil
}

func (s *Server) handleRepoDocAuthorNotice(w http.ResponseWriter, r *http.Request) {
	c, st, ok := s.repoDocCaller(w, r, rbac.DocsWrite, callerMember)
	if !ok {
		return
	}
	raw, err := readAllCapped(w, r, 4<<10)
	var in RepoDocAuthorBody
	if err != nil || json.Unmarshal(raw, &in) != nil || in.GitName == "" || in.GitEmail == "" {
		writeErr(w, http.StatusBadRequest, "bad_body", `the body is {"git_name", "git_email"}: the identity the notice showed`)
		return
	}
	ctx := r.Context()
	author, err := repodocs.ResolveAuthor(ctx, repoDocDir{s, st}, c.t.ID, c.hum)
	if !s.repoDocRefused(w, err) {
		return
	}
	if in.GitName != author.Name || in.GitEmail != author.Email {
		writeJSON(w, http.StatusConflict, repoDocNoticeBody{Error: "author_changed",
			Detail:            "the identity a save publishes is not the one confirmed; show the notice again",
			RepoDocAuthorBody: RepoDocAuthorBody{author.Name, author.Email, author.Source}})
		return
	}
	if err := st.AckRepoDocAuthorNotice(ctx, c.t.ID, c.hum, author.Name, author.Email, s.o.Now()); err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
		return
	}
	s.o.Log.Info().Str("audit", "repo_doc.author_notice").Str("tenant", c.t.ID).Str("human", c.hum).
		Str("author_source", author.Source).Msg("repo doc author notice acknowledged")
	w.WriteHeader(http.StatusNoContent)
}

// RepoDocEditView is one edit as the edits routes answer it.
type RepoDocEditView struct {
	EditID       string    `json:"edit_id"`
	Path         string    `json:"path"`
	Status       string    `json:"status"`
	HumanID      string    `json:"human_id"`
	ActorKind    string    `json:"actor_kind"`
	AgentID      string    `json:"agent_id,omitempty"`
	Base         string    `json:"base"`
	GitName      string    `json:"git_name"`
	GitEmail     string    `json:"git_email"`
	AuthorSource string    `json:"author_source"`
	Tries        int       `json:"tries"`
	LastError    string    `json:"last_error,omitempty"`
	CommitSHA    string    `json:"commit_sha,omitempty"`
	MergedWith   string    `json:"merged_with,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

func repoDocView(e store.RepoDocEdit) RepoDocEditView {
	return RepoDocEditView{EditID: e.EditID, Path: e.Path, Status: e.Status, HumanID: e.HumanID, ActorKind: e.ActorKind,
		AgentID: e.AgentID, Base: e.BaseBlob, GitName: e.AuthorName, GitEmail: e.AuthorEmail, AuthorSource: e.AuthorSource,
		Tries: e.Tries, LastError: e.LastError, CommitSHA: e.CommitSHA, MergedWith: e.MergedWith,
		CreatedAt: e.CreatedAt, UpdatedAt: e.UpdatedAt}
}

// RepoDocEdits is GET /v1/docs/edits.
type RepoDocEdits struct {
	Edits []RepoDocEditView `json:"edits"`
}

func (s *Server) handleListRepoDocEdits(w http.ResponseWriter, r *http.Request) {
	c, st, ok := s.repoDocCaller(w, r, rbac.DocsRead, callerMember)
	if !ok {
		return
	}
	q := r.URL.Query()
	f := store.RepoDocEditFilter{Path: q.Get("path")}
	if q.Get("mine") == "1" {
		f.HumanID = c.hum
	}
	if f.HumanID == "" && f.Path == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "name mine=1 or path=<doc>")
		return
	}
	rows, err := st.ListRepoDocEdits(r.Context(), c.t.ID, f)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
		return
	}
	out := RepoDocEdits{Edits: make([]RepoDocEditView, 0, len(rows))}
	for _, e := range rows {
		out.Edits = append(out.Edits, repoDocView(e))
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// repoDocEdit is the caller's workspace's edit {id}, or the 404 written.
func (s *Server) repoDocEdit(w http.ResponseWriter, r *http.Request, st repoDocStore, c repoDocCaller) (store.RepoDocEdit, bool) {
	id := r.PathValue("id")
	if _, err := uuid.Parse(id); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such edit")
		return store.RepoDocEdit{}, false
	}
	e, err := st.GetRepoDocEdit(r.Context(), c.t.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such edit")
		return e, false
	}
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
		return e, false
	}
	return e, true
}

func (s *Server) handleRetryRepoDocEdit(w http.ResponseWriter, r *http.Request) {
	c, st, ok := s.repoDocCaller(w, r, rbac.DocsWrite, callerSeat)
	if !ok {
		return
	}
	e, ok := s.repoDocEdit(w, r, st, c)
	if !ok {
		return
	}
	mine := (c.agent == "" && c.hum == e.HumanID) || (c.agent != "" && c.agent == e.AgentID)
	if !mine && (c.agent != "" || !s.allowed(r.Context(), c.hum, c.t.ID, rbac.TenantSettings)) {
		writeForbidden(w, rbac.TenantSettings, "only the editor, the requester or an admin retries an edit")
		return
	}
	row, err := st.RetryRepoDocEdit(r.Context(), c.t.ID, e.EditID, s.o.Now())
	switch {
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "not_failed", "only a failed edit is retried; this one is "+e.Status)
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such edit")
		return
	case err != nil:
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "repo docs store unavailable", err)
		return
	}
	writeJSON(w, http.StatusAccepted, repoDocView(row))
}

// RepoDocConflict is GET .../conflict: the three texts of the merge that
// failed. Saving the resolution sends If-Match: HeadBlob.
type RepoDocConflict struct {
	EditID     string `json:"edit_id"`
	Path       string `json:"path"`
	Base       string `json:"base"`
	Theirs     string `json:"theirs"`
	Mine       string `json:"mine"`
	BaseBlob   string `json:"base_blob"`
	HeadBlob   string `json:"head_blob"`
	HeadCommit string `json:"head_commit"`
	Reason     string `json:"reason"`
}

func (s *Server) handleRepoDocConflict(w http.ResponseWriter, r *http.Request) {
	c, st, ok := s.repoDocCaller(w, r, rbac.DocsRead, callerMember)
	if !ok {
		return
	}
	e, ok := s.repoDocEdit(w, r, st, c)
	if !ok {
		return
	}
	if e.HumanID != c.hum {
		writeForbidden(w, rbac.DocsWrite, "only the editor or the requester sees a conflict")
		return
	}
	if e.Status != store.RepoDocConflict {
		writeErr(w, http.StatusConflict, "not_conflict", "this edit is "+e.Status)
		return
	}
	repo := s.o.RepoEdit.Repo
	if repo == nil {
		writeErr(w, http.StatusServiceUnavailable, "github_off", "this hub does not read the repository")
		return
	}
	ctx := r.Context()
	out := RepoDocConflict{EditID: e.EditID, Path: e.Path, BaseBlob: e.BaseBlob, Reason: e.LastError}
	var base, theirs []byte
	head, err := repo.HeadBlob(ctx, e.Path)
	if err == nil && e.BaseBlob != "" {
		base, err = repo.Blob(ctx, e.BaseBlob)
	}
	if err == nil && head.Blob != "" {
		theirs, err = repo.Blob(ctx, head.Blob)
	}
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "github", "the repository could not be read", err)
		return
	}
	mine, err := s.readDocsKey(ctx, e.OverlayKey)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "docs store unavailable", err)
		return
	}
	out.Base, out.Theirs, out.Mine = string(base), string(theirs), string(mine)
	out.HeadBlob, out.HeadCommit = head.Blob, head.Commit
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
