package hubclient

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 184 row H2: ReportAgentModels against the real hub (memory store, the
// routes of row H1). A reading is stored under Cfg.BoxID, an older one
// answers stored false, nil models go out as [], and a hub refusal is a
// *HubError with the hub's token.
func TestReportAgentModels(t *testing.T) {
	ctx, st := context.Background(), store.NewMemory()
	rootPub, _, _ := ed25519.GenerateKey(nil)
	if err := st.CreateTenant(ctx, store.Tenant{ID: "t1", RootPubKey: rootPub}); err != nil {
		t.Fatal(err)
	}
	srv, err := hub.New(hub.Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}.hub.test", HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: time.Hour, QueueTTL: 24 * time.Hour, QueueMaxPerBox: 100, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() { srv.Shutdown(); ts.Close() })
	root := t.TempDir()
	keys := filepath.Join(root, "keys")
	pubB64, err := sign.GenerateKey(keys, "box-a", false)
	if err != nil {
		t.Fatal(err)
	}
	pub, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(pubB64))
	if err := st.PutPin(ctx, "t1", "box-a", pub, true, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	c := New(&config.Config{SpoolRoot: filepath.Join(root, "spool"), KeysDir: keys, PinsDir: filepath.Join(root, "spool", "pins"),
		BoxID: "box-a", Tenant: "t1", HubURL: ts.URL, SubmitSocket: "off"})
	c.ReadyTimeout = 5 * time.Second

	at := time.Now().UTC().Truncate(time.Second)
	stored, err := c.ReportAgentModels(ctx, AgentModelReading{Vendor: "grok", CLIVersion: "1.0.92", Models: []string{"grok-4"}, ReadAt: at})
	if err != nil || !stored {
		t.Fatalf("first reading: stored %v err %v, want stored true", stored, err)
	}
	stored, err = c.ReportAgentModels(ctx, AgentModelReading{Vendor: "grok", CLIVersion: "1.0.91", ReadAt: at.Add(-time.Hour)})
	if err != nil || stored {
		t.Fatalf("older reading: stored %v err %v, want stored false", stored, err)
	}
	rows, err := st.AgentModelReadings(ctx, "t1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Box != "box-a" || rows[0].CLIVersion != "1.0.92" || !slices.Equal(rows[0].Models, []string{"grok-4"}) {
		t.Fatalf("readings %+v, want the first one only, under box-a", rows)
	}
	_, err = c.ReportAgentModels(ctx, AgentModelReading{Vendor: "nope", CLIVersion: "1", ReadAt: at})
	var he *HubError
	if !errors.As(err, &he) || he.Token != "bad_vendor" {
		t.Fatalf("vendor nope: err %v, want a HubError bad_vendor", err)
	}
}
