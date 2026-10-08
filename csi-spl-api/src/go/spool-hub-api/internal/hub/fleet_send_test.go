package hub_test

// specs/058 N1: agent-to-agent messages and reports across the machines of one
// fleet. Each simulated machine has a harness root (what its agents read with
// `spool recv`, SPOOL_FLEET_ROOT) and a desk box with its own id. A send to an
// agent of the OTHER machine goes through the hub (what spool-send.sh's relay
// does) and lands in that machine's harness inbox; a local send never mints
// an orphan inbox; reports follow the fleet lease's orch holder.

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// harness gives b a fleet root holding an inbox for each agent, the way the
// spawn harness lays out /var/spool-hub, and returns that root's local config.
func harness(t *testing.T, b *box, agents ...string) *config.Config {
	t.Helper()
	root := t.TempDir()
	for _, a := range agents {
		for _, d := range []string{"inbox", "outbox", "archive"} {
			if err := os.MkdirAll(filepath.Join(root, a, d), 0o775); err != nil {
				t.Fatal(err)
			}
		}
	}
	b.cfg.FleetRoot = root
	return &config.Config{SpoolRoot: root, KeysDir: filepath.Join(t.TempDir(), "keys"),
		PinsDir: filepath.Join(root, "pins"), LogLevel: "error", LogFormat: "console"}
}

func harnessBodies(t *testing.T, cfg *config.Config, as string) []string {
	t.Helper()
	res, err := spool.New(cfg).Recv(as, false)
	if err != nil {
		t.Fatalf("recv %s: %v", as, err)
	}
	var out []string
	for _, m := range res.Messages {
		out = append(out, m.Body)
	}
	return out
}

// orchHolder is spool_fleet_orchestrator over the hub row: "<ID>@<box>" ->
// the id and its box. The box is what makes the send unambiguous: the role id
// CLE-001 exists on every machine.
func orchHolder(t *testing.T, b *box) (string, string) {
	t.Helper()
	got := leaseCall(t, b, action.LeaseArgs{Fleet: "main", Role: "orch"})
	id, box, _ := strings.Cut(got.Holder, "@")
	return id, box
}

func TestFleetSendAcrossMachinesAndReportsFollowTheLease(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	home := e.box(tid, "box-desk", "CLE-001", "CLE-77913")
	sat := e.box(tid, "box-desk-sat", "CLE-001", "CLE-100004") // the standby CLE-001
	e.pin(tid, home)
	e.pin(tid, sat)
	homeH := harness(t, home, "CLE-001", "CLE-77913")
	satH := harness(t, sat, "CLE-001", "CLE-100004")
	ctx := context.Background()
	for _, b := range []*box{home, sat} {
		s, err := b.c.Dial(ctx, wire.RoleBox)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(s)
	}
	eventually(t, "each machine sees the other's agents on the hub roster", func() bool {
		a, errA := home.c.ResolveToBox("CLE-100004", "")
		b, errB := sat.c.ResolveToBox("CLE-77913", "")
		return errA == nil && errB == nil && a == "box-desk-sat" && b == "box-desk"
	})

	// O3: the satellite's LOCAL send to the box machine's orchestrator is
	// refused and writes nothing; before N1 it reported "local" and was lost.
	_, err := action.Send(satH, action.SendArgs{From: "CLE-100004", To: "CLE-77913", Kind: "result", Body: "lost"})
	if !errors.Is(err, spool.ErrUnknownRecipient) || action.ExitCode(err) != 3 {
		t.Fatalf("local send to another machine's agent: %v (exit %d), want unknown_local_agent exit 3", err, action.ExitCode(err))
	}
	if _, err := os.Stat(filepath.Join(satH.SpoolRoot, "CLE-77913")); !os.IsNotExist(err) {
		t.Fatalf("the refused send minted an orphan inbox on the satellite")
	}

	// both ways through the hub (the relay leg), into the harness inboxes
	if out := send(t, sat, "CLE-100004", "CLE-77913", "note", "sat -> home", ""); out.Delivery != wire.DeliverySent {
		t.Fatalf("sat -> home delivery %q", out.Delivery)
	}
	if out := send(t, home, "CLE-77913", "CLE-100004", "note", "home -> sat", ""); out.Delivery != wire.DeliverySent {
		t.Fatalf("home -> sat delivery %q", out.Delivery)
	}
	eventually(t, "one message each way in the harness inboxes", func() bool {
		return len(harnessBodies(t, homeH, "CLE-77913")) == 1 && len(harnessBodies(t, satH, "CLE-100004")) == 1
	})

	// reports while the orch lease flips: home holds it, then the satellite
	// (a bare CLE-001 is on both boxes: the hub cannot place it)
	if _, err := action.SendCtx(ctx, sat.cfg, action.SendArgs{From: "CLE-100004", To: "CLE-001", Kind: "note", Body: "x", Hub: sat.c}); err == nil || !strings.Contains(err.Error(), "ambiguous_to_box") {
		t.Fatalf("a bare role id across machines: %v, want ambiguous_to_box", err)
	}
	if got := leaseCall(t, home, action.LeaseArgs{Fleet: "main", Role: "orch", Holder: "CLE-001@box-desk", IfGen: 0}); !got.Won {
		t.Fatalf("home takes orch: %+v", got)
	}
	id, bx := orchHolder(t, sat)
	send(t, sat, "CLE-100004", id, "result", "report 1", bx)
	if got := leaseCall(t, sat, action.LeaseArgs{Fleet: "main", Role: "orch", Holder: "CLE-001@box-desk-sat", IfGen: 1}); !got.Won {
		t.Fatalf("sat takes orch: %+v", got)
	}
	id, bx = orchHolder(t, home)
	send(t, home, "CLE-77913", id, "result", "report 2", bx)
	eventually(t, "each report at the orchestrator holding the lease when it was sent", func() bool {
		return strings.Join(harnessBodies(t, homeH, "CLE-001"), ",") == "report 1" &&
			strings.Join(harnessBodies(t, satH, "CLE-001"), ",") == "report 2"
	})
	// routed once: nothing landed on the machine that did not hold the agent
	for _, c := range []struct {
		cfg *config.Config
		id  string
	}{{homeH, "CLE-100004"}, {satH, "CLE-77913"}} {
		if _, err := os.Stat(filepath.Join(c.cfg.SpoolRoot, c.id)); !os.IsNotExist(err) {
			t.Fatalf("%s appeared in the other machine's harness root", c.id)
		}
	}
	// a re-sync replays nothing into the harness inboxes
	if _, err := home.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(harnessBodies(t, homeH, "CLE-77913")); n != 1 {
		t.Fatalf("re-sync doubled the harness copy: %d", n)
	}
}
