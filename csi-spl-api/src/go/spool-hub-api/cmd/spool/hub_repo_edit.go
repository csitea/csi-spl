package main

import (
	"context"
	"os"
	"strings"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/repodocs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GitHubAppKeyEnv is the env var the App private key arrives in (Secret
// Manager slot spool-hub-github-app-key, cnf docs.repo_edit.secret_env).
const GitHubAppKeyEnv = "SPOOL_GITHUB_APP_KEY"

// repoEdit wires editable Repo Docs (spec 075 repo-edit, task T08): the edit
// routes' options, and the env's one pusher (repodocs.Worker) started on
// ctx. Only while cnf enabled is true and every piece is there; a missing
// piece is logged and keeps editing off (nil), it never stops the hub. The
// key is read here and handed to the GitHub client only: never logged.
func repoEdit(ctx context.Context, hc *config.Hub, log zerolog.Logger, st store.Store, docs blob.Store) *hub.RepoEdit {
	if !hc.DocsEditEnabled {
		return nil
	}
	off := func(why string) *hub.RepoEdit {
		log.Error().Str("reason", why).Msg("repo docs editing stays off")
		return nil
	}
	pg, ok := st.(*store.Postgres)
	if !ok {
		return off("the store has no edit queue (Postgres only)")
	}
	if docs == nil {
		return off("no docs bucket (SPOOL_HUB_DOCS_BUCKET)")
	}
	deny := nonEmpty(hc.DocsEditDeny)
	if len(deny) == 0 {
		return off("SPOOL_HUB_DOCS_EDIT_DENY is empty: every path would be editable")
	}
	owner, repo, ok := strings.Cut(hc.DocsEditGitHubRepo, "/")
	if !ok || owner == "" || repo == "" || strings.Contains(repo, "/") {
		return off("SPOOL_HUB_DOCS_EDIT_GITHUB_REPO must be <owner>/<repo> (no default)")
	}
	key := os.Getenv(GitHubAppKeyEnv)
	if key == "" {
		return off(GitHubAppKeyEnv + " is not set (cnf docs.repo_edit.inject)")
	}
	gh, err := github.New(github.Config{API: hc.DocsEditGitHubAPI, AppID: hc.DocsEditGitHubAppID,
		InstallationID: hc.DocsEditInstallationID, Owner: owner, Repo: repo, Branch: "master",
		Key: []byte(key), Log: log.With().Str("component", "github").Logger()})
	if err != nil { // never quotes the key
		return off("github client: " + err.Error())
	}
	w, err := repodocs.NewWorker(repodocs.WorkerConfig{Env: hc.Env, Queue: pg, Repo: gh, Bucket: docs, Deny: deny,
		Log: log.With().Str("component", "repo-edit-worker").Logger(),
		Lock: func(ctx context.Context) (repodocs.Session, bool, error) {
			s, held, err := pg.LockRepoDocWorker(ctx)
			if err != nil || !held {
				return nil, false, err
			}
			return s, true, nil
		}})
	if err != nil {
		return off("worker: " + err.Error())
	}
	go w.Run(ctx) //nolint:errcheck // Run returns only when ctx ends
	log.Info().Str("repo", hc.DocsEditGitHubRepo).Int("deny", len(deny)).Msg("repo docs editing on")
	return &hub.RepoEdit{Env: hc.Env, Deny: deny, BlockedWorkspaces: nonEmpty(hc.DocsEditBlocked),
		CoalesceAfter: hc.DocsEditCoalesceAfter, CoalesceMax: hc.DocsEditCoalesceMax, MinMemberAge: hc.DocsEditMinMemberAge,
		RateMemberHour: hc.DocsEditRateMemberHour, RateAgentHour: hc.DocsEditRateAgentHour,
		RateWorkspaceDay: hc.DocsEditRateWorkspaceDay, RateEnvDay: hc.DocsEditRateEnvDay, Repo: gh}
}

// nonEmpty drops the blank entries a comma list carries ("" -> [""]).
func nonEmpty(in []string) []string {
	var out []string
	for _, v := range in {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}
