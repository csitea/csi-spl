package hubclient

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit/fakehub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r7-04: the send paths no other test drove - an answer (never queued), a
// channel post, a re-announce.

func outboxHas(t *testing.T, c *Client, m *msg.Message) bool {
	t.Helper()
	_, err := os.Stat(filepath.Join(c.Cfg.SpoolRoot, m.From, "outbox", msg.Filename(m)))
	return err == nil
}

func TestSendAnswerMessage(t *testing.T) {
	h := &opsHub{}
	c := opsClient(t, h)
	src := filepath.Join(t.TempDir(), "r.txt")
	if err := os.WriteFile(src, []byte("the report"), 0o644); err != nil {
		t.Fatal(err)
	}
	a, err := files.PutFile(c.Cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	m, err := spool.New(c.Cfg).Compose("c-007", "c-009", "", "result", "answered", []msg.Attachment{a})
	if err != nil {
		t.Fatal(err)
	}
	d, err := c.SendAnswerMessage(context.Background(), m, "box-b", "q-msg", 4)
	if err != nil || d != wire.DeliverySent {
		t.Fatalf("delivery %q err %v", d, err)
	}
	s := h.frames(wire.TSend)
	if len(s) != 1 || s[0].Answers != "q-msg" || s[0].IfGen != 4 || wire.InnerMsgID(s[0].Env) != m.MsgID {
		t.Fatalf("send frames %+v", s)
	}
	h.mu.Lock()
	up := string(h.files[a.FileID])
	h.mu.Unlock()
	if up != "the report" {
		t.Errorf("attachment not uploaded before the answer: %q", up)
	}
	if !outboxHas(t, c, m) {
		t.Error("an accepted answer is not in the outbox")
	}
	if p, _ := c.Pending(); len(p) != 0 {
		t.Errorf("an answer was queued: %v", p)
	}
}

// A refused answer writes no outbox copy and leaves nothing pending.
func TestSendAnswerMessageRefused(t *testing.T) {
	h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
		return []wire.Frame{{Type: wire.TError, MsgID: wire.InnerMsgID(f.Env), Error: wire.TokenAnswered, Status: 409}}
	}}
	c := opsClient(t, h)
	m, err := spool.New(c.Cfg).Compose("c-007", "c-009", "", "result", "late", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.SendAnswerMessage(context.Background(), m, "box-b", "q-msg", 4)
	var he *HubError
	if !errors.As(err, &he) || he.Token != wire.TokenAnswered {
		t.Fatalf("got %v", err)
	}
	if outboxHas(t, c, m) {
		t.Error("a refused answer reached the outbox")
	}
	if _, err := c.SendAnswerMessage(context.Background(), m, "not a box", "q", 1); err == nil {
		t.Error("an invalid --to-box went through")
	}
}

// A channel post is signed to box-wui with the channel tag, written to the
// sender's outbox only, and flushed through a dial (fakehub records it).
func TestSendChannelTyped(t *testing.T) {
	hub := fakehub.New(t)
	root := t.TempDir()
	cfg := &config.Config{SpoolRoot: filepath.Join(root, "spool"), KeysDir: filepath.Join(root, "keys"),
		PinsDir: filepath.Join(root, "spool", "pins")}
	hub.Wire(t, cfg, "box-a")
	c := New(cfg)
	m, err := spool.New(cfg).Compose("c-007", "ALL-0", "", "note", "to the channel", nil)
	if err != nil {
		t.Fatal(err)
	}
	d, err := c.SendChannelTyped(context.Background(), m, "ops", "HUM-1")
	if err != nil || d != wire.DeliverySent {
		t.Fatalf("delivery %q err %v", d, err)
	}
	sends := hub.Sends()
	if len(sends) != 1 || sends[0].TypedBy != "HUM-1" {
		t.Fatalf("hub sends %+v", sends)
	}
	e, err := wire.ParseEnvelope(sends[0].Env)
	if err != nil {
		t.Fatal(err)
	}
	if e.ToBox != wuiBox || e.Channel != "ops" || e.FromBox != "box-a" {
		t.Errorf("envelope to %s #%s from %s", e.ToBox, e.Channel, e.FromBox)
	}
	if !outboxHas(t, c, m) {
		t.Error("the post is not in the sender's outbox")
	}
	if p, _ := c.Pending(); len(p) != 0 {
		t.Errorf("a sent post stayed pending: %v", p)
	}
}

// Announce re-sends the dir scan and the channel list on a role=box session.
func TestAnnounce(t *testing.T) {
	h := &opsHub{}
	c, s := dialOps(t, h, wire.RoleBox)
	if err := os.MkdirAll(filepath.Join(c.Cfg.SpoolRoot, "c-011", "inbox"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := s.Announce(context.Background()); err != nil {
		t.Fatal(err)
	}
	var got []wire.Frame
	for i := 0; i < 100 && len(got) == 0; i++ {
		got = h.frames(wire.TAnnounce)
		if len(got) == 0 {
			waitABit()
		}
	}
	if len(got) != 1 || strings.Join(got[0].Agents, ",") != "c-007,c-008,c-011" {
		t.Fatalf("announce frames %+v", got)
	}
}

func waitABit() { time.Sleep(10 * time.Millisecond) }
