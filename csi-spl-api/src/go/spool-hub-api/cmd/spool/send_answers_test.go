package main

import (
	"io"
	"os"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 068: `spool send` takes --answers / --if-gen and --to peers, and a
// shell caller can branch on the hub's answer-once refusals: exit 5 names
// "answered", exit 6 "not_responsible" on stderr. The round trip against a
// hub is hub.TestSendAnswers; this pins the flags and the exit mapping.
func TestSendAnswersFlagsAndExits(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "c-001", "c-120")
	stderr := func(fn func() int) (int, string) {
		r, w, _ := os.Pipe()
		old := os.Stderr
		os.Stderr = w
		code := fn()
		w.Close()
		os.Stderr = old
		b, _ := io.ReadAll(r)
		return code, string(b)
	}
	base := []string{"--from", "c-001", "--to", "c-120", "--kind", "result", "--body", "x"}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--if-gen", "2"}, "--if-gen needs --answers"},
		{[]string{"--answers", "0b6f0c55-8a1f-4d5e-9a4c-2f0d4c6e7a10", "--if-gen", "2"}, "--answers needs hub mode"},
		{[]string{"--to", "peers"}, "--to peers needs hub mode"},
	} {
		code, out := stderr(func() int { return cmdSend(cfg, append(append([]string{}, base...), c.args...)) })
		if code != 1 || !strings.Contains(out, c.want) {
			t.Errorf("%v: exit %d %q, want 1 naming %q", c.args, code, out, c.want)
		}
	}
	for _, c := range []struct {
		token string
		want  int
	}{{wire.TokenAnswered, action.ExitAnswered}, {wire.TokenNotResponsible, action.ExitNotResponsible}, {"conflict_msg", 1}} {
		code, out := stderr(func() int { return fail(&hubclient.HubError{Token: c.token, Status: 409, Detail: "d"}) })
		if code != c.want || !strings.Contains(out, c.token) {
			t.Errorf("%s: exit %d %q, want %d naming it", c.token, code, out, c.want)
		}
	}
	if action.ExitAnswered == action.ExitNotResponsible {
		t.Fatal("answered and not_responsible share an exit code")
	}
}
