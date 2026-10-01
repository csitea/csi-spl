package spool

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// specs/058 N1 (O3): a local send to an id this root does not know is refused
// before anything is written. The control: the old Send still mints the
// orphan inbox, which is the loss this guards against.
func TestSendKnownRefusesAnOrphanInbox(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	_, err := st.SendKnown("CLE-07", "CLE-100004", "", "note", "to the other machine", nil)
	if !errors.Is(err, ErrUnknownRecipient) || ExitCode(err) != 3 {
		t.Fatalf("got %v (exit %d), want unknown_local_agent exit 3", err, ExitCode(err))
	}
	for _, id := range []string{"CLE-100004", "CLE-07"} {
		if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, id)); !os.IsNotExist(err) {
			t.Fatalf("a refused send wrote %s/%s", cfg.SpoolRoot, id)
		}
	}
	// control: the unchecked Send is what made the orphan
	if _, err := st.Send("CLE-07", "CLE-100005", "", "note", "x", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, "CLE-100005", "inbox")); err != nil {
		t.Fatalf("control: Send no longer mints the inbox, so this test proves nothing: %v", err)
	}
}

func TestSendKnownAcceptsDirOrRegistry(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	if err := os.MkdirAll(filepath.Join(cfg.SpoolRoot, "CLE-08"), 0o775); err != nil {
		t.Fatal(err)
	}
	reg := "CLE-09\tclaude\t%1\t/x\t20260101T000000Z\nCLE-10@sat\tclaude\t%2\t/y\t20260101T000000Z\n"
	if err := os.WriteFile(filepath.Join(cfg.SpoolRoot, "registry.tsv"), []byte(reg), 0o664); err != nil {
		t.Fatal(err)
	}
	for _, to := range []string{"CLE-08", "CLE-09", "CLE-10"} {
		if _, err := st.SendKnown("CLE-07", to, "", "note", "hi", nil); err != nil {
			t.Fatalf("%s: %v", to, err)
		}
	}
	if _, err := st.SendKnown("CLE-07", "CLE-1", "", "note", "hi", nil); !errors.Is(err, ErrUnknownRecipient) {
		t.Fatalf("CLE-1 is a prefix of no registry id but was accepted: %v", err)
	}
}

// Two simulated machines' halves on one disk: the desk root the hub sidecar
// delivers into, and the harness root the agent reads (SPOOL_FLEET_ROOT).
func TestDeliverCopiesAgentDMIntoFleetRoot(t *testing.T) {
	cfg := newCfg(t)
	fleet := t.TempDir()
	cfg.FleetRoot = fleet
	st := New(cfg)
	if err := os.MkdirAll(filepath.Join(fleet, "CLE-001", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	m, err := st.Compose("CLE-100004", "CLE-001", "", "result", "report from the satellite", nil)
	if err != nil {
		t.Fatal(err)
	}
	if wrote, err := st.Deliver(m); err != nil || !wrote {
		t.Fatalf("deliver: %v %v", wrote, err)
	}
	name := msg.Filename(m)
	if _, err := os.Stat(filepath.Join(fleet, "CLE-001", "inbox", name)); err != nil {
		t.Fatalf("no fleet copy: %v", err)
	}
	fcfg := *cfg
	fcfg.SpoolRoot, fcfg.FleetRoot = fleet, ""
	fst := New(&fcfg)
	got, err := fst.Recv("CLE-001", true)
	if err != nil || len(got.Messages) != 1 || got.Messages[0].MsgID != m.MsgID {
		t.Fatalf("recv in the fleet root: %v %+v", err, got)
	}
	// a hub redelivery after the agent acked: shown once, not again
	if wrote, err := st.Deliver(m); err != nil || wrote {
		t.Fatalf("redeliver: %v %v", wrote, err)
	}
	if ents, _ := os.ReadDir(filepath.Join(fleet, "CLE-001", "inbox")); len(ents) != 0 {
		t.Fatalf("redelivery re-copied an acked message: %d files", len(ents))
	}
}

func TestDeliverFleetCopyRetriedOnRedelivery(t *testing.T) {
	cfg := newCfg(t)
	fleet := t.TempDir()
	st := New(cfg)
	m, _ := st.Compose("CLE-100004", "CLE-001", "", "note", "x", nil)
	if _, err := st.Deliver(m); err != nil { // fleet root not set yet: desk copy only
		t.Fatal(err)
	}
	cfg.FleetRoot = fleet
	if err := os.MkdirAll(filepath.Join(fleet, "CLE-001", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	if wrote, err := st.Deliver(m); err != nil || wrote {
		t.Fatalf("redeliver: %v %v", wrote, err)
	}
	if _, err := os.Stat(filepath.Join(fleet, "CLE-001", "inbox", msg.Filename(m))); err != nil {
		t.Fatalf("the redelivery did not complete the missing fleet copy: %v", err)
	}
}

func TestDeliverFleetCopyRefusals(t *testing.T) {
	cfg := newCfg(t)
	fleet := t.TempDir()
	cfg.FleetRoot = fleet
	st := New(cfg)
	if err := os.MkdirAll(filepath.Join(fleet, "CLE-001", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	human, _ := st.Compose("HUM-4", "CLE-001", "", "note", "from the WUI", nil)
	if _, err := st.Deliver(human); err != nil {
		t.Fatal(err)
	}
	// a channel mention: delivered to CLE-001 although msg.to is someone else
	mention, _ := st.Compose("CLE-100004", "CLE-002", "", "note", "@CLE-001 look", nil)
	if _, err := st.DeliverTo(mention, "CLE-001"); err != nil {
		t.Fatal(err)
	}
	if ents, _ := os.ReadDir(filepath.Join(fleet, "CLE-001", "inbox")); len(ents) != 0 {
		t.Fatalf("a human DM or a mention was copied: %d files", len(ents))
	}
	// no harness inbox for the recipient: never an orphan in the fleet root
	stray, _ := st.Compose("CLE-100004", "CLE-555", "", "note", "x", nil)
	if _, err := st.Deliver(stray); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(fleet, "CLE-555")); !os.IsNotExist(err) {
		t.Fatalf("an orphan dir was made in the fleet root")
	}
}
