package spool

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// retire writes registry.retired.tsv rows as agent-id-retire.sh does: the
// registry row's 5 columns plus retired-utc, ago before now.
func retire(t *testing.T, root string, ago time.Duration, ids ...string) {
	t.Helper()
	at := time.Now().UTC().Add(-ago).Format(retiredLayout)
	var b strings.Builder
	for _, id := range ids {
		b.WriteString(id + "\tclaude\t%5\t/x\t20261002T080000Z\t" + at + "\n")
	}
	f, err := os.OpenFile(filepath.Join(root, "registry.retired.tsv"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o664)
	if err != nil {
		if err := os.MkdirAll(root, 0o775); err != nil {
			t.Fatal(err)
		}
		if f, err = os.OpenFile(filepath.Join(root, "registry.retired.tsv"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o664); err != nil {
			t.Fatal(err)
		}
	}
	defer f.Close()
	if _, err := f.WriteString(b.String()); err != nil {
		t.Fatal(err)
	}
}

// specs/061 3.6: a send to an id retired inside the quarantine bounces to the
// sender as a reject naming the retired id; it does not queue.
func TestSendKnownBouncesARetiredIDInQuarantine(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	retire(t, cfg.SpoolRoot, 2*time.Hour, "c-004")
	_, err := st.SendKnown("c-005", "c-004", "task-1", "task", "do X", nil)
	if !errors.Is(err, ErrRetiredRecipient) || ExitCode(err) != 4 {
		t.Fatalf("got %v (exit %d), want retired_agent exit 4", err, ExitCode(err))
	}
	if _, serr := os.Stat(filepath.Join(cfg.SpoolRoot, "c-004")); !os.IsNotExist(serr) {
		t.Fatal("the bounce minted a mailbox for the retired id: the message queued for the next holder")
	}
	res, err := st.Recv("c-005", false)
	if err != nil || len(res.Messages) != 1 {
		t.Fatalf("the sender's inbox: %v, %+v", err, res)
	}
	r := res.Messages[0]
	if r.Kind != "reject" || r.From != "c-004" || r.To != "c-005" || r.TaskID != "task-1" ||
		!strings.HasPrefix(r.Body, "c-004 retired at ") || !strings.Contains(r.Body, "does not queue") {
		t.Fatalf("the reject: %+v", r)
	}
	if outs, _ := os.ReadDir(st.dir("c-005", "outbox")); len(outs) != 0 {
		t.Fatalf("an undelivered message is in the sender's outbox: %d", len(outs))
	}
}

// Past the quarantine the send behaves as before: an id nothing holds is
// unknown (exit 3), and a new holder of the number receives the message.
func TestSendKnownAfterTheQuarantineIsAsBefore(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	retire(t, cfg.SpoolRoot, 25*time.Hour, "c-004")
	if _, err := st.SendKnown("c-005", "c-004", "", "note", "hi", nil); !errors.Is(err, ErrUnknownRecipient) {
		t.Fatalf("expired quarantine: %v, want unknown_local_agent as before", err)
	}
	if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, "c-005", "inbox")); !os.IsNotExist(err) {
		t.Fatal("an expired quarantine still bounced a reject")
	}
	// A new holder: its dir exists, so even inside a quarantine it receives.
	retire(t, cfg.SpoolRoot, time.Hour, "c-006")
	if err := os.MkdirAll(filepath.Join(cfg.SpoolRoot, "c-006", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SendKnown("c-005", "c-006", "", "note", "hi", nil); err != nil {
		t.Fatalf("a live holder of the number: %v", err)
	}
}

func TestRetiredInQuarantineRows(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	now := time.Now().UTC()
	retire(t, cfg.SpoolRoot, 30*time.Hour, "c-004", "sat: c-007@sat")
	retire(t, cfg.SpoolRoot, time.Hour, "c-004")
	if at, ok := st.RetiredInQuarantine("c-004", now); !ok || now.Sub(at) > 2*time.Hour {
		t.Fatalf("the newest retirement wins: %v %v", at, ok)
	}
	if _, ok := st.RetiredInQuarantine("c-007", now); ok {
		t.Fatal("30 h ago is past the default 24 h")
	}
	cfg.IDQuarantineH = 48
	if _, ok := st.RetiredInQuarantine("c-007", now); !ok {
		t.Fatal("SPOOL_ID_QUARANTINE_H=48 holds a 30 h old retirement; the tag and @box are ignored")
	}
	if _, ok := st.RetiredInQuarantine("c-00", now); ok {
		t.Fatal("a prefix matched")
	}
}

// TestSendKnownQuarantineReadsTheStoreClock: SendKnown measures the
// quarantine on the store's clock, the one BounceRetired uses. Inside it the
// send bounces; with the clock stepped past its end the id is unknown.
// CONTROL: the same retired row both times; only the clock moves.
func TestSendKnownQuarantineReadsTheStoreClock(t *testing.T) {
	cfg := newCfg(t)
	st := New(cfg)
	retire(t, cfg.SpoolRoot, time.Hour, "c-004")
	at := time.Now()
	st.clock = func() time.Time { return at }
	if _, err := st.SendKnown("c-005", "c-004", "", "note", "hi", nil); !errors.Is(err, ErrRetiredRecipient) {
		t.Fatalf("inside the quarantine: %v, want ErrRetiredRecipient", err)
	}
	at = at.Add(cfg.IDQuarantine())
	if _, err := st.SendKnown("c-005", "c-004", "", "note", "hi", nil); !errors.Is(err, ErrUnknownRecipient) {
		t.Fatalf("past the quarantine on the store clock: %v, want ErrUnknownRecipient", err)
	}
}

// TestComposeStampsTheStoreClock: a composed message's ts is the store's clock.
func TestComposeStampsTheStoreClock(t *testing.T) {
	st := New(newCfg(t))
	st.clock = func() time.Time { return time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC) }
	m, err := st.Compose("c-005", "c-004", "", "note", "hi", nil)
	if err != nil || m.TS != "2020-01-02T03:04:05Z" {
		t.Fatalf("compose: ts %q %v, want 2020-01-02T03:04:05Z", m.TS, err)
	}
}
