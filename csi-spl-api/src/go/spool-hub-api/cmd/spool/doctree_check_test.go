package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// TestDocTreeCheck: `spool doctree --check <verb> ...` (SPL-2545) parses the
// verb's arguments as the real run does and never reaches the hub. The desk
// action's DRY_RUN=1 relies on it: `edit <doc> --item <id>` passed a dry run
// and then failed for real with "flag provided but not defined: -item".
func TestDocTreeCheck(t *testing.T) {
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		http.Error(w, "no hub call expected", http.StatusTeapot)
	}))
	t.Cleanup(srv.Close)
	docEnv(t, srv.URL)
	dir := t.TempDir()
	body := filepath.Join(dir, "body.md")
	if err := os.WriteFile(body, []byte("a body\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	from := filepath.Join(dir, "read.json")
	if err := os.WriteFile(from, []byte(`{"items":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out.md")

	for _, args := range [][]string{
		{"create", "--title", "T"},
		{"add", "d1", "--kind", "para", "--text", "t"},
		{"add", "d1", "--kind", "heading", "--title", "H", "--level", "1"},
		{"edit", "d1", "i7", "--field", "body", "--file", body},
		{"edit", "d1", "i7", "--field", "attrs.numbered", "--value", "false", "--json"},
		{"move", "d1", "i7", "--ord", "1"},
		{"delete", "d1"},
		{"rename", "d1", "--title", "Y"},
		{"folder", "--name", "f"},
		{"move-node", "n1"},
		{"read", "d1", "--item", "i7"},
		{"export", "d1", "--from", from, "--out", out},
	} {
		rc, stdout, errOut := captureRun(t, append([]string{"doctree", "--check"}, args...))
		if rc != 0 || stdout != "" {
			t.Errorf("--check %v: rc %d, stdout %q, stderr %q; want 0 and no output", args, rc, stdout, errOut)
		}
	}
	if _, err := os.Stat(out); err == nil {
		t.Errorf("--check export wrote --out %s", out)
	}

	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"edit", "d1", "--item", "i7", "--file", body}, "flag provided but not defined: -item"},
		{[]string{"edit", "d1", "i7", "--body-file", body}, "flag provided but not defined: -body-file"},
		{[]string{"edit", "d1", "--field", "body", "--value", "v"}, "usage: spool doctree edit"},
		{[]string{"edit", "d1", "i7", "--field", "attrs", "--value", "{}"}, "--field is title, body or attrs.<key>"},
		{[]string{"add", "d1", "--kind", "nope"}, "--kind is heading"},
		{[]string{"folder"}, "usage: spool doctree folder"},
		{[]string{"frob"}, "unknown doctree verb"},
		{nil, "usage: spool doctree --check <verb>"},
	} {
		rc, _, errOut := captureRun(t, append([]string{"doctree", "--check"}, c.args...))
		if rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("--check %v: rc %d, stderr %q, want a refusal with %q", c.args, rc, errOut, c.want)
		}
	}

	t.Setenv("SPOOL_DOCTREE_FS", "git")
	if rc, _, errOut := captureRun(t, []string{"doctree", "--check", "create", "--title", "T"}); rc == 0 ||
		!strings.Contains(errOut, "SPOOL_DOCTREE_FS is workspace or repo") {
		t.Errorf("--check with SPOOL_DOCTREE_FS=git: rc %d %q", rc, errOut)
	}
	if n := hits.Load(); n != 0 {
		t.Errorf("--check reached the hub %d time(s)", n)
	}
}
