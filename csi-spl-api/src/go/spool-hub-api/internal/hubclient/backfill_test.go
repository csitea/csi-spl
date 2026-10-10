package hubclient

import (
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r7-04: the pure text of the back-fill summary and the fallback poke.

func TestNormChannel(t *testing.T) {
	for in, want := range map[string]string{"general": "lobby", "lobby": "lobby", "ops": "ops", "": ""} {
		if got := normChannel(in); got != want {
			t.Errorf("normChannel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBackfillSummary(t *testing.T) {
	cases := []struct {
		f    wire.Frame
		want string
	}{
		{wire.Frame{Backfill: "general", Count: 1, Topics: 1, From: "c-009"},
			"added to #lobby: 1 earlier message in 1 topic, newest from c-009"},
		{wire.Frame{Backfill: "ops", Count: 7, Topics: 3},
			"added to #ops: 7 earlier messages in 3 topics, newest from ?"},
	}
	for _, tc := range cases {
		tc.f.MsgID, tc.f.TaskID = "m-1", "t-1"
		m := BackfillSummary(tc.f, "c-007")
		if m.Body != tc.want {
			t.Errorf("body %q, want %q", m.Body, tc.want)
		}
		if m.V != msg.V1 || m.Kind != "note" || m.To != "c-007" || m.MsgID != "m-1" || m.TaskID != "t-1" || m.From == "" {
			t.Errorf("summary %+v", m)
		}
	}
}

func TestFallbackPoke(t *testing.T) {
	m := &msg.Message{V: msg.V1, MsgID: "m-1", TaskID: "t-1", From: "HUM-1", Kind: "task",
		Body: "please\n\n  look   at this"}
	dm := FallbackPoke(m, "DM to c-007", "c-007")
	if dm.Body != "unanswered post in DM to c-007 (agent offline): please look at this" {
		t.Errorf("DM poke %q", dm.Body)
	}
	ch := FallbackPoke(m, "#ops", "c-008")
	if !strings.Contains(ch.Body, "(no member agent online)") || ch.To != "c-008" || ch.From != "HUM-1" || ch.Kind != "task" {
		t.Errorf("channel poke %+v", ch)
	}
}

func TestExcerpt(t *testing.T) {
	if got := excerpt(" a  b\nc ", 10); got != "a b c" {
		t.Errorf("short: %q", got)
	}
	long := strings.Repeat("é", 200)
	got := excerpt(long, fallbackExcerpt)
	if got != strings.Repeat("é", fallbackExcerpt)+"…" {
		t.Errorf("long excerpt has %d runes", len([]rune(got)))
	}
}

func TestPlural(t *testing.T) {
	if plural(1, "a", "b") != "a" || plural(0, "a", "b") != "b" || plural(2, "a", "b") != "b" {
		t.Error("plural")
	}
}

func TestCheckWUIKind(t *testing.T) {
	for kind, ok := range map[string]bool{"task": true, "note": true, "result": false, "blocker": false} {
		err := checkWUIKind(&wire.Envelope{FromBox: wuiBox}, &msg.Message{Kind: kind})
		if ok != (err == nil) || (!ok && !errors.Is(err, sign.ErrVerify)) {
			t.Errorf("wui kind %s: %v", kind, err)
		}
	}
	if err := checkWUIKind(&wire.Envelope{FromBox: "box-b"}, &msg.Message{Kind: "result"}); err != nil {
		t.Errorf("a box may send any kind: %v", err)
	}
}
