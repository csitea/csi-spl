package spool

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// SPL-1716: a send to a role seat alias of ANOTHER box (g-001@sat, while sat
// runs the seat as c-001) reaches that box's live seat, on both legs the
// sidecar writes: the desk inbox and the fleet inbox `spool recv` reads.
// Before it, the desk minted an orphan g-001 and the fleet copy was dropped.
func TestDeliverRoleAliasReachesLiveSeat(t *testing.T) {
	cfg := newCfg(t)
	fleet := t.TempDir()
	cfg.FleetRoot = fleet
	st := New(cfg)
	for _, d := range []string{filepath.Join(cfg.SpoolRoot, "c-001", "inbox"), filepath.Join(fleet, "c-001", "inbox")} {
		if err := os.MkdirAll(d, 0o775); err != nil {
			t.Fatal(err)
		}
	}
	m, err := st.Compose("g-001", "g-001", "", "task", "spawn-request v1", nil)
	if err != nil {
		t.Fatal(err)
	}
	m = WithFromAgent(m, "box-a")
	if wrote, err := st.Deliver(m); err != nil || !wrote {
		t.Fatalf("deliver: %v %v", wrote, err)
	}
	name := msg.Filename(m)
	for _, root := range []string{cfg.SpoolRoot, fleet} {
		if _, err := os.Stat(filepath.Join(root, "c-001", "inbox", name)); err != nil {
			t.Errorf("%s: the live seat c-001 did not get the g-001 mail: %v", root, err)
		}
		if _, err := os.Lstat(filepath.Join(root, "g-001")); !os.IsNotExist(err) {
			t.Errorf("%s: an orphan g-001 entry was minted (err %v)", root, err)
		}
	}
	got, err := New(cfg).Recv("c-001", true)
	if err != nil || len(got.Messages) != 1 || got.Messages[0].MsgID != m.MsgID {
		t.Fatalf("c-001 recv: %+v %v", got, err)
	}
}

// liveRoleSeat's cases, each with what it must keep.
func TestLiveRoleSeat(t *testing.T) {
	root := t.TempDir()
	mk := func(p string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Join(root, p), 0o775); err != nil {
			t.Fatal(err)
		}
	}
	ln := func(target, name string) {
		t.Helper()
		if err := os.Symlink(target, filepath.Join(root, name)); err != nil {
			t.Fatal(err)
		}
	}
	mk("c-001@sat") // qualified layout: c-001 -> c-001@sat
	ln("c-001@sat", "c-001")
	mk("g-002") // the switched box: the other letters link to the live dir
	ln("g-002", "c-002")
	mk("c-003") // two live dirs of one seat: ambiguous
	mk("a-003")
	mk("c-004") // no role seat
	cases := []struct{ id, want string }{
		{"g-001", "c-001"}, // alias -> the live seat, through the layout link
		{"m-001", "c-001"},
		{"c-001", "c-001"}, // the live id itself
		{"g-002", "g-002"}, // present: kept
		{"c-002", "c-002"}, // a link of the switched box: kept, it already resolves
		{"a-002", "g-002"}, // c-002 and g-002 are ONE dir: not ambiguous
		{"g-003", "g-003"}, // c-003 and a-003 both live: kept
		{"g-004", "g-004"}, // 004 is no role seat
		{"CLE-001", "CLE-001"},
	}
	for _, c := range cases {
		if got := liveRoleSeat(root, c.id); got != c.want {
			t.Errorf("liveRoleSeat(%s) = %s, want %s", c.id, got, c.want)
		}
	}
	// control: no seat at all keeps the id (nothing to resolve to)
	if got := liveRoleSeat(t.TempDir(), "g-001"); got != "g-001" {
		t.Errorf("empty root: got %s", got)
	}
}

// SPL-4031: after a role seat switch (c-001 -> g-001) with no letter links,
// recv, send and the outbox copy of a c-001 id all use g-001's mailbox, and no
// c-001 entry is ever minted. Before it, the first `spool recv --as c-001`
// made c-001/ and from then on every mail to c-001 landed in that orphan.
func TestRoleAliasSendRecvMintNothing(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if err := os.MkdirAll(filepath.Join(cfg.SpoolRoot, "g-001", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	orphan := func(step string) {
		t.Helper()
		if _, err := os.Lstat(filepath.Join(cfg.SpoolRoot, "c-001")); !os.IsNotExist(err) {
			t.Fatalf("%s: an orphan c-001 entry was minted (err %v)", step, err)
		}
	}
	got, err := st.Recv("c-001", false)
	if err != nil || len(got.Messages) != 0 {
		t.Fatalf("recv as c-001 on an empty seat: %+v %v", got, err)
	}
	orphan("recv")
	if !st.KnownLocal("c-001") {
		t.Fatal("KnownLocal(c-001) = false with g-001 live")
	}
	m, err := st.SendKnown("c-001", "c-001", "", "note", "to the seat by its old letter", nil)
	if err != nil {
		t.Fatalf("send to c-001: %v", err)
	}
	orphan("send")
	name := msg.Filename(m)
	for _, box := range []string{"inbox", "outbox"} {
		if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, "g-001", box, name)); err != nil {
			t.Errorf("g-001/%s lacks the c-001 mail: %v", box, err)
		}
	}
	got, err = st.Recv("c-001", true)
	if err != nil || len(got.Messages) != 1 || got.Messages[0].MsgID != m.MsgID {
		t.Fatalf("recv --ack as c-001: %+v %v", got, err)
	}
	orphan("recv --ack")
	if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, "g-001", "archive", name)); err != nil {
		t.Errorf("the ack did not archive into g-001: %v", err)
	}
	if err := st.ensureAgent("c-001"); err != nil {
		t.Fatal(err)
	}
	orphan("ensureAgent")
}

// The control: with no live sibling a role seat id is a fresh agent, and
// recv makes its mailbox as before.
func TestRoleSeatWithoutSiblingStillMinted(t *testing.T) {
	cfg := newCfg(t)
	if _, err := New(cfg).Recv("c-001", false); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(filepath.Join(cfg.SpoolRoot, "c-001", "inbox")); err != nil || !fi.IsDir() {
		t.Fatalf("c-001/inbox not made: %v", err)
	}
}
