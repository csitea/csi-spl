package config

import (
	"testing"

	"github.com/caarlos0/env/v10"
)

// N3, the R7 of SPL-5808 (SPL-6006): the hub's own GitHub sync and its
// webhook are off by default: an environment that names neither switch on
// parses to RepoSyncEnabled false and no webhook secret. RED CONTROL:
// envDefault:"true" on RepoSyncEnabled fails here. The hub side (no loop,
// "Sync now" 503, no webhook route) is internal/hub TestRepoSyncOffByDefault.
func TestRepoSyncOffByDefault(t *testing.T) {
	var h Hub
	if err := env.ParseWithOptions(&h, env.Options{Environment: map[string]string{}}); err != nil {
		t.Fatal(err)
	}
	if h.RepoSyncEnabled || h.RepoSyncWebhookSecret != "" {
		t.Fatalf("defaults: RepoSyncEnabled=%v, webhook secret set=%v; want off and none", h.RepoSyncEnabled, h.RepoSyncWebhookSecret != "")
	}
}
