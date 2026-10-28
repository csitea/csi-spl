package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/cloud"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// r8-09: the hub's option and mailer builders, driven by env and a memory
// store. Nothing here opens a socket or a database.

// hubEnv is the smallest env LoadHub accepts, with the memory store.
func hubEnv(t *testing.T) {
	t.Helper()
	t.Setenv("SPOOL_HUB_DB_DSN", "memory:")
	t.Setenv("SPOOL_HUB_FILES_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_FILES_BUCKET", "")
	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "{tenant}.hub.test")
	t.Setenv("SPOOL_HUB_ENV", "dev")
}

func loadHub(t *testing.T) *config.Hub {
	t.Helper()
	hc, err := config.LoadHub()
	if err != nil {
		t.Fatalf("LoadHub: %v", err)
	}
	return hc
}

func edKey(t *testing.T) string {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(priv)
}

func TestApplyRuntimeLimits(t *testing.T) {
	procs, mem := runtime.GOMAXPROCS(0), debug.SetMemoryLimit(-1)
	t.Cleanup(func() { runtime.GOMAXPROCS(procs); debug.SetMemoryLimit(mem) })
	cases := []struct {
		name      string
		procs     int
		memLimit  string
		wantErr   string
		wantProcs int
		wantMem   int64
	}{
		{name: "unset keeps the runtime's own", wantProcs: procs, wantMem: mem},
		{name: "both set", procs: 1, memLimit: "460MiB", wantProcs: 1, wantMem: 460 << 20},
		{name: "negative procs", procs: -1, wantErr: "SPOOL_HUB_GOMAXPROCS"},
		{name: "bad mem limit", memLimit: "lots", wantErr: "SPOOL_HUB_GOMEMLIMIT"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			runtime.GOMAXPROCS(procs)
			debug.SetMemoryLimit(mem)
			err := applyRuntimeLimits(&config.Hub{GoMaxProcs: c.procs, GoMemLimit: c.memLimit})
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got := runtime.GOMAXPROCS(0); got != c.wantProcs {
				t.Fatalf("GOMAXPROCS = %d, want %d", got, c.wantProcs)
			}
			if got := debug.SetMemoryLimit(-1); got != c.wantMem {
				t.Fatalf("memory limit = %d, want %d", got, c.wantMem)
			}
		})
	}
}

func TestCICDService(t *testing.T) {
	cases := []struct {
		name       string
		hc         config.Hub
		wantNil    bool
		wantSigner bool
		wantErr    string
	}{
		{name: "off", hc: config.Hub{}, wantNil: true},
		{name: "on, no box key", hc: config.Hub{CICDLogsEnabled: true, Env: "dev"}},
		{name: "on, box key", hc: config.Hub{CICDLogsEnabled: true, Env: "dev", CICDHubBoxKey: edKey(t)}, wantSigner: true},
		{name: "bad box key", hc: config.Hub{CICDLogsEnabled: true, Env: "dev", CICDHubBoxKey: "bm90LWEta2V5"}, wantErr: "SPOOL_HUB_CICD_HUB_BOX_KEY"},
		{name: "bad tenant tokens", hc: config.Hub{CICDLogsEnabled: true, Env: "dev", CICDTenantTokens: "no-colon"}, wantErr: "SPOOL_HUB_CICD_TENANT_TOKENS"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			svc, err := cicdService(&c.hc)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if (svc == nil) != c.wantNil {
				t.Fatalf("service = %v, want nil %v", svc, c.wantNil)
			}
			if svc != nil && (svc.Signer != nil) != c.wantSigner {
				t.Fatalf("signer set = %v, want %v", svc.Signer != nil, c.wantSigner)
			}
		})
	}
}

