// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// browserMove is a channel the operator workspace's biz owner may move from the
// menu (spec 169 T14): op, <SRC> with the channel, <DST> with the box pinned, and
// hidden, a workspace the owner is not in.
type browserMove struct {
	e                       *env
	op, src, dst, hidden    string
	owner, ch, probe, planU string
	task                    string
}

func browserMoveFixture(t *testing.T, mut ...func(*hub.Options)) *browserMove {
	t.Helper()
	op := newTenantID("op")
	e := chanMoveEnv(t, append([]func(*hub.Options){func(o *hub.Options) { o.OperatorTenant = op }}, mut...)...)
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	b := &browserMove{e: e, op: op, ch: "mvweb-" + uuid4()[:8]}
	b.src, _ = e.tenant()
	b.dst, _ = e.tenant()
	b.hidden, _ = e.tenant()
	b.owner = seatAs(t, e, op, rbac.BizOwner, b.src, rbac.Developer, b.dst, rbac.Developer)
	b.task = moveChannel(t, e, b.src, b.ch, b.owner)
	movePinBox(t, e, b.dst)
	b.probe = "/v1/channels/" + b.ch + "/workspace-move"
	b.planU = b.probe + "/plan"
	return b
}

// seatAs admits one fresh human to each tenant, role pairs: tenant, role, ...
func seatAs(t *testing.T, e *env, pairs ...string) string {
	t.Helper()
	h := e.st.(store.Humans)
	raw := make([]byte, 5)
	rand.Read(raw) //nolint:errcheck
	email := hex.EncodeToString(raw) + "@example.com"
	now := time.Now()
	var hum string
	for i := 0; i+1 < len(pairs); i += 2 {
		if err := h.PutInvite(context.Background(), store.Invite{TenantID: pairs[i], Email: email, Role: pairs[i+1],
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		got, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, pairs[i], store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		hum = got
	}
	return hum
}

func (b *browserMove) plan(t *testing.T, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, b.e, b.src, http.MethodPost, b.planU, as, body)
}

// C29: the probe and the plan answer 403 channel_move_owner to every member of
// <SRC> who is not the operator workspace's biz owner, an admin of it included,
// and to no session with the view door off, and 403 to that owner when not a member of <SRC>; the channel is
// not read first, so a refused caller learns nothing of it. RED CONTROL: answer
// Admin too (channelMoveBrowserOwner) -> the operator workspace's admin is
// allowed and this test fails.
func TestChannelMoveBrowserWhoC29(t *testing.T) {
	b := browserMoveFixture(t)
	if code, out := call(t, b.e, b.src, http.MethodGet, b.probe, b.owner, nil); code != http.StatusOK || out["allowed"] != true {
		t.Fatalf("control, the owner: %d %v", code, out)
	}
	if code, out := b.plan(t, b.owner, map[string]any{"dst": b.dst}); code != http.StatusOK {
		t.Fatalf("control, the owner's plan: %d %v", code, out)
	}
	opAdmin := seatAs(t, b.e, b.op, rbac.Admin, b.src, rbac.Admin)
	srcOwner := seatAs(t, b.e, b.src, rbac.BizOwner, b.dst, rbac.BizOwner)
	notInSrc := seatAs(t, b.e, b.op, rbac.BizOwner, b.dst, rbac.Developer)
	// The operator's owner who is no member of <SRC> meets the session door
	// first (humanTenant's topics.read), so the token is that door's.
	for _, c := range []struct{ name, as, path, token string }{
		{"an admin of the operator workspace", opAdmin, b.probe, "channel_move_owner"},
		{"the biz owner of <SRC>", srcOwner, b.probe, "channel_move_owner"},
		{"the operator's owner, no member of <SRC>", notInSrc, b.probe, "forbidden"},
		{"no session", "", b.probe, "channel_move_owner"},
		{"an unknown channel, refused before it is read", opAdmin, "/v1/channels/nope/workspace-move", "channel_move_owner"},
	} {
		code, out := call(t, b.e, b.src, http.MethodGet, c.path, c.as, nil)
		if code != http.StatusForbidden || out["error"] != c.token || out["targets"] != nil {
			t.Errorf("probe, %s: %d %v", c.name, code, out)
		}
		code, out = call(t, b.e, b.src, http.MethodPost, c.path+"/plan", c.as, map[string]any{"dst": b.dst})
		if code != http.StatusForbidden || out["error"] != c.token || out["blocked"] != nil {
			t.Errorf("plan, %s: %d %v", c.name, code, out)
		}
	}
	for _, c := range []struct {
		name, path, errCode string
		code                int
	}{
		{"an unknown channel", "/v1/channels/nope/workspace-move", "unknown_channel", http.StatusNotFound},
		{"a default channel", "/v1/channels/lobby/workspace-move", "bad_channel", http.StatusBadRequest},
	} {
		if code, out := call(t, b.e, b.src, http.MethodGet, c.path, b.owner, nil); code != c.code || out["error"] != c.errCode {
			t.Errorf("the owner, %s: %d %v", c.name, code, out)
		}
	}
}

// C29 with the view door on (prd, dev): the session door answers no session
// before the owner test, 401 view_door on both routes. RED CONTROL: the door
// off (hub.ViewDoorOff) -> the owner test's 403 channel_move_owner, as in
// TestChannelMoveBrowserWhoC29, and this test fails.
func TestChannelMoveBrowserNoSessionDoorC29(t *testing.T) {
	b := browserMoveFixture(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorToken })
	code, out := call(t, b.e, b.src, http.MethodGet, b.probe, "", nil)
	if code != http.StatusUnauthorized || out["error"] != "view_door" {
		t.Errorf("probe, no session: %d %v", code, out)
	}
	code, out = b.plan(t, "", map[string]any{"dst": b.dst})
	if code != http.StatusUnauthorized || out["error"] != "view_door" {
		t.Errorf("plan, no session: %d %v", code, out)
	}
}

