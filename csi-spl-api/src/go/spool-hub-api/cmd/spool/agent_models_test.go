package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// Spec 184 row H2: `spool agent-models report` against the real hub (memory
// store, the routes of row H1). The verb's reading is stored and read back;
// a second, older reading answers stored false and changes nothing.
// RED CONTROL: a verb that sends no bearer gets 401 door, and the first case
// fails.
func TestAgentModelsReportStoresReading(t *testing.T) {
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
	cfg := testkit.NewConfig(t)
	pubB64, err := sign.GenerateKey(cfg.KeysDir, "box-a", false)
	if err != nil {
		t.Fatal(err)
	}
	pub, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(pubB64))
	if err := st.PutPin(ctx, "t1", "box-a", pub, true, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	cfg.HubURL, cfg.BoxID, cfg.Tenant, cfg.SubmitSocket = ts.URL, "box-a", "t1", "off"

	at := time.Now().UTC().Truncate(time.Second)
	report := func(models, readAt string) (int, string, string) {
		return capture(t, models, func() int {
			return cmdAgentModels(cfg, []string{"report", "--vendor", "grok", "--cli-version", "1.0.92", "--read-at", readAt})
		})
	}
	readings := func() []store.AgentModelReading {
		rows, err := st.AgentModelReadings(ctx, "t1")
		if err != nil {
			t.Fatal(err)
		}
		return rows
	}

	rc, out, errOut := report("grok-4.7\n\n grok-4.6 \n", at.Format(time.RFC3339))
	if rc != 0 || strings.TrimSpace(out) != `{"box":"box-a","stored":true,"vendor":"grok"}` {
		t.Fatalf("first reading: rc %d out %q err %q, want rc 0 stored true", rc, out, errOut)
	}
	rows := readings()
	if len(rows) != 1 || rows[0].Box != "box-a" || rows[0].Vendor != "grok" || rows[0].CLIVersion != "1.0.92" ||
		!slices.Equal(rows[0].Models, []string{"grok-4.7", "grok-4.6"}) || !rows[0].ReadAt.Equal(at) {
		t.Fatalf("read back %+v", rows)
	}

	rc, out, errOut = report("grok-3\n", at.Add(-time.Hour).Format(time.RFC3339))
	if rc != 0 || strings.TrimSpace(out) != `{"box":"box-a","stored":false,"vendor":"grok"}` {
		t.Fatalf("older reading: rc %d out %q err %q, want rc 0 stored false", rc, out, errOut)
	}
	if rows := readings(); len(rows) != 1 || !slices.Equal(rows[0].Models, []string{"grok-4.7", "grok-4.6"}) {
		t.Fatalf("an older reading replaced the stored one: %+v", rows)
	}

	rc, _, errOut = report("bad name\n", at.Add(time.Minute).Format(time.RFC3339))
	if rc != 1 || !strings.Contains(errOut, "bad_reading") {
		t.Fatalf("a model outside the syntax: rc %d err %q, want 1 bad_reading", rc, errOut)
	}
	rc, _, errOut = capture(t, "", func() int {
		return cmdAgentModels(cfg, []string{"report", "--vendor", "nope", "--cli-version", "1"})
	})
	if rc != 1 || !strings.Contains(errOut, "bad_vendor") {
		t.Fatalf("an unknown vendor: rc %d err %q, want 1 bad_vendor", rc, errOut)
	}
}

// The off and usage paths: exit 3 with no hub mode or a hub without the
// route (A1's codes), 1 with no --vendor or no report sub-verb.
func TestAgentModelsReportOff(t *testing.T) {
	cfg := testkit.NewConfig(t)
	args := []string{"report", "--vendor", "grok", "--cli-version", "1"}
	if rc, _, errOut := capture(t, "grok-4\n", func() int { return cmdAgentModels(cfg, args) }); rc != 3 || !strings.Contains(errOut, "no hub mode") {
		t.Fatalf("no hub mode: rc %d %q, want 3", rc, errOut)
	}
	h := newScriptHub(t, nil, nil) // every REST path is 404
	cfg = hubCfg(t, h.URL)
	if rc, _, errOut := capture(t, "grok-4\n", func() int { return cmdAgentModels(cfg, args) }); rc != 3 || !strings.Contains(errOut, "no reading route (404)") {
		t.Fatalf("a hub without the route: rc %d %q, want 3", rc, errOut)
	}
	for _, a := range [][]string{nil, {"list"}, {"report", "--cli-version", "1"}} {
		if rc, _, _ := capture(t, "", func() int { return cmdAgentModels(cfg, a) }); rc != 1 {
			t.Errorf("%v: rc %d, want 1", a, rc)
		}
	}
	// A hub URL with no box id is off too (A1's 3), not config.Load's 1.
	t.Setenv("SPOOL_ROOT", t.TempDir())
	t.Setenv("SPOOL_HUB_URL", h.URL)
	t.Setenv("SPOOL_BOX_ID", "")
	if rc, _, errOut := capture(t, "grok-4\n", func() int { return run(append([]string{"agent-models"}, args...)) }); rc != 3 || !strings.Contains(errOut, "no box id") {
		t.Fatalf("no box id: rc %d %q, want 3", rc, errOut)
	}
}
