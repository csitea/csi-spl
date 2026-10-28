package mcp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// SPL-3959: a lane's spool_send on a workspace desk's spool root is refused
// (c-423's task 9bb91e55 was written into c-189's desk inbox, reported
// "local", and read by nobody); the same send on the fleet-shaped root is
// delivered, and the desk's own seats still send there.
func TestLaneSendOnDeskRootIsRefused(t *testing.T) {
	desk := filepath.Join(t.TempDir(), "cloud", "prd", "desk", "acme", "box1", "spool")
	fleet := filepath.Join(t.TempDir(), "spool-hub")
	send := map[string]any{"to": "c-423", "task_id": task, "kind": "result", "body": "the result"}
	inbox := func(root string) int {
		n, _ := filepath.Glob(filepath.Join(root, "c-423", "inbox", "*.json"))
		return len(n)
	}

	// RED CONTROL: lane c-189 on the desk root.
	cs, cfg := seated(t, "c-189")
	cfg.SpoolRoot, cfg.PinsDir = desk, filepath.Join(desk, "pins")
	testkit.Agents(t, cfg, "c-189", "c-423")
	out, isErr := callText(t, cs, "spool_send", send)
	if !isErr || !strings.Contains(out, "SPL-3959") || !strings.Contains(out, "Nothing was sent") || !strings.Contains(out, desk) {
		t.Fatalf("lane send on a desk root: isErr=%v %q, want a refusal naming the root", isErr, out)
	}
	if n := inbox(desk); n != 0 {
		t.Fatalf("a refused send wrote %d message(s) into the desk inbox", n)
	}
	if n, _ := filepath.Glob(filepath.Join(desk, "c-189", "outbox", "*.json")); len(n) != 0 {
		t.Fatalf("a refused send wrote %d outbox message(s)", len(n))
	}

	// The same send on the fleet-shaped root is delivered.
	cfg.SpoolRoot, cfg.PinsDir = fleet, filepath.Join(fleet, "pins")
	testkit.Agents(t, cfg, "c-189", "c-423")
	if out, isErr := callText(t, cs, "spool_send", send); isErr || inbox(fleet) != 1 {
		t.Fatalf("lane send on the fleet root: isErr=%v %q, inbox %d, want delivered", isErr, out, inbox(fleet))
	}

	// The desk's own seats still send on the desk root: a role seat, and the
	// id a desk alias links to (RSP-01 -> c-684). A lane-shaped link
	// (c-002 -> g-002) seats nobody.
	if err := os.Symlink("c-684", filepath.Join(desk, "RSP-01")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("c-189", filepath.Join(desk, "c-777")); err != nil {
		t.Fatal(err)
	}
	for i, seat := range []string{"c-001", "c-684"} {
		cs, cfg := seated(t, seat)
		cfg.SpoolRoot, cfg.PinsDir = desk, filepath.Join(desk, "pins")
		testkit.Agents(t, cfg, seat)
		if out, isErr := callText(t, cs, "spool_send", send); isErr || inbox(desk) != i+1 {
			t.Fatalf("desk seat %s on its desk root: isErr=%v %q, inbox %d", seat, isErr, out, inbox(desk))
		}
	}
	if deskSeat(desk, "c-189") {
		t.Fatal("a lane-shaped link (c-777 -> c-189) made c-189 a desk seat")
	}
}

// SPL-3959 review: a symlink to a desk root, or a //, /. or /.. spelling of
// one (also through the link), is the desk root too: refused, nothing written.
func TestLaneSendOnDeskRootSpellingIsRefused(t *testing.T) {
	base := t.TempDir()
	desk := filepath.Join(base, "cloud", "prd", "desk", "acme", "box1", "spool")
	if err := os.MkdirAll(desk, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "via-link")
	if err := os.Symlink(desk, link); err != nil {
		t.Fatal(err)
	}
	send := map[string]any{"to": "c-423", "task_id": task, "kind": "result", "body": "the result"}
	// link + "/../via-link": EvalSymlinks fails on it, the store's Join
	// cleans it back to the link (g-007 re-review, msg 9d41b399).
	for _, root := range []string{desk + "//", desk + "/.", desk + "/../spool", link, link + "/../via-link"} {
		cs, cfg := seated(t, "c-189")
		cfg.SpoolRoot, cfg.PinsDir = root, filepath.Join(desk, "pins")
		testkit.Agents(t, cfg, "c-189", "c-423")
		if out, isErr := callText(t, cs, "spool_send", send); !isErr || !strings.Contains(out, "Nothing was sent") {
			t.Fatalf("lane send on %s: isErr=%v %q, want a refusal", root, isErr, out)
		}
	}
	if n, _ := filepath.Glob(filepath.Join(desk, "*", "*", "*.json")); len(n) != 0 {
		t.Fatalf("refused sends wrote %d message(s) under the desk root", len(n))
	}
}

// deskRootResolved resolves the deepest existing ancestor: a root not made
// yet under a link to a desk's box dir is that desk's spool root.
func TestDeskRootResolvedNotYetMade(t *testing.T) {
	base := t.TempDir()
	box := filepath.Join(base, "cloud", "prd", "desk", "acme", "box1")
	if err := os.MkdirAll(box, 0o755); err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(box)
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "box-link")
	if err := os.Symlink(box, link); err != nil {
		t.Fatal(err)
	}
	if got, want := deskRootResolved(link+"/spool"), filepath.Join(real, "spool"); got != want {
		t.Fatalf("deskRootResolved(%s/spool) = %s, want %s", link, got, want)
	}
	if !deskRootRe.MatchString(filepath.ToSlash(deskRootResolved(link + "/./spool/"))) {
		t.Fatal("a not-yet-made spool root under a link to a desk box dir is not matched as a desk root")
	}
}
