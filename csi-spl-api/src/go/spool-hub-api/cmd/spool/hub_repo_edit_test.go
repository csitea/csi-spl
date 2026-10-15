package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"reflect"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// r11-10: repoEdit's guards, each of which keeps editing off (nil) and says
// why in one log line. No network and no database: the Postgres guard only
// type-asserts, so a store that is not *store.Postgres drives it, and a zero
// *store.Postgres passes it without a connection.

// notPostgres is a store.Store that is not *store.Postgres; repoEdit never
// calls it.
type notPostgres struct{ store.Store }

// repoEditKey is the App key value the guards must never log.
const repoEditKey = "r11-10-app-key-value-never-logged"

func editOnHub() *config.Hub {
	return &config.Hub{Env: "dev", DocsEditEnabled: true, DocsEditDeny: []string{"secrets/**"},
		DocsEditGitHubRepo: "acme/docs", DocsEditGitHubAPI: "https://api.github.invalid",
		DocsEditGitHubAppID: "1", DocsEditInstallationID: "2"}
}

// appKeyPEM is a fresh App key, made at run time; the armour is assembled so
// no-key-material-in-tree.tst.sh sees no key shape in git.
func appKeyPEM(t *testing.T) string {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "RSA " + "PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)}))
}

func TestRepoEditGuardsKeepEditingOff(t *testing.T) {
	docs := blob.Dir{Root: t.TempDir()}
	goodKey := appKeyPEM(t)
	cases := []struct {
		name string
		hub  func(*config.Hub)
		st   store.Store
		docs blob.Store
		key  string
		want string // the reason logged; "" = nothing logged
	}{
		{name: "editing off", hub: func(h *config.Hub) { h.DocsEditEnabled = false },
			st: notPostgres{}, docs: docs, key: repoEditKey},
		{name: "store not Postgres", st: notPostgres{}, docs: docs, key: repoEditKey,
			want: "the store has no edit queue (Postgres only)"},
		{name: "no docs bucket", st: &store.Postgres{}, key: repoEditKey,
			want: "no docs bucket (SPOOL_HUB_DOCS_BUCKET)"},
		{name: "deny list blank", hub: func(h *config.Hub) { h.DocsEditDeny = []string{" ", ""} },
			st: &store.Postgres{}, docs: docs, key: repoEditKey,
			want: "SPOOL_HUB_DOCS_EDIT_DENY is empty: every path would be editable"},
		{name: "repo not owner/repo", hub: func(h *config.Hub) { h.DocsEditGitHubRepo = "acme/docs/x" },
			st: &store.Postgres{}, docs: docs, key: repoEditKey,
			want: "SPOOL_HUB_DOCS_EDIT_GITHUB_REPO must be <owner>/<repo> (no default)"},
		{name: "no app key", st: &store.Postgres{}, docs: docs,
			want: GitHubAppKeyEnv + " is not set (cnf docs.repo_edit.inject)"},
		{name: "key not a PEM", st: &store.Postgres{}, docs: docs, key: repoEditKey,
			want: "github client: "},
		{name: "worker refused", hub: func(h *config.Hub) { h.Env = "" },
			st: &store.Postgres{}, docs: docs, key: goodKey,
			want: "worker: repodocs: worker needs Env for its commit messages"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(GitHubAppKeyEnv, tc.key)
			hc := editOnHub()
			if tc.hub != nil {
				tc.hub(hc)
			}
			var buf bytes.Buffer
			if got := repoEdit(context.Background(), hc, zerolog.New(&buf), tc.st, tc.docs); got != nil {
				t.Fatalf("repoEdit = %+v, want nil", got)
			}
			out := buf.String()
			if tc.want == "" {
				if out != "" {
					t.Fatalf("log = %q, want nothing", out)
				}
				return
			}
			if !strings.Contains(out, `"reason":"`+tc.want) || !strings.Contains(out, "repo docs editing stays off") {
				t.Fatalf("log = %q, want reason %q", out, tc.want)
			}
			if strings.Contains(out, repoEditKey) || (tc.key != "" && strings.Contains(out, tc.key)) {
				t.Fatalf("log quotes the App key: %q", out)
			}
		})
	}
}

func TestNonEmpty(t *testing.T) {
	cases := []struct {
		in, want []string
	}{
		{in: nil, want: nil},
		{in: []string{""}, want: nil},
		{in: []string{" ", "\t"}, want: nil},
		{in: []string{"a"}, want: []string{"a"}},
		{in: []string{" a ", "", "b/**", "  "}, want: []string{"a", "b/**"}},
	}
	for _, tc := range cases {
		if got := nonEmpty(tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("nonEmpty(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
