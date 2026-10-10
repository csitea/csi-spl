package embedassets

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// harness is testdata/postmessage.test.mjs: it runs both assets in node with
// a fake DOM and fails when message text crosses postMessage, a targetOrigin
// is not exact, a message from another origin or window is taken, or the
// token leaves the frame's localStorage / Bearer header.
const harness = "testdata/postmessage.test.mjs"

func TestFSHoldsTheServedNames(t *testing.T) {
	for _, name := range []string{"loader.js", "chat.html"} {
		b, err := fs.ReadFile(FS, name)
		if err != nil || len(b) == 0 {
			t.Fatalf("%s: %v (%d bytes)", name, err, len(b))
		}
	}
}

// TestEveryPostMessageIsAUIEvent is the check that needs no node: each
// postMessage call sends uiEvent(...) (the one builder, which takes no text)
// to a named origin, never "*".
func TestEveryPostMessageIsAUIEvent(t *testing.T) {
	call := regexp.MustCompile(`postMessage\(([^;]*)\)`)
	for _, name := range []string{"loader.js", "chat.html"} {
		b, _ := fs.ReadFile(FS, name)
		got := call.FindAllStringSubmatch(string(b), -1)
		if len(got) != 1 {
			t.Fatalf("%s: %d postMessage calls, want 1 (the toParent/toFrame helper)", name, len(got))
		}
		args := got[0][1]
		if !strings.HasPrefix(args, "uiEvent(") || strings.Contains(args, `"*"`) || strings.Contains(args, `'*'`) {
			t.Errorf("%s: postMessage(%s): want uiEvent(...) to an exact origin", name, args)
		}
	}
}

func node(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not on PATH: the behaviour harness needs it (TestEveryPostMessageIsAUIEvent still ran)")
	}
	return p
}

func runHarness(t *testing.T, nodeBin, dir string) (string, error) {
	t.Helper()
	abs, err := filepath.Abs(harness)
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(nodeBin, abs, dir).CombinedOutput()
	return string(out), err
}

func TestNoMessageTextCrossesPostMessage(t *testing.T) {
	out, err := runHarness(t, node(t), ".")
	if err != nil {
		t.Fatalf("harness: %v\n%s", err, out)
	}
	t.Log(strings.TrimSpace(out))
}

// TestHarnessRedControls: each mutation breaks one Done item; the harness
// must fail on every one, or it proves nothing.
func TestHarnessRedControls(t *testing.T) {
	bin := node(t)
	controls := []struct{ name, file, from, to string }{
		{"chat sends text", "chat.html", `var m = { spl: 1, ev: ev };`,
			`var m = { spl: 1, ev: ev }; if (latest.length) m.n = latest[latest.length - 1].body;`},
		{"chat targetOrigin *", "chat.html", `postMessage(uiEvent(ev, n), parentOrigin)`, `postMessage(uiEvent(ev, n), "*")`},
		{"chat no origin check", "chat.html", `e.origin !== parentOrigin || `, ``},
		{"chat no source check", "chat.html", ` || e.source !== window.parent`, ``},
		{"chat trusts o over ancestorOrigins", "chat.html", `if (ao && ao.length > 0 && ao[0] !== o) return "";`, ``},
		{"chat token not Bearer", "chat.html", `h["Authorization"] = "Bearer " + tok;`, `h["X-Token"] = tok;`},
		{"chat token not in localStorage", "chat.html", `try { window.localStorage.setItem(k, v); }`, `try { mem[k] = v; }`},
		{"loader targetOrigin *", "loader.js", `postMessage(uiEvent(ev), hub)`, `postMessage(uiEvent(ev), "*")`},
		{"loader no origin check", "loader.js", `e.origin !== hub || `, ``},
		{"loader no source check", "loader.js", ` || e.source !== frame.contentWindow`, ``},
	}
	for _, c := range controls {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			for _, name := range []string{"loader.js", "chat.html"} {
				b, _ := fs.ReadFile(FS, name)
				s := string(b)
				if name == c.file {
					if !strings.Contains(s, c.from) {
						t.Fatalf("control text not in %s: %q", name, c.from)
					}
					s = strings.Replace(s, c.from, c.to, 1)
				}
				if err := os.WriteFile(filepath.Join(dir, name), []byte(s), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if out, err := runHarness(t, bin, dir); err == nil {
				t.Fatalf("harness passed a broken %s:\n%s", c.file, out)
			}
		})
	}
}
