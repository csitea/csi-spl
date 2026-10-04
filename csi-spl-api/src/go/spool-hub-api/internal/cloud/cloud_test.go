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
	for name, open := range map[string]func(context.Context, string, string) (blob.Store, error){
		"Files": f.BlobStore().Files, "Docs": f.BlobStore().Docs,
	} {
		bs, err := open(ctx, "files-bucket", "/ignored")
		if _, ok := bs.(*blob.GCS); err != nil || !ok {
			t.Errorf("gcp %s(bucket) = %T, %v; want *blob.GCS", name, bs, err)
		}
		if bs, _ := open(ctx, "", "/d"); bs != (blob.Dir{Root: "/d"}) {
			t.Errorf("gcp %s(dir) = %#v, want blob.Dir{/d}", name, bs)
		}
		if bs, err := open(ctx, "", ""); bs != nil || err != nil {
			t.Errorf("gcp %s(off) = %#v, %v; want nil, nil", name, bs, err)
		}
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
	docs := f.BlobStore().Docs
	if bs, err := docs(ctx, "", "/var/lib/spool/docs"); err != nil || bs != (blob.Dir{Root: "/var/lib/spool/docs"}) {
		t.Errorf("none Docs(dir) = %#v, %v", bs, err)
	}
	if _, err := docs(ctx, "docs-bucket", "/d"); err == nil {
		t.Error("none Docs(bucket) must refuse, never open a GCS client")
	}
	if bs, err := docs(ctx, "", ""); bs != nil || err != nil {
		t.Errorf("none Docs(off) = %#v, %v; want nil, nil", bs, err)
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

// composeS3 is the S3 env docker-compose.yml gives the hub, with test values.
func composeS3() map[string]string {
	return map[string]string{
		EnvProvider:         "none",
		blob.EnvS3Endpoint:  "http://s3.test:9000",
		EnvS3Bucket:         "test-files",
		blob.EnvS3AccessKey: "test-access",
		blob.EnvS3SecretKey: "test-secret",
		EnvS3UsePathStyle:   "true",
	}
}

func TestNoneFilesIsS3(t *testing.T) {
	ctx := context.Background()
	kv := composeS3()
	f, _ := New(fakeEnv(kv, "h"))
	// the dir is ignored: under none the S3 env is the store (owner decision 1)
	bs, err := f.BlobStore().Files(ctx, "", "/var/lib/spool/files")
	if _, ok := bs.(*blob.S3); err != nil || !ok {
		t.Fatalf("none Files = %T, %v; want *blob.S3", bs, err)
	}
	if _, err := f.BlobStore().Files(ctx, "files-bucket", ""); err == nil || !strings.Contains(err.Error(), "GCS") {
		t.Errorf("none Files(GCS bucket) = %v, want a refusal", err)
	}
	opt, err := s3Options(fakeEnv(kv, "h"))
	if err != nil || opt != (blob.S3Options{Bucket: "test-files", Region: s3DefaultRegion, Endpoint: "http://s3.test:9000"}) {
		t.Errorf("s3Options = %#v, %v", opt, err)
	}
	kv[blob.EnvS3Region] = "eu-north-1"
	if opt, _ := s3Options(fakeEnv(kv, "h")); opt.Region != "eu-north-1" {
		t.Errorf("s3Options region = %q, want %s", opt.Region, blob.EnvS3Region)
	}
}

func TestNoneFilesFailsFastWithoutS3Env(t *testing.T) {
	ctx := context.Background()
	for _, k := range []string{blob.EnvS3Endpoint, EnvS3Bucket, blob.EnvS3AccessKey, blob.EnvS3SecretKey} {
		kv := composeS3()
		delete(kv, k)
		f, _ := New(fakeEnv(kv, "h"))
		bs, err := f.BlobStore().Files(ctx, "", "/var/lib/spool/files")
		if bs != nil || err == nil || !strings.Contains(err.Error(), k) {
			t.Errorf("none Files without %s = %#v, %v; want an error naming it", k, bs, err)
		}
	}
	for _, v := range []string{"false", "maybe"} {
		kv := composeS3()
		kv[EnvS3UsePathStyle] = v
		if _, err := s3Options(fakeEnv(kv, "h")); err == nil {
			t.Errorf("%s=%s accepted; the driver is always path-style on an endpoint", EnvS3UsePathStyle, v)
		}
	}
}
