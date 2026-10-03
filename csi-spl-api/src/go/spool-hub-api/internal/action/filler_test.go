package action

import (
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

func TestIsFiller(t *testing.T) {
	filler := []string{
		"ack", "ACK.", "Acked", "acknowledged", "ok", "Okay!", "noted", "got it",
		"Received.", "msg received", "thanks", "Thank you!", "on it", "will do",
		"routing this now", "Received, routing this now.", "c-115: ack",
		"**c-115** received - on it", "@HUM-10 noted", "looking into it now",
		"forwarding it on", "standing by",
	}
	for _, b := range filler {
		if !IsFiller(b) {
			t.Errorf("IsFiller(%q) = false, want true", b)
		}
	}
	value := []string{
		"", "   ", "Received, deployed 1.3.4 to dev and prd.",
		"ok, closing this topic", "ack: the hub returns 502 on /version since 14:02Z",
		"routing this to c-112 (spool-mirror.py owns it)", "thanks to c-107 the bar is fixed",
		"Done: sha 5078e6c7 landed", "check c-115", "no",
	}
	for _, b := range value {
		if IsFiller(b) {
			t.Errorf("IsFiller(%q) = true, want false", b)
		}
	}
}

func TestSendRefusesFillerToHumans(t *testing.T) {
	const hub = "http://127.0.0.1:1" // never dialled: every case is refused first
	for _, in := range []SendArgs{
		{From: "c-1", Channel: "spool-hub-bugs", Body: "Received, routing this now."},
		{From: "c-1", To: "ALL-0", TaskID: "0b9a5b7e-0000-4000-8000-000000000000", Body: "ack"},
		{From: "c-1", To: "HUM-10", Body: "on it"},
		{From: "c-1", To: "HUM-10@box-wui", Body: "noted"},
	} {
		cfg := testkit.NewConfig(t)
		cfg.HubURL = hub
		_, err := Send(cfg, in)
		if err == nil || !strings.HasPrefix(err.Error(), "refused: ") || !strings.Contains(err.Error(), "how-to-post.md") {
			t.Errorf("%+v: got %v, want the filler refusal", in, err)
		}
	}
}

func TestSendFillerBetweenAgentsStillGoes(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "CLE-2")
	if _, err := Send(cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "ack"}); err != nil {
		t.Fatalf("agent-to-agent ack refused: %v", err)
	}
}
