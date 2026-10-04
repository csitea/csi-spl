package cloud

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

func fakeEnv(kv map[string]string, host string) Env {
	return Env{
		Getenv: func(k string) string { return kv[k] },
		Hostname: func() (string, error) {
			if host == "" {
				return "", errors.New("no hostname")
			}
			return host, nil
		},
	}
}

func TestParseProvider(t *testing.T) {
	for in, want := range map[string]Provider{"": GCP, " ": GCP, "gcp": GCP, "none": None, "aws": AWS} {
		got, err := ParseProvider(in)
		if err != nil || got != want {
			t.Errorf("ParseProvider(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"azure", "GCP", "local"} {
		if _, err := ParseProvider(bad); err == nil {
			t.Errorf("ParseProvider(%q) accepted an unknown provider", bad)
		}
	}
}

func TestNewPicksTheProvider(t *testing.T) {
	for in, want := range map[string]Provider{"": GCP, "gcp": GCP, "none": None} {
		f, err := New(fakeEnv(map[string]string{EnvProvider: in}, "h"))
		if err != nil || f.Provider() != want {
			t.Fatalf("New(%q) = %v, %v; want %q", in, f, err, want)
		}
	}
	for _, bad := range []string{"aws", "azure"} {
		if _, err := New(fakeEnv(map[string]string{EnvProvider: bad}, "h")); err == nil {
			t.Errorf("New(%q) must be a startup error, not a fallback", bad)
		}
	}
}

func TestGCPChoices(t *testing.T) {
	t.Setenv("STORAGE_EMULATOR_HOST", "127.0.0.1:1") // a client without ADC; nothing is dialled
	ctx := context.Background()
	f, _ := New(fakeEnv(map[string]string{"K_REVISION": "spool-hub-00042-abc", "SPOOL_VERSION": "9.9.9"}, "h"))
	if got := f.Compute().Revision(); got != "spool-hub-00042-abc" {
		t.Errorf("gcp revision = %q, want K_REVISION", got)
	}
	if got := (gcpFactory{fakeEnv(nil, "h")}).Compute().Revision(); got != "" {
		t.Errorf("gcp revision without K_REVISION = %q, want \"\" (hub mints a per-process id)", got)
	}
	for _, dsn := range []string{"host=/cloudsql/p:r:i dbname=d", "postgres://u@h/d", "memory:"} {
		if got, err := f.Database().DSN(dsn); err != nil || got != dsn {
			t.Errorf("gcp DSN(%q) = %q, %v; want unchanged", dsn, got, err)
		}
	}
	bs, err := f.Blob(ctx, "files-bucket", "/ignored")
	if _, ok := bs.(*blob.GCS); err != nil || !ok {
		t.Errorf("gcp Blob(bucket) = %T, %v; want *blob.GCS", bs, err)
	}
	if bs, _ := f.Blob(ctx, "", "/d"); bs != (blob.Dir{Root: "/d"}) {
		t.Errorf("gcp Blob(dir) = %#v, want blob.Dir{/d}", bs)
	}
	if bs, err := f.Blob(ctx, "", ""); bs != nil || err != nil {
		t.Errorf("gcp Blob(off) = %#v, %v; want nil, nil", bs, err)
	}
}

func TestNoneChoices(t *testing.T) {
	ctx := context.Background()
	f, _ := New(fakeEnv(map[string]string{EnvProvider: "none", "K_REVISION": "x"}, "c0ffee"))
	if got := f.Compute().Revision(); got != "c0ffee" {
		t.Errorf("none revision = %q, want the hostname", got)
	}
	f, _ = New(fakeEnv(map[string]string{EnvProvider: "none", "SPOOL_VERSION": "1.4.2"}, "c0ffee"))
	if got := f.Compute().Revision(); got != "1.4.2" {
		t.Errorf("none revision = %q, want SPOOL_VERSION", got)
	}
	f, _ = New(fakeEnv(map[string]string{EnvProvider: "none"}, ""))
	if got := f.Compute().Revision(); got != "" {
		t.Errorf("none revision without version or hostname = %q, want \"\"", got)
	}
	if bs, err := f.Blob(ctx, "", "/var/lib/spool/files"); err != nil || bs != (blob.Dir{Root: "/var/lib/spool/files"}) {
		t.Errorf("none Blob(dir) = %#v, %v", bs, err)
	}
	if _, err := f.Blob(ctx, "files-bucket", "/d"); err == nil {
		t.Error("none Blob(bucket) must refuse, never open a GCS client")
	}
	if bs, err := f.Blob(ctx, "", ""); bs != nil || err != nil {
		t.Errorf("none Blob(off) = %#v, %v; want nil, nil", bs, err)
	}
	dsn := "postgres://rt:pw@pg:5432/spool_hub?sslmode=disable"
	if got, err := f.Database().DSN(dsn); err != nil || got != dsn {
		t.Errorf("none DSN(tcp) = %q, %v", got, err)
	}
	if _, err := f.Database().DSN("host=/cloudsql/p:r:i dbname=d"); err == nil || !strings.Contains(err.Error(), "TCP") {
		t.Errorf("none DSN(cloudsql socket) = %v, want a refusal", err)
	}
}

func TestSecretsReadTheEnv(t *testing.T) {
	for _, p := range []string{"gcp", "none"} {
		f, _ := New(fakeEnv(map[string]string{EnvProvider: p, "SPOOL_X": "v"}, "h"))
		if v, ok := f.Secrets().Secret("SPOOL_X"); !ok || v != "v" {
			t.Errorf("%s Secret(SPOOL_X) = %q, %v", p, v, ok)
		}
		if _, ok := f.Secrets().Secret("SPOOL_MISSING"); ok {
			t.Errorf("%s Secret(missing) reported present", p)
		}
	}
}
