package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// backfillEnv is dispatchEnv (browser posts signed by box-wui) with the
// SPL-987 back-fill on.
func backfillEnv(t *testing.T, key ed25519.PrivateKey, max int) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIKey, o.WUIDispatch = key, true
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		o.BackfillMax = max
	})
}

// pokeLog points b's terminal leg at a script that appends one line per poke
// ("<args> | <body>") to a file, and returns a reader of those lines.
func pokeLog(t *testing.T, b *box) func() []string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "pokes")
	script := filepath.Join(dir, "notify.sh")
	body := "#!/bin/sh\nprintf '%s | %s\\n' \"$*\" \"$(cat)\" >> " + log + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	b.cfg.NotifyCmd = script
	return func() []string {
		raw, _ := os.ReadFile(log)
		var out []string
		for _, l := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
			if l != "" {
				out = append(out, l)
			}
		}
		return out
	}
}

func inboxIDs(t *testing.T, b *box, as string) []string {
	var ids []string
	for _, m := range inbox(t, b, as) {
		ids = append(ids, m.MsgID)
	}
	sort.Strings(ids)
	return ids
}

// SPL-987, the owner's case: a human posts into a channel, THEN invites two
// agents. Each agent's inbox receives the earlier posts (and only them: not
// the other channel's, not a DM), its pane is poked ONCE with a summary, a
// re-invite delivers nothing again, and a post after the invite arrives the
// ordinary way.
func TestChannelInviteBackfillsEarlierPosts(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := backfillEnv(t, key, 200)
	tid, _ := e.tenant()
	ctx := context.Background()
	d := e.box(tid, "box-desk", "CLE-35", "AGY-34", "GRK-36")
	pokes := pokeLog(t, d)
	e.pin(tid, d)
	e.pinKey(tid, hub.WUIBox, pub)
	human := "HUM-google-sub-1@" + tid
	now := time.Now()
	for _, ch := range []string{"mobile", "other"} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch,
			Name: ch, CreatedBy: human, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, []string{human}, human, now); err != nil {
			t.Fatal(err)
		}
	}
	s, err := d.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	// Three posts before any agent is in #mobile: two topics, one reply
	// (the WUI reply pane sends no tag; the hub signs the inherited one).
	w := dialMember(t, e, tid, "Owner", human)
	taskA, taskB := "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "2a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
	m1, m2, m3 := "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e", "4c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f", "5c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
	threadFrame(t, w, m1, taskA, "mobile", 1, "why are no agents connected")
	threadFrame(t, w, m2, taskA, "", 0, "the invite should subscribe them")
	threadFrame(t, w, m3, taskB, "mobile", 1, "second topic")
	threadFrame(t, w, "6d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f1a", "7d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f1a",
		"other", 1, "another channel: never back-filled into #mobile")

	for _, ag := range []string{"CLE-35", "AGY-34"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/mobile/agents", human,
			map[string]string{"id": ag, "box": "box-desk"}); code != http.StatusCreated {
			t.Fatalf("invite %s: %d %v", ag, code, out)
		}
	}
	want := m1 + "," + m2 + "," + m3
	for _, ag := range []string{"CLE-35", "AGY-34"} {
		eventually(t, ag+" back-fill", func() bool { return strings.Join(inboxIDs(t, d, ag), ",") == want })
	}
	// The poke names the newest post (its topic and id) and its author, the
	// human's roster id (HUM-<n>).
	summary := func(ag string) string {
		return "--to " + ag + " --from HUM-"
	}
	tail := " --kind note --task " + taskB + " --msg-id " + m3 +
		" --body-stdin | added to #mobile: 3 earlier messages in 2 topics, newest from HUM-"
	eventually(t, "one summary poke per agent", func() bool { return len(pokes()) == 2 })
	got := strings.Join(pokes(), "\n")
	for _, ag := range []string{"CLE-35", "AGY-34"} {
		if !strings.Contains(got, summary(ag)) || strings.Count(got, tail) != 2 {
			t.Fatalf("summary poke for %s missing:\n%s\nwant %s", ag, got, summary(ag))
		}
	}
	if n := len(inbox(t, d, "GRK-36")); n != 0 {
		t.Fatalf("GRK-36 was never invited, reads %d", n)
	}
	bf := e.st.(store.Backfills)
	if p, _ := bf.PendingBackfills(ctx, tid, "box-desk"); len(p) != 0 {
		t.Fatalf("seats still pending after the back-fill: %+v", p)
	}

	// Idempotent: a re-invite neither re-delivers nor re-pokes.
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/channels/mobile/agents", human,
		map[string]string{"id": "CLE-35", "box": "box-desk"}); code != http.StatusCreated {
		t.Fatalf("re-invite: %d", code)
	}
	time.Sleep(200 * time.Millisecond)
	if n := len(pokes()); n != 2 {
		t.Fatalf("re-invite poked again: %v", pokes())
	}

	// After the invite a post is an ordinary live delivery, one poke each.
	m4 := "8e0f1a2b-3c4d-4e5f-8a6b-7c8d9e0f1a2b"
	threadFrame(t, w, m4, taskB, "", 0, "live now")
	for _, ag := range []string{"CLE-35", "AGY-34"} {
		eventually(t, ag+" live post", func() bool { return len(inboxIDs(t, d, ag)) == 4 })
	}
	eventually(t, "live pokes", func() bool { return len(pokes()) == 4 })
	if errs := s.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-desk recv errors: %v", errs)
	}
}

