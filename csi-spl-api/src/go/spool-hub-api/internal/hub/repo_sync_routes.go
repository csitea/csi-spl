package hub

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The two triggers of the hub's own GitHub sync besides its 5-minute loop
// (spec 143 releases-projects.md row B-6b part 2, spec 171 section 3.4.1,
// SPL-6006):
//
//	POST /v1/repos/{owner}/{name}/sync
//	    "Sync now": a workspace admin, signed in as themself, syncs one of
//	    the workspace's registered repos at once. 200 {stored, versioned,
//	    rejected, redacted, sync_status, sync_error}; 403 for anyone else;
//	    404 not_registered for a repo this workspace has not registered for
//	    the sync (before any GitHub call); 409 sync_busy while another sync
//	    holds the repo; 503 repo_sync_off while the sync is off.
//	POST /v1/webhooks/github
//	    GitHub's App webhook, mounted only while the sync is on and
//	    Options.RepoSyncWebhookSecret is set. Not tenant-scoped: the body's
//	    X-Hub-Signature-256 (HMAC-SHA256 of the body with the secret) is the
//	    only credential, compared in constant time; 401 bad_signature else.
//	    A body over repoSyncWebhookMax is 413 with no sync (GitHub's push
//	    payloads can be larger; the loop catches up). ping and other events
//	    answer 204. A push to a registered row's trunk branch, or a release,
//	    starts a sync of each workspace that registered the repo, in the
//	    background, and answers 202 {started} at once.
//
// The webhook's syncs are bounded (C1 of the GO): at most one in flight per
// (workspace, repo) on this instance (Server.repoHooks), and one whose repo
// lock another sync holds returns at once, dropped (the loop catches up):
// nothing queues behind a sync. Each runs on its own context, never the
// request's, with a repoSyncHookTimeout deadline.

// repoSyncWebhookMax is the most bytes a webhook body takes.
const repoSyncWebhookMax = 1 << 20

// repoSyncHookTimeout bounds one sync the webhook starts.
const repoSyncHookTimeout = 4 * time.Minute

func (s *Server) routeRepoSync(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/repos/{owner}/{name}/sync", s.handleRepoSyncNow)
	mux.HandleFunc("OPTIONS /v1/repos/{owner}/{name}/sync", s.preflight)
	if _, on := s.repoSyncStores(); on && s.o.RepoSyncWebhookSecret != "" {
		mux.HandleFunc("POST /v1/webhooks/github", s.handleGitHubWebhook)
	}
}

// handleRepoSyncNow is "Sync now".
func (s *Server) handleRepoSyncNow(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	if !a.Has(rbac.Admin) || s.readerIsActAsClone(r.Context(), t.ID, a.HumanID) {
		writeForbidden(w, rbac.TenantSettings, "only a workspace's admin, signed in as themself, syncs a repo")
		return
	}
	slug := strings.ToLower(r.PathValue("owner") + "/" + r.PathValue("name"))
	res, err := s.SyncRepo(r.Context(), t.ID, slug)
	switch {
	case errors.Is(err, ErrRepoSyncOff):
		writeErr(w, http.StatusServiceUnavailable, "repo_sync_off", "this hub does not sync repos")
		return
	case errors.Is(err, ErrRepoSyncRefused):
		writeErr(w, http.StatusNotFound, "not_registered", "this workspace has not registered that repo for the sync")
		return
	case errors.Is(err, ErrRepoSyncBusy):
		writeErr(w, http.StatusConflict, "sync_busy", "another sync of that repo is running; try again in a minute")
		return
	}
	out := map[string]any{"repo_slug": slug, "stored": res.Stored, "versioned": res.Versioned,
		"rejected": res.Rejected, "redacted": res.Redacted, "sync_status": "ok", "sync_error": ""}
	if err != nil {
		out["sync_status"], out["sync_error"] = "error", err.Error()
	}
	writeJSON(w, http.StatusOK, out)
}

// gitHubHook is the part of a push or release payload the webhook reads.
type gitHubHook struct {
	Ref        string `json:"ref"`
	Repository struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
}

// handleGitHubWebhook is GitHub's App webhook.
func (s *Server) handleGitHubWebhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, repoSyncWebhookMax))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "the body is over 1 MiB; the 5-minute sync catches up")
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_body", "the body was not read")
		return
	}
	if !validHubSignature(r.Header.Get("X-Hub-Signature-256"), body, s.o.RepoSyncWebhookSecret) {
		writeErr(w, http.StatusUnauthorized, "bad_signature", "X-Hub-Signature-256 does not match")
		return
	}
	event := r.Header.Get("X-GitHub-Event")
	if event != "push" && event != "release" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var p gitHubHook
	if err := json.Unmarshal(body, &p); err != nil || p.Repository.FullName == "" {
		writeErr(w, http.StatusBadRequest, "bad_json", "the body names no repository.full_name")
		return
	}
	targets, err := s.hookTargets(r.Context(), strings.ToLower(p.Repository.FullName))
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "unavailable", "the synced repos were not read", err)
		return
	}
	started := 0
	for _, t := range targets {
		if event == "push" && p.Ref != "refs/heads/"+t.TrunkBranch {
			continue
		}
		if s.startHookSync(t) {
			started++
		}
	}
	writeJSON(w, http.StatusAccepted, map[string]int{"started": started})
}

// hookTargets is the synced rows of slug, one per workspace that registered it.
func (s *Server) hookTargets(ctx context.Context, slug string) ([]store.RepoSyncTarget, error) {
	st, on := s.repoSyncStores()
	if !on {
		return nil, ErrRepoSyncOff
	}
	all, err := st.rs.RepoSyncTargets(ctx)
	if err != nil {
		return nil, err
	}
	var out []store.RepoSyncTarget
	for _, t := range all {
		if t.Slug == slug {
			out = append(out, t)
		}
	}
	return out, nil
}

// startHookSync starts one background sync of t unless one is in flight
// on this instance; false = dropped.
func (s *Server) startHookSync(t store.RepoSyncTarget) bool {
	key := t.Tenant + "\x00" + t.Slug
	if _, busy := s.repoHooks.LoadOrStore(key, struct{}{}); busy {
		return false
	}
	go func() {
		defer s.repoHooks.Delete(key)
		ctx, cancel := context.WithTimeout(context.Background(), repoSyncHookTimeout)
		defer cancel()
		res, err := s.SyncRepo(ctx, t.Tenant, t.Slug)
		if err != nil {
			s.o.Log.Warn().Str("repo", t.Slug).Str("err", err.Error()).Msg("repo sync: webhook")
			return
		}
		s.o.Log.Info().Str("repo", t.Slug).Int("stored", res.Stored).Int("versioned", res.Versioned).Msg("repo sync: webhook")
	}()
	return true
}

// validHubSignature is whether sig is "sha256=<hex>" of HMAC-SHA256(body)
// under secret; an empty secret matches nothing.
func validHubSignature(sig string, body []byte, secret string) bool {
	hexSig, ok := strings.CutPrefix(sig, "sha256=")
	got, err := hex.DecodeString(hexSig)
	if !ok || err != nil || secret == "" {
		return false
	}
	m := hmac.New(sha256.New, []byte(secret))
	m.Write(body) //nolint:errcheck // hash.Hash.Write never fails
	return hmac.Equal(got, m.Sum(nil))
}