func TestWorkspaceDocs(t *testing.T) {
	t.Setenv("STORAGE_EMULATOR_HOST", "127.0.0.1:1") // a GCS client without ADC; nothing is dialled
	cf, err := cloud.New(cloud.OSEnv())
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	cases := []struct {
		name    string
		hc      config.Hub
		wantNil bool
		wantLoc string
		wantErr bool
	}{
		{name: "off", wantNil: true},
		{name: "dir", hc: config.Hub{WorkspaceDocsDir: dir}, wantLoc: filepath.Join(dir, "acme")},
		{name: "bucket", hc: config.Hub{WorkspaceDocsBucket: "docs-{tenant}"}, wantLoc: "docs-acme"},
		{name: "bucket without {tenant}", hc: config.Hub{WorkspaceDocsBucket: "docs"}, wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			wd, err := workspaceDocs(cf, &c.hc)
			if c.wantErr {
				if err == nil {
					t.Fatal("bad location was accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if (wd == nil) != c.wantNil {
				t.Fatalf("resolver = %v, want nil %v", wd, c.wantNil)
			}
			if wd == nil {
				return
			}
			defer wd.Close()
			if loc, err := wd.Location("acme"); err != nil || loc != c.wantLoc {
				t.Fatalf("Location = %q, %v; want %q", loc, err, c.wantLoc)
			}
			if c.hc.WorkspaceDocsDir == "" {
				return
			}
			if bs, err := wd.Store(context.Background(), "acme"); err != nil || bs == nil {
				t.Fatalf("Store = %v, %v", bs, err)
			}
		})
	}
}

func TestLoadAuthConfig(t *testing.T) {
	cases := []struct {
		name     string
		env      map[string]string
		hc       config.Hub
		wantErr  string
		wantHops int
	}{
		{name: "defaults", hc: config.Hub{Env: "dev", TrustedProxyHops: 2}, wantHops: 2},
		{name: "retired knob agrees", env: map[string]string{"SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS": "1"},
			hc: config.Hub{Env: "dev", TrustedProxyHops: 1}, wantHops: 1},
		{name: "retired knob disagrees", env: map[string]string{"SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS": "3"},
			hc: config.Hub{Env: "dev", TrustedProxyHops: 1}, wantErr: "disagrees"},
		{name: "session door, nobody can sign in", hc: config.Hub{Env: "dev", ViewDoor: hub.ViewDoorSession},
			wantErr: "SPOOL_HUB_VIEW_DOOR=session"},
		{name: "session door, native on", env: map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true"},
			hc: config.Hub{Env: "dev", ViewDoor: hub.ViewDoorSession}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			for k, v := range c.env {
				t.Setenv(k, v)
			}
			ac, nc, err := loadAuthConfig(&c.hc)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if ac == nil || nc == nil || nc.TrustedProxyHops != c.wantHops {
				t.Fatalf("ac = %v, nc = %+v, want hops %d", ac, nc, c.wantHops)
			}
		})
	}
}

func TestOperatorInviteConfig(t *testing.T) {
	cases := []struct {
		name, emails, aud string
		want              []string
		wantAud, wantErr  string
	}{
		{name: "off"},
		{name: "split and lowered", emails: " Ops@Example.test,b@example.test\tc@example.test\n", aud: " https://hub.test ",
			want: []string{"ops@example.test", "b@example.test", "c@example.test"}, wantAud: "https://hub.test"},
		{name: "emails without audience", emails: "a@example.test", wantErr: "SPOOL_HUB_OPERATOR_AUDIENCE"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("SPOOL_HUB_OPERATOR_EMAILS", c.emails)
			t.Setenv("SPOOL_HUB_OPERATOR_AUDIENCE", c.aud)
			emails, aud, err := operatorInviteConfig()
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if strings.Join(emails, " ") != strings.Join(c.want, " ") || aud != c.wantAud {
				t.Fatalf("got %q %q, want %q %q", emails, aud, c.want, c.wantAud)
			}
		})
	}
}

