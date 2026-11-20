package main

import (
	"os"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// repoSyncOptions sets the hub's repo sync and, for its webhook route
// (SPL-6006), the webhook secret: "" = no webhook route.
func repoSyncOptions(opts *hub.Options, hc *config.Hub, log zerolog.Logger) {
	opts.RepoSync = repoSync(hc, log)
	opts.RepoSyncWebhookSecret = hc.RepoSyncWebhookSecret
}

// repoSync wires the hub's own GitHub sync of workspace repos (spec 143
// releases-projects.md row B-6b, SPL-5808): nil (off) unless
// SPOOL_HUB_REPO_SYNC_ENABLED. It reads through the fleet GitHub App, the
// one the Docs edit uses (spec 171 Q3); with no App key it reads public
// repos only. The key is handed to the GitHub package only: never logged.
func repoSync(hc *config.Hub, log zerolog.Logger) *hub.RepoSync {
	if !hc.RepoSyncEnabled {
		return nil
	}
	api := hc.RepoSyncGitHubAPI
	if api == "" {
		api = hc.DocsEditGitHubAPI
	}
	app, err := github.NewRepoApp(github.RepoAppConfig{API: api, AppID: hc.DocsEditGitHubAppID,
		Key: []byte(os.Getenv(GitHubAppKeyEnv)), Log: log.With().Str("component", "repo-sync").Logger()})
	if err != nil {
		log.Error().Str("reason", err.Error()).Msg("repo sync stays off")
		return nil
	}
	log.Info().Bool("app_key", os.Getenv(GitHubAppKeyEnv) != "").Msg("repo sync on")
	return hub.GitHubRepoSync(app, hc.DocsEditInstallationID)
}
