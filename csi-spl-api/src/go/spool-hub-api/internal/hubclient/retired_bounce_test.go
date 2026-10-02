package hubclient

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func retireHere(t *testing.T, root, id string, ago time.Duration) {
	t.Helper()
	if err := os.MkdirAll(root, 0o775); err != nil {
		t.Fatal(err)
	}
	row := id + "\tclaude\t%5\t/x\t20261002T080000Z\t" + time.Now().UTC().Add(-ago).Format("20060102T150405Z") + "\n"
	if err := os.WriteFile(filepath.Join(root, "registry.retired.tsv"), []byte(row), 0o664); err != nil {
		t.Fatal(err)
	}
}

// specs/061 3.6, hub mode: a message for an id THIS box retired inside the
// quarantine - addressed to this box, or announced by no other box - bounces
// to the sender as a reject; nothing is queued for the hub either.
func TestSendMessageBouncesARetiredLocalID(t *testing.T) {
	for _, toBox := range []string{"box-a", ""} {
		c := testClient(t)
		retireHere(t, c.Cfg.SpoolRoot, "c-004", time.Hour)
		m, err := spool.New(c.Cfg).Compose("c-005", "c-004", "", "task", "do X", nil)
		if err != nil {
			t.Fatal(err)
		}
		_, err = c.SendMessage(context.Background(), m, toBox)
		if !errors.Is(err, spool.ErrRetiredRecipient) {
			t.Fatalf("to_box %q: %v, want retired_agent", toBox, err)
		}
		res, _ := spool.New(c.Cfg).Recv("c-005", false)
		if res == nil || len(res.Messages) != 1 || res.Messages[0].Kind != "reject" || res.Messages[0].From != "c-004" {
			t.Fatalf("to_box %q: the sender's inbox holds %+v, want one reject from c-004", toBox, res)
		}
		if left, _ := c.Pending(); len(left) != 0 {
			t.Fatalf("to_box %q: a bounced message is pending for the hub: %v", toBox, left)
		}
		if _, err := os.Stat(filepath.Join(c.Cfg.SpoolRoot, "c-004")); !os.IsNotExist(err) {
			t.Fatalf("to_box %q: the retired id got a mailbox", toBox)
		}
	}
}

// Once the quarantine is over, a send addressed to this box is delivered as
// before (the local inbox); and a retired id on ANOTHER box is not this box's
// to bounce.
func TestSendMessageAfterQuarantineOrElsewhereIsAsBefore(t *testing.T) {
	c := testClient(t)
	retireHere(t, c.Cfg.SpoolRoot, "c-004", 25*time.Hour)
	m, err := spool.New(c.Cfg).Compose("c-005", "c-004", "", "task", "do X", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d, err := c.SendMessage(context.Background(), m, "box-a"); err != nil || d != wire.DeliveryLocal {
		t.Fatalf("expired quarantine: delivery=%q err=%v, want local", d, err)
	}
	c2 := testClient(t)
	retireHere(t, c2.Cfg.SpoolRoot, "c-004", time.Hour)
	m2, _ := spool.New(c2.Cfg).Compose("c-005", "c-004", "", "task", "do X", nil)
	if _, err := c2.SendMessage(context.Background(), m2, "box-b"); errors.Is(err, spool.ErrRetiredRecipient) {
		t.Fatal("a send addressed to another box bounced on this box's retirement")
	}
}