func TestMailPreflight(t *testing.T) {
	cases := []struct {
		name, env, preflight string
		wantErr              bool
	}{
		{name: "warn returns at once", env: "prd", preflight: mail.PreflightWarn},
		{name: "require, no relay, dev", env: "dev", preflight: mail.PreflightRequire},
		{name: "require, no relay, prd", env: "prd", preflight: mail.PreflightRequire, wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mc := &mail.Config{Transport: mail.TransportNone, Preflight: c.preflight}
			err := mailPreflight(context.Background(), &config.Hub{Env: c.env}, zerolog.Nop(), mc)
			if (err != nil) != c.wantErr {
				t.Fatalf("err = %v, want error %v", err, c.wantErr)
			}
		})
	}
}

func TestMailers(t *testing.T) {
	ctx, log, hc := context.Background(), zerolog.Nop(), &config.Hub{DefaultLocale: "en"}
	none := &mail.Config{Transport: mail.TransportNone}
	logged := &mail.Config{Transport: mail.TransportLog}
	cases := []struct {
		name     string
		st       store.Store
		mc       *mail.Config
		appURL   string
		wantMail bool
	}{
		{name: "no relay", st: store.NewMemory(), mc: none, appURL: "https://app.test"},
		{name: "no app url", st: store.NewMemory(), mc: logged},
		{name: "store without invite mails", st: struct{ store.Store }{store.NewMemory()}, mc: logged, appURL: "https://app.test"},
		{name: "relay, store and url", st: store.NewMemory(), mc: logged, appURL: "https://app.test", wantMail: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			om := operatorMailer(hc, log, c.st, c.mc, c.appURL)
			im := inviteMailer(hc, log, c.st, c.mc, c.appURL)
			if (om != nil) != c.wantMail || (im != nil) != c.wantMail {
				t.Fatalf("operator mailer %v, invite mailer %v, want %v", om != nil, im != nil, c.wantMail)
			}
			if !c.wantMail {
				return
			}
			// no invite row: the claim refuses, nothing is sent
			res, err := om(ctx, "acme", "nobody@example.test", "en")
			if err != nil || res.Outcome == "" {
				t.Fatalf("operator mailer = %+v, %v", res, err)
			}
			if out, err := im(ctx, "acme", "nobody@example.test", "en"); err != nil || out != res.Outcome {
				t.Fatalf("invite mailer = %q, %v; want %q", out, err, res.Outcome)
			}
		})
	}
	if embedRelinkMailer(log, none) != nil {
		t.Fatal("relink mailer without a relay")
	}
	relink := embedRelinkMailer(log, logged)
	if relink == nil {
		t.Fatal("no relink mailer with a relay")
	}
	if err := relink(ctx, "visitor@example.test", "https://app.test/relink", time.Hour); err != nil {
		t.Fatalf("relink over the log relay: %v", err)
	}
}

func TestBaseOptions(t *testing.T) {
	hubEnv(t)
	hc := loadHub(t)
	hc.LobbyTaskID, hc.TrustedProxyHops = "lobby-1", 2
	st := store.NewMemory()
	ot := hub.NewOriginTenant(hc.TenantHostPattern, "apex")
	opts := baseOptions(hc, zerolog.Nop(), st, blob.Dir{Root: t.TempDir()}, ot)
	if opts.Store != st || opts.Blob == nil || opts.OriginTenant != ot {
		t.Fatal("store, blob or origin tenant not wired")
	}
	if opts.TenantHostPattern != hc.TenantHostPattern || opts.Env != hc.Env || opts.LobbyTaskID != "lobby-1" ||
		opts.Edge.TrustedProxyHops != 2 || opts.Version != version {
		t.Fatalf("cnf not mapped: %+v", opts)
	}
}

