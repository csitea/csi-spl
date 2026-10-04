package main

import (
	"context"
	"os"
	"reflect"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/cloud"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// The pre-076 openBlobStore / openDocsStore / Revision line, verbatim, so the
// gcp path is proved against what dev and prd ran before the factory.
func legacyOpenBlobStore(ctx context.Context, hc *config.Hub) (blob.Store, error) {
	if hc.FilesBucket == "" {
		return blob.Dir{Root: hc.FilesDir}, nil
	}
	g, err := blob.OpenGCS(ctx, hc.FilesBucket)
	if err != nil {
		return nil, err
	}
	return g, nil
}

func legacyOpenDocsStore(ctx context.Context, hc *config.Hub) (blob.Store, error) {
	switch {
	case hc.DocsBucket != "":
		return blob.OpenGCS(ctx, hc.DocsBucket)
	case hc.DocsDir != "":
		return blob.Dir{Root: hc.DocsDir}, nil
	}
	return nil, nil
}

// same reports whether two stores are the same choice: the same type, and for
// a Dir the same root (a GCS client differs per open, its type is the choice).
func same(a, b blob.Store) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	if reflect.TypeOf(a) != reflect.TypeOf(b) {
		return false
	}
	if _, ok := a.(*blob.GCS); ok {
		return true
	}
	return a == b
}

func TestHubGCPPathUnchanged(t *testing.T) {
	t.Setenv("STORAGE_EMULATOR_HOST", "127.0.0.1:1") // a GCS client without ADC; nothing is dialled
	ctx := context.Background()
	cases := []config.Hub{
		{FilesBucket: "spl-files", DocsBucket: "spl-docs", DBDSN: "host=/cloudsql/p:r:i dbname=spool_hub"},
		{FilesBucket: "spl-files", DocsDir: "/docs", DBDSN: "postgres://u@10.0.0.3/spool_hub"},
		{FilesDir: "/files", DBDSN: "memory:"},
		{FilesDir: "/files", DocsDir: "/docs", DBDSN: "postgres://u@pg:5432/d?sslmode=disable"},
	}
	for _, prov := range []string{"", "gcp"} {
		t.Setenv(cloud.EnvProvider, prov)
		t.Setenv("K_REVISION", "spool-hub-00077-xyz")
		cf, err := cloud.New(cloud.OSEnv())
		if err != nil {
			t.Fatalf("provider %q: %v", prov, err)
		}
		if got := cf.Compute().Revision(); got != os.Getenv("K_REVISION") {
			t.Errorf("provider %q: revision %q, legacy %q", prov, got, os.Getenv("K_REVISION"))
		}
		for i := range cases {
			hc := &cases[i]
			nb, err1 := openBlobStore(ctx, cf, hc)
			ob, err2 := legacyOpenBlobStore(ctx, hc)
			if err1 != nil || err2 != nil || !same(nb, ob) {
				t.Errorf("provider %q case %d files: %#v (%v), legacy %#v (%v)", prov, i, nb, err1, ob, err2)
			}
			nd, err1 := openDocsStore(ctx, cf, hc)
			od, err2 := legacyOpenDocsStore(ctx, hc)
			if err1 != nil || err2 != nil || !same(nd, od) {
				t.Errorf("provider %q case %d docs: %#v (%v), legacy %#v (%v)", prov, i, nd, err1, od, err2)
			}
			if dsn, err := cf.Database().DSN(hc.DBDSN); err != nil || dsn != hc.DBDSN {
				t.Errorf("provider %q case %d DSN: %q (%v), legacy %q", prov, i, dsn, err, hc.DBDSN)
			}
		}
	}
}

func TestHubNonePath(t *testing.T) {
	ctx := context.Background()
	t.Setenv(cloud.EnvProvider, "none")
	t.Setenv("K_REVISION", "")
	t.Setenv("SPOOL_VERSION", "")
	cf, err := cloud.New(cloud.OSEnv())
	if err != nil {
		t.Fatal(err)
	}
	host, _ := os.Hostname()
	if got := cf.Compute().Revision(); got != host {
		t.Errorf("none revision %q, want hostname %q", got, host)
	}
	hc := &config.Hub{FilesDir: "/var/lib/spool/files", DBDSN: "postgres://rt@pg:5432/spool_hub?sslmode=disable"}
	if bs, err := openBlobStore(ctx, cf, hc); err != nil || bs != (blob.Dir{Root: hc.FilesDir}) {
		t.Errorf("none files store %#v, %v; want blob.Dir on SPOOL_HUB_FILES_DIR", bs, err)
	}
	if bs, err := openDocsStore(ctx, cf, hc); bs != nil || err != nil {
		t.Errorf("none docs store %#v, %v; want off", bs, err)
	}
	if _, err := openBlobStore(ctx, cf, &config.Hub{FilesBucket: "spl-files"}); err == nil {
		t.Error("none with a files bucket must refuse, not open GCS")
	}
	if _, err := openBlobStore(ctx, cf, &config.Hub{}); err == nil {
		t.Error("no files dir must refuse")
	}
}

func TestHubUnknownProviderRefused(t *testing.T) {
	for _, p := range []string{"azure", "aws"} {
		t.Setenv(cloud.EnvProvider, p)
		if _, err := cloud.New(cloud.OSEnv()); err == nil {
			t.Errorf("SPOOL_CLOUD_PROVIDER=%s started; want a startup error", p)
		}
	}
}