// C30: the targets are the owner's own workspaces but <SRC>; hidden, which the
// owner is not in, is never listed, and a plan into it answers as an unknown
// workspace does. RED CONTROL: list every workspace (channelMoveTargets) -> the
// hidden slug is in the answer and this test fails.
func TestChannelMoveBrowserTargetsC30(t *testing.T) {
	b := browserMoveFixture(t)
	code, out := call(t, b.e, b.src, http.MethodGet, b.probe, b.owner, nil)
	if code != http.StatusOK {
		t.Fatalf("probe: %d %v", code, out)
	}
	var slugs []string
	for _, x := range out["targets"].([]any) {
		tg := x.(map[string]any)
		if tg["name"] == "" {
			t.Errorf("a target with no name: %v", tg)
		}
		slugs = append(slugs, tg["slug"].(string))
	}
	slices.Sort(slugs)
	want := []string{b.op, b.dst}
	slices.Sort(want)
	if !slices.Equal(slugs, want) {
		t.Fatalf("targets %v, want %v (never %s or %s)", slugs, want, b.hidden, b.src)
	}
	_, unknown := b.plan(t, b.owner, map[string]any{"dst": "tnosuchws"})
	code, hidden := b.plan(t, b.owner, map[string]any{"dst": b.hidden})
	if code != http.StatusNotFound || hidden["error"] != "unknown_tenant" || hidden["detail"] != unknown["detail"] {
		t.Fatalf("a plan into a hidden workspace: %d %v, an unknown one: %v", code, hidden, unknown)
	}
	for _, c := range []struct {
		name    string
		body    map[string]any
		errCode string
	}{
		{"<SRC> itself", map[string]any{"dst": b.src}, "bad_tenant"},
		{"an unknown field", map[string]any{"dst": b.dst, "to_name": "x"}, "bad_json"},
		{"a keep that is no HUM id", map[string]any{"dst": b.dst, "keep": []string{"c-001"}}, "bad_detail"},
	} {
		if code, out := b.plan(t, b.owner, c.body); code != http.StatusBadRequest || out["error"] != c.errCode {
			t.Errorf("%s: %d %v", c.name, code, out)
		}
	}
}