// A seat written straight into the table (the operator path) while the box
// is away is back-filled at the box's next hello. A box whose client does
// not say FeatureBackfill gets nothing and the seat stays owed.
func TestChannelBackfillOnHelloAndOldClient(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := backfillEnv(t, key, 200)
	tid, _ := e.tenant()
	ctx := context.Background()
	d := e.box(tid, "box-desk", "CLE-35")
	pokes := pokeLog(t, d)
	e.pin(tid, d)
	e.pinKey(tid, hub.WUIBox, pub)
	human := "HUM-google-sub-1@" + tid
	now := time.Now()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "mobile",
		Name: "mobile", CreatedBy: human, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "mobile", []string{human}, human, now); err != nil {
		t.Fatal(err)
	}
	w := dialMember(t, e, tid, "Owner", human)
	m1 := "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e"
	threadFrame(t, w, m1, "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "mobile", 1, "before the seat")
	if err := e.st.InviteChannelAgent(ctx, tid, "mobile", "box-desk", "CLE-35", now); err != nil {
		t.Fatal(err)
	}
	bf := e.st.(store.Backfills)

	// An old client: no features in its hello. Nothing is sent, the seat
	// stays pending.
	rb := e.rawBox(tid, d, []string{"CLE-35"}, nil)
	time.Sleep(200 * time.Millisecond)
	if p, _ := bf.PendingBackfills(ctx, tid, "box-desk"); len(p) != 1 {
		t.Fatalf("old client: pending %+v, want the one seat", p)
	}
	rb.c.CloseNow() //nolint:errcheck
	eventually(t, "box offline in Properties", func() bool { return agentState(t, e, tid, "mobile", human) == "CLE-35@box-desk seated" })

	s, err := d.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if got := agentState(t, e, tid, "mobile", human); got != "CLE-35@box-desk online seated" {
		t.Fatalf("Properties agent state: %q", got)
	}
	eventually(t, "hello back-fill", func() bool { return strings.Join(inboxIDs(t, d, "CLE-35"), ",") == m1 })
	eventually(t, "one summary poke", func() bool { return len(pokes()) == 1 })
	if !strings.Contains(pokes()[0], "added to #mobile: 1 earlier message in 1 topic, newest from HUM-") {
		t.Fatalf("summary: %v", pokes())
	}
	if p, _ := bf.PendingBackfills(ctx, tid, "box-desk"); len(p) != 0 {
		t.Fatalf("pending after hello: %+v", p)
	}
}

// Nothing to send still stamps the seat, and pokes nobody.
func TestChannelBackfillEmptyChannel(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := backfillEnv(t, key, 200)
	tid, _ := e.tenant()
	ctx := context.Background()
	d := e.box(tid, "box-desk", "CLE-35")
	pokes := pokeLog(t, d)
	e.pin(tid, d)
	e.pinKey(tid, hub.WUIBox, pub)
	human := "HUM-google-sub-1@" + tid
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "quiet",
		Name: "quiet", CreatedBy: human, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "quiet", []string{human}, human, time.Now()); err != nil {
		t.Fatal(err)
	}
	s, err := d.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/quiet/agents", human,
		map[string]string{"id": "CLE-35", "box": "box-desk"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	bf := e.st.(store.Backfills)
	eventually(t, "stamped", func() bool {
		p, _ := bf.PendingBackfills(ctx, tid, "box-desk")
		return len(p) == 0
	})
	if n := len(pokes()); n != 0 || len(inbox(t, d, "CLE-35")) != 0 {
		t.Fatalf("empty channel poked %v", pokes())
	}
}

// agentState is GET /v1/channels/{ch}/members' agents as "id@box [online]
// [seated]" lines (SPL-987: the Properties dialog shows it).
func agentState(t *testing.T, e *env, tid, ch, as string) string {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/channels/"+ch+"/members", as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET members: %d %v", code, out)
	}
	var lines []string
	ags, _ := out["agents"].([]any)
	for _, a := range ags {
		m, _ := a.(map[string]any)
		l := fmtAgent(m)
		if m["online"] == true {
			l += " online"
		}
		if m["seated"] == true {
			l += " seated"
		}
		lines = append(lines, l)
	}
	return strings.Join(lines, "\n")
}