func TestHubOptions(t *testing.T) {
	cases := []struct {
		name         string
		env          map[string]string
		wantErr      string
		wantWUIKey   bool
		wantOperator bool
		wantCICD     bool
		// r34-02: the wiring a dropped line left green
		wantOrigin, wantUploadKey, wantGcal bool
	}{
		{name: "defaults"},
		{name: "ephemeral wui key, tenant hosts, cicd", env: map[string]string{"SPOOL_HUB_WUI_KEY_EPHEMERAL": "true",
			"SPOOL_HUB_WUI_TENANT_HOSTS": "true", "SPOOL_HUB_CICD_LOGS_ENABLED": "true",
			"SPOOL_HUB_CICD_GITHUB_API": "https://api.example.test"}, wantWUIKey: true, wantCICD: true, wantOrigin: true},
		{name: "native sign-in and operator routes", env: map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true",
			"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32), "SPOOL_HUB_AUTH_APP_URL": "https://app.test",
			"SPOOL_HUB_MAIL_TRANSPORT": "log", "SPOOL_HUB_OPERATOR_EMAILS": "ops@example.test",
			"SPOOL_HUB_OPERATOR_AUDIENCE": "https://hub.test", "SPOOL_HUB_GCAL_WORKSPACES": "acme"},
			wantOperator: true, wantUploadKey: true, wantGcal: true},
		{name: "bad wui key", env: map[string]string{"SPOOL_HUB_WUI_KEY": "bm90LWEta2V5"}, wantErr: "SPOOL_HUB_WUI_KEY"},
		{name: "operator emails without audience", env: map[string]string{"SPOOL_HUB_OPERATOR_EMAILS": "ops@example.test"},
			wantErr: "SPOOL_HUB_OPERATOR_AUDIENCE"},
		{name: "require preflight on prd without relay", env: map[string]string{"SPOOL_HUB_ENV": "prd",
			"SPOOL_HUB_MAIL_PREFLIGHT": "require"}, wantErr: "SPOOL_HUB_MAIL_PREFLIGHT=require"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hubEnv(t)
			t.Setenv("SPOOL_HUB_OPERATOR_EMAILS", "")
			t.Setenv("SPOOL_HUB_OPERATOR_AUDIENCE", "")
			for k, v := range c.env {
				t.Setenv(k, v)
			}
			hc, err := config.LoadHub()
			var opts hub.Options
			if err == nil {
				opts, err = hubOptions(context.Background(), hc, zerolog.Nop(), store.NewMemory(), blob.Dir{Root: t.TempDir()})
			}
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if opts.Auth == nil || opts.Payments == nil {
				t.Fatal("auth or payments not wired")
			}
			if (opts.WUIKey != nil) != c.wantWUIKey || (opts.OperatorVerify != nil) != c.wantOperator ||
				(opts.OperatorMail != nil) != c.wantOperator || (opts.CICD != nil) != c.wantCICD {
				t.Fatalf("wui key %v, operator %v/%v, cicd %v", opts.WUIKey != nil, opts.OperatorVerify != nil,
					opts.OperatorMail != nil, opts.CICD != nil)
			}
			if (opts.OriginTenant != nil) != c.wantOrigin || (len(opts.UploadTokenKey) > 0) != c.wantUploadKey ||
				(opts.Gcal != nil) != c.wantGcal {
				t.Fatalf("origin tenant %v, upload token key %v, gcal %v", opts.OriginTenant != nil,
					len(opts.UploadTokenKey) > 0, opts.Gcal != nil)
			}
		})
	}
}

// TestAuthOptions pins what auth.New is handed: inside auth.Handler it is
// out of the test's reach, so the step that builds it is read directly.
func TestAuthOptions(t *testing.T) {
	hubEnv(t)
	hc := loadHub(t)
	ao := authOptions(hc, zerolog.Nop(), store.NewMemory(), blob.Dir{Root: t.TempDir()}, nil)
	if ao.Revocations == nil || ao.Registrar == nil || ao.DefaultLocale != hc.DefaultLocale {
		t.Fatalf("auth options not wired: revocations %v, registrar %v, locale %q",
			ao.Revocations != nil, ao.Registrar != nil, ao.DefaultLocale)
	}
}
