package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 068 4.2: two peers never both answer one message. A send frame with
// answers=<msg_id> is stored only from that message's responsible seat on its
// responsible_gen (if_gen), and only once; the second answer is refused 409
// naming the first, and a refused answer is not stored. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestAnswerOnce(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	b := e.box(tid, "box-b", "CLE-08")
	c := e.box(tid, "box-c", "CLE-09", "CLE-10")
	e.pin(tid, b)
	e.pin(tid, c)
	// a message to CLE-09: rdb 0110 makes CLE-09@box-c responsible, gen 0
	ask := func() string { return send(t, b, "CLE-08", "CLE-09", "task", "a question", "box-c").MsgID }
	dial := func() *hubclient.Session {
		s, err := c.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { closeWait(s) })
		return s
	}
	reply := func(from string) *wire.Envelope {
		return signedIn(t, c, "box-b", "", "", &msg.Message{V: 1, MsgID: uuidV4(), TaskID: uuidV4(),
			TS: time.Now().UTC().Format(time.RFC3339), From: from, To: "CLE-08", Kind: "result",
			Body: "the answer", Files: []msg.Attachment{}})
	}
	stored := func(env *wire.Envelope) bool {
		m, _ := env.Inner()
		ok, err := e.st.HasMessage(ctx, tid, m.MsgID)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	refused := func(err error, token string) *hubclient.HubError {
		t.Helper()
		var he *hubclient.HubError
		if !errors.As(err, &he) || he.Status != http.StatusConflict || he.Token != token {
			t.Fatalf("want 409 %s, got %v", token, err)
		}
		return he
	}

	// two peers answer one message at once: one 200, one 409 naming the first
	q := ask()
	s1, s2 := dial(), dial()
	envs := []*wire.Envelope{reply("CLE-09"), reply("CLE-09")}
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i, s := range []*hubclient.Session{s1, s2} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = s.SendAnswer(ctx, envs[i], q, 0)
		}()
	}
	wg.Wait()
	win, lose := 0, 1
	if errs[0] != nil {
		win, lose = 1, 0
	}
	if errs[win] != nil {
		t.Fatalf("no answer won: %v / %v", errs[0], errs[1])
	}
	first, _ := envs[win].Inner()
	if he := refused(errs[lose], hub.TokenAnswered); !strings.Contains(he.Detail, first.MsgID) || !strings.Contains(he.Detail, "CLE-09@box-c") {
		t.Fatalf("the 409 does not name the first answer: %q", he.Detail)
	}
	if !stored(envs[win]) || stored(envs[lose]) {
		t.Fatalf("stored: winner %v, loser %v", stored(envs[win]), stored(envs[lose]))
	}
	// a resend of the winner is still a 200; any later answer is a 409
	if _, err := s1.SendAnswer(ctx, envs[win], q, 0); err != nil {
		t.Fatalf("resend: %v", err)
	}
	_, err := s1.SendAnswer(ctx, reply("CLE-10"), q, 0)
	refused(err, hub.TokenAnswered)

	// only the responsible seat, only on its gen; a refusal stores nothing
	q2 := ask()
	other, stale := reply("CLE-10"), reply("CLE-09")
	_, err = s1.SendAnswer(ctx, other, q2, 0)
	if he := refused(err, hub.TokenNotResponsible); !strings.Contains(he.Detail, "CLE-09@box-c") {
		t.Fatalf("the 409 does not name the holder: %q", he.Detail)
	}
	_, err = s1.SendAnswer(ctx, stale, q2, 1)
	refused(err, hub.TokenNotResponsible)
	if stored(other) || stored(stale) {
		t.Fatal("a refused answer was stored")
	}
	if _, err := s1.SendAnswer(ctx, reply("CLE-09"), q2, 0); err != nil {
		t.Fatalf("the holder on its gen: %v", err)
	}

	// an unknown message, and a post that answers itself
	_, err = s1.SendAnswer(ctx, reply("CLE-09"), uuidV4(), 0)
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Status != http.StatusNotFound {
		t.Fatalf("unknown message: %v", err)
	}
	self := reply("CLE-09")
	sm, _ := self.Inner()
	if _, err := s1.SendAnswer(ctx, self, sm.MsgID, 0); !errors.As(err, &he) || he.Status != http.StatusBadRequest {
		t.Fatalf("self answer: %v", err)
	}
	// a post without answers= is untouched by the guard
	if _, err := s1.Send(ctx, reply("CLE-10")); err != nil {
		t.Fatalf("plain post: %v", err)
	}
}
