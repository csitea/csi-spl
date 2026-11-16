package action

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// Spec 155 2.11 (C40): `spool note add` and spool_note_add are hub-only and
// need the acting agent and the ask; the rest goes to the hub (internal/hub
// TestNotesC35AgentAdd drives it end to end).
func TestNoteAddArgs(t *testing.T) {
	ctx := context.Background()
	ask := "6f1c2b9e-3a4d-4e5f-8a7b-0c1d2e3f4a5b"
	if _, err := NoteAdd(ctx, &config.Config{}, NoteAddArgs{As: "c-007", AskMsgID: ask}); err == nil || !strings.Contains(err.Error(), "hub mode") {
		t.Fatalf("folder mode: %v", err)
	}
	cfg := &config.Config{HubURL: "http://127.0.0.1:1", BoxID: "box-a", KeysDir: t.TempDir(), SpoolRoot: t.TempDir()}
	if _, err := NoteAdd(ctx, cfg, NoteAddArgs{AskMsgID: ask}); err == nil || !strings.Contains(err.Error(), "--as") {
		t.Fatalf("no --as: %v", err)
	}
	if _, err := NoteAdd(ctx, cfg, NoteAddArgs{As: "c-007", AskMsgID: "  "}); err == nil || !strings.Contains(err.Error(), "--ask-msg") {
		t.Fatalf("no --ask-msg: %v", err)
	}
	// A hub that does not answer: the request is built and the dial fails.
	hc := hubclient.New(cfg)
	hc.ReadyTimeout = time.Second
	_, err := NoteAdd(ctx, cfg, NoteAddArgs{As: "c-007", AskMsgID: ask, Title: "t", Priority: 2, Hub: hc})
	var he *hubclient.HubError
	if err == nil || errors.As(err, &he) {
		t.Fatalf("an unreachable hub answered: %v", err)
	}
}

// The note object sent: priority only when set (0 = the hub's default 5), the
// ask lower-cased and trimmed, empty fields left out.
func TestNoteAddRequestShape(t *testing.T) {
	for _, tc := range []struct {
		in   NoteAddArgs
		want string
	}{
		{NoteAddArgs{AskMsgID: " 6F1C2B9E-3A4D-4E5F-8A7B-0C1D2E3F4A5B "},
			`{"ask_msg_id":"6f1c2b9e-3a4d-4e5f-8a7b-0c1d2e3f4a5b"}`},
		{NoteAddArgs{AskMsgID: "a", Title: "T", Priority: 2, Pinned: true, Items: []NoteItemArg{{Text: "x", Done: true}},
			Links: []NoteLinkArg{{Kind: "url", Ref: "https://example.com"}}},
			`{"ask_msg_id":"a","title":"T","pinned":true,"priority":2,"items":[{"text":"x","done":true}],"links":[{"kind":"url","ref":"https://example.com"}]}`},
	} {
		raw, err := noteAddRequest(tc.in)
		if err != nil || string(raw) != tc.want {
			t.Errorf("request = %s (%v), want %s", raw, err, tc.want)
		}
	}
}