// C30, a suspended workspace: the owner is in it, yet it is no target.
// CONTROL: before the suspension <DST> is listed. RED CONTROL: drop
// t.Suspended() (channelMoveTargets) -> the suspended slug is listed.
func TestChannelMoveBrowserTargetsSuspendedC30(t *testing.T) {
	b := browserMoveFixture(t)
	slugs := func() []string {
		t.Helper()
		code, out := call(t, b.e, b.src, http.MethodGet, b.probe, b.owner, nil)
		if code != http.StatusOK {
			t.Fatalf("probe: %d %v", code, out)
		}
		var got []string
		for _, x := range out["targets"].([]any) {
			got = append(got, x.(map[string]any)["slug"].(string))
		}
		return got
	}
	if !slices.Contains(slugs(), b.dst) {
		t.Fatalf("control, <DST> live: %v", slugs())
	}
	if err := b.e.st.(store.OperatorWorkspaces).SetWorkspaceState(context.Background(), b.dst, true, false, time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := slugs(); slices.Contains(got, b.dst) || !slices.Contains(got, b.op) {
		t.Fatalf("targets %v: the suspended %s listed, or the live %s left out", got, b.dst, b.op)
	}
}

// C31, the order of .blocked: the plan's own stops (.refuse) come first, then
// the P2 lines. A channel of the same name in <DST> is a stop, and <DST> has no
// orchestrator seat. RED CONTROL: the P2 lines first (handleChannelMoveBrowserPlan)
// -> this test fails.
func TestChannelMoveBrowserBlockedOrderC31(t *testing.T) {
	b := browserMoveFixture(t)
	if err := b.e.st.CreateChannel(context.Background(), store.Channel{TenantID: b.dst, ChannelID: b.ch, Name: b.ch, CreatedBy: b.owner, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	code, out := b.plan(t, b.owner, map[string]any{"dst": b.dst})
	if code != http.StatusOK {
		t.Fatalf("plan: %d %v", code, out)
	}
	refuse, blocked := anyStrings(out["refuse"]), anyStrings(out["blocked"])
	if len(refuse) != 1 || !strings.Contains(refuse[0], "exists in "+b.dst) {
		t.Fatalf(".refuse: %v", refuse)
	}
	if len(blocked) != 2 || blocked[0] != refuse[0] || !strings.Contains(blocked[1], b.dst+" has no orchestrator seat") {
		t.Fatalf(".blocked %v, want .refuse's line, then the orchestrator line", blocked)
	}
}

// C31: no orchestrator seat in <DST> is in .blocked, and on a store that cannot
// count the set's files (Memory) under a file quota so is the uncounted total; the
// plan's own .refuse holds neither. CONTROL: with an orchestrator seat and no
// quota .blocked is []. RED CONTROL: .blocked = .refuse (the plan's stops alone)
// -> this test fails.
func TestChannelMoveBrowserBlockedC31(t *testing.T) {
	b := browserMoveFixture(t, func(o *hub.Options) { o.QuotaFileBytes = 1 << 30 })
	code, out := b.plan(t, b.owner, map[string]any{"dst": b.dst})
	if code != http.StatusOK {
		t.Fatalf("plan: %d %v", code, out)
	}
	blocked := strings.Join(anyStrings(out["blocked"]), "\n")
	_, counts := b.e.st.(store.ChannelMoveJournals) // Postgres counts: TestChannelMoveBrowserBlockedPostgresC31
	if !strings.Contains(blocked, b.dst+" has no orchestrator seat") || counts == strings.Contains(blocked, "file quota of "+b.dst) {
		t.Fatalf(".blocked: %v", out["blocked"])
	}
	if listLen(out["refuse"]) != 0 {
		t.Fatalf(".refuse is the plan's own: %v", out["refuse"])
	}

	free := browserMoveFixture(t)
	if err := free.e.st.SetRoster(context.Background(), free.dst, "box-a", []string{"c-001"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	code, out = free.plan(t, free.owner, map[string]any{"dst": free.dst})
	if l, isList := out["blocked"].([]any); code != http.StatusOK || !isList || len(l) != 0 {
		t.Fatalf("control, nothing stops it: %d %v", code, out)
	}
	if counts, _ := out["counts"].(map[string]any); counts["messages"] != float64(1) || listLen(out["kept"]) == 0 {
		t.Fatalf("the plan's answer: %v", out)
	}
}

// C31 on Postgres, where the files are counted: a file total over <DST>'s quota
// and no orchestrator seat are both in .blocked, the plan wrote nothing (no
// journal row in <DST>, no post in the operator workspace). CONTROL: with the
// seat only the quota stops it; under a quota the file fits, nothing does.
func TestChannelMoveBrowserBlockedPostgresC31(t *testing.T) {
	for _, c := range []struct {
		name  string
		quota int64
		want  []string
	}{
		{"the file over the quota", 1, []string{"has no orchestrator seat", "do not fit the file quota of "}},
		{"control, the file fits", 1 << 30, []string{"has no orchestrator seat"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := browserMoveFixture(t, func(o *hub.Options) { o.QuotaFileBytes = c.quota })
			if _, ok := b.e.st.(*store.Postgres); !ok {
				t.Skip("the set's file total needs Postgres (SPOOL_TEST_PG_DSN)")
			}
			moveBlobPost(t, &moveFix{e: b.e, src: b.src, ch: b.ch, task: b.task})
			_, out := b.plan(t, b.owner, map[string]any{"dst": b.dst})
			blocked := anyStrings(out["blocked"])
			if len(blocked) != len(c.want) {
				t.Fatalf(".blocked %v, want %d lines naming %v", blocked, len(c.want), c.want)
			}
			for i, w := range c.want {
				if !strings.Contains(blocked[i], w) {
					t.Errorf(".blocked[%d] = %q, want %q", i, blocked[i], w)
				}
			}
			if err := b.e.st.SetRoster(context.Background(), b.dst, "box-a", []string{"c-001"}, time.Now()); err != nil {
				t.Fatal(err)
			}
			_, out = b.plan(t, b.owner, map[string]any{"dst": b.dst})
			if got := anyStrings(out["blocked"]); len(got) != len(c.want)-1 || slices.ContainsFunc(got, func(l string) bool { return strings.Contains(l, "orchestrator") }) {
				t.Errorf("with the seat: %v", got)
			}
			if n := browserMoveRows(t, b, `SELECT count(*) FROM channel_move_journal WHERE tenant_id = $1`, b.dst); n != 0 {
				t.Errorf("the plan wrote %d journal rows in <DST>", n)
			}
			if n := browserMoveRows(t, b, `SELECT count(*) FROM messages WHERE tenant_id = $1`, b.op); n != 0 {
				t.Errorf("the plan wrote %d posts in the operator workspace", n)
			}
		})
	}
}

// browserMoveRows counts under the operator scope, as moveExec writes.
func browserMoveRows(t *testing.T, b *browserMove, sql string, args ...any) int {
	t.Helper()
	ctx := context.Background()
	tx, err := b.e.st.(*store.Postgres).Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := tx.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
