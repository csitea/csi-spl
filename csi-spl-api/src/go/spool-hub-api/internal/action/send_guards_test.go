package action

import (
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// The send guards checkRef, checkPeers and checkAnswers, one table each and
// one case per arm (refactor round 19 row 07): each refusal word for word,
// each pass with no error.

const (
	sgHub  = "http://127.0.0.1:1" // never dialled: the guards only read cfg.HubURL
	sgUUID = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
)

// sgCfg is a config in hub mode when hub is set, else in local mode.
func sgCfg(hub string) *config.Config { return &config.Config{HubURL: hub} }

// sgErr is the error text, or "" for no error.
func sgErr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestSendGuardCheckRef(t *testing.T) {
	cases := []struct {
		name string
		hub  string
		in   SendArgs
		want string
	}{
		{"no ref", "", SendArgs{}, ""},
		{"local mode", "", SendArgs{Ref: sgUUID}, "--ref needs hub mode ($SPOOL_HUB_URL)"},
		{"not a uuid", sgHub, SendArgs{Ref: "topic-1"}, `--ref must be a topic uuid (task_id), got "topic-1"`},
		{"channel post", sgHub, SendArgs{Ref: sgUUID, Channel: "ops"}, "--ref names the topic a DM is about: drop --channel and reply in the topic with --task"},
		{"answer", sgHub, SendArgs{Ref: sgUUID, Answers: sgUUID}, "--ref names the topic a DM is about: drop --answers"},
		{"a DM", sgHub, SendArgs{Ref: sgUUID, To: "c-002"}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sgErr(checkRef(sgCfg(c.hub), c.in)); got != c.want {
				t.Errorf("checkRef = %q, want %q", got, c.want)
			}
		})
	}
}

func TestSendGuardCheckPeers(t *testing.T) {
	cases := []struct {
		name      string
		hub       string
		in        SendArgs
		want      string
		wantToBox string
	}{
		{"not peers", "", SendArgs{To: "c-002", ToBox: "box-b"}, "", "box-b"},
		{"local mode", "", SendArgs{To: msg.PeersID}, "--to peers needs hub mode ($SPOOL_HUB_URL): a peer seat claims it on the hub", ""},
		{"other box", sgHub, SendArgs{To: msg.PeersID, ToBox: "box-b"}, "--to peers reaches no box (a seat claims it): drop --to-box box-b", "box-b"},
		{"no box", sgHub, SendArgs{To: msg.PeersID}, "", msg.PeersToBox},
		{"the hub's box", sgHub, SendArgs{To: msg.PeersID, ToBox: msg.PeersToBox}, "", msg.PeersToBox},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := c.in
			if got := sgErr(checkPeers(sgCfg(c.hub), &in)); got != c.want {
				t.Errorf("checkPeers = %q, want %q", got, c.want)
			}
			if in.ToBox != c.wantToBox {
				t.Errorf("ToBox = %q, want %q", in.ToBox, c.wantToBox)
			}
		})
	}
}

func TestSendGuardCheckAnswers(t *testing.T) {
	cases := []struct {
		name string
		hub  string
		in   SendArgs
		want string
	}{
		{"no answer", "", SendArgs{}, ""},
		{"if-gen alone", sgHub, SendArgs{IfGen: 3}, "--if-gen needs --answers <msg_id>"},
		{"local mode", "", SendArgs{Answers: sgUUID}, "--answers needs hub mode ($SPOOL_HUB_URL): the hub guards the answer"},
		{"negative if-gen", sgHub, SendArgs{Answers: sgUUID, IfGen: -1}, "--if-gen must be >= 0 (the responsible_gen the seat claimed)"},
		{"channel post", sgHub, SendArgs{Answers: sgUUID, Channel: "ops"}, "--answers replies to one message: drop --channel"},
		{"an answer", sgHub, SendArgs{Answers: sgUUID, IfGen: 2}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sgErr(checkAnswers(sgCfg(c.hub), c.in)); got != c.want {
				t.Errorf("checkAnswers = %q, want %q", got, c.want)
			}
		})
	}
}
