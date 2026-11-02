// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const moveURL = "/v1/operator/channel-moves"

// chanMoveEnv is an env with the operator allow-list on; "good" is the service
// account's token, "other-sa" an identity not on the list.
func chanMoveEnv(t *testing.T, mut ...func(*hub.Options)) *env {
	t.Helper()
	return rbacEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "other-sa":
				return "intruder@example-dev.iam.gserviceaccount.com", nil
			}
			return "", errors.New("token rejected")
		}
	}}, mut...)...)
}

// movePost stores one message with an inner body, as a browser send would.
func movePost(t *testing.T, e *env, tenant, id, task, channel, from, body string, at time.Time) {
	t.Helper()
	inner := `{"body":` + quoteJSON(body) + `,"files":[],"from":"` + from + `","kind":"note","msg_id":"` + id +
		`","task_id":"` + task + `","to":"ALL-0","ts":"` + at.Format(time.RFC3339) + `","v":1}`
	raw := `{"channel":"` + channel + `","from_box":"box-wui","msg":` + inner + `,"sig":"","to_box":"box-wui"}`
	m := store.Message{TenantID: tenant, MsgID: id, TaskID: task, Channel: channel, TS: at, IsParent: 1,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: body,
		Files: []byte(`[]`), Msg: []byte(inner), Env: []byte(raw), ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

func quoteJSON(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(s) + `"`
}

// moveChannel makes the channel with one post and answers that post's task.
func moveChannel(t *testing.T, e *env, tenant, channel, from string) string {
	t.Helper()
	ctx := context.Background()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tenant, ChannelID: channel, Name: channel, CreatedBy: from, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tenant, channel, []string{from}, from, time.Now()); err != nil {
		t.Fatal(err)
	}
	task := uuid4()
	movePost(t, e, tenant, uuid4(), task, channel, "GRK-03", "a topic", time.Now().UTC().Truncate(time.Second))
	return task
}

func chanMoveBody(op, src, ch, dst string, extra map[string]any) map[string]any {
	b := map[string]any{"op": op, "env": "dev", "src": src, "channel": ch, "dst": dst, "mode": "move", "to_name": ch,
		"move_id": nil, "go_msg_id": nil, "step": nil, "detail": nil}
	for k, v := range extra {
		b[k] = v
	}
	return b
}

func listLen(v any) int {
	l, _ := v.([]any)
	return len(l)
}

// The plan path: the catalogue through the store, every stop once in .refuse
// (the shell adds .refuse, .shared and .missing_desks), the name check of P2,
// the kept list, and the doors. CONTROLS: an unknown channel, a default channel,
// copy, a bad op, an unknown field, no token, an identity not on the list, and a
// Host naming another workspace.
func TestChannelMovePlanEndpoint(t *testing.T) {
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	hum := seat(t, e, src, rbac.Admin)
	task := moveChannel(t, e, src, "proj-x", hum)

	code, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("plan", src, "proj-x", dst, nil))
	if code != http.StatusOK {
		t.Fatalf("plan: %d %v", code, out)
	}
	counts, _ := out["counts"].(map[string]any)
	if counts["messages"] != float64(1) || counts["channels"] != float64(1) {
		t.Fatalf("counts: %v", counts)
	}
	if listLen(out["refuse"]) != 0 || listLen(out["kept"]) == 0 || listLen(out["members_lost"]) != 1 {
		t.Fatalf("plan: %v", out)
	}
	for _, k := range []string{"refuse", "mentions", "seats", "members_lost", "kept"} {
		if _, isList := out[k].([]any); !isList {
			t.Fatalf("%s is not a list: %v", k, out[k])
		}
	}

	// A shared issue (C7) is one stop, once: .shared and .missing_desks stay out.
	is := e.st.(store.Issues)
	other := moveChannel(t, e, src, "stays", hum)
	if i, err := is.CreateIssue(context.Background(), store.Issue{TenantID: src, Title: "shared", TaskID: task, Discussions: []string{task}, CreatedBy: hum}, time.Now()); err != nil {
		t.Fatal(err)
	} else if _, err := e.st.(store.IssueDiscussions).LinkIssueDiscussion(context.Background(), src, i.Number, other, hum, time.Now()); err != nil {
		t.Fatal(err)
	}
	_, out = opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("plan", src, "proj-x", dst, nil))
	if listLen(out["refuse"]) != 1 || !strings.HasPrefix(out["refuse"].([]any)[0].(string), "shared issue ") {
		t.Fatalf("a shared issue: %v", out["refuse"])
	}
	if _, has := out["shared"]; has {
		t.Fatalf(".shared would count it twice: %v", out)
	}
	if _, has := out["missing_desks"]; has {
		t.Fatalf(".missing_desks would count it twice: %v", out)
	}

	// P2: the name must be free in <DST>; TO_NAME frees it.
	if err := e.st.CreateChannel(context.Background(), store.Channel{TenantID: dst, ChannelID: "proj-x", Name: "proj-x", CreatedBy: hum, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	_, out = opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("plan", src, "proj-x", dst, nil))
	if !strings.Contains(strings.Join(anyStrings(out["refuse"]), "\n"), "channel proj-x exists in "+dst) {
		t.Fatalf("the name is taken: %v", out["refuse"])
	}
	_, out = opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("plan", src, "proj-x", dst, map[string]any{"to_name": "proj-y"}))
	if strings.Contains(strings.Join(anyStrings(out["refuse"]), "\n"), "exists in") {
		t.Fatalf("TO_NAME: %v", out["refuse"])
	}

	for _, c := range []struct {
		name, host, token string
		body              map[string]any
		code              int
		errCode           string
	}{
		{"unknown channel", src, "good", chanMoveBody("plan", src, "nope", dst, nil), http.StatusNotFound, "unknown_channel"},
		{"a default channel", src, "good", chanMoveBody("plan", src, "lobby", dst, nil), http.StatusBadRequest, "bad_channel"},
		{"own workspace", src, "good", chanMoveBody("plan", src, "proj-x", src, nil), http.StatusBadRequest, "bad_tenant"},
		{"unknown target", src, "good", chanMoveBody("plan", src, "proj-x", "tnosuchws", nil), http.StatusNotFound, "unknown_tenant"},
		{"copy", src, "good", chanMoveBody("plan", src, "proj-x", dst, map[string]any{"mode": "copy"}), http.StatusNotImplemented, "not_built"},
		{"bad mode", src, "good", chanMoveBody("plan", src, "proj-x", dst, map[string]any{"mode": "swap"}), http.StatusBadRequest, "bad_mode"},
		{"bad op", src, "good", chanMoveBody("drop", src, "proj-x", dst, nil), http.StatusBadRequest, "bad_op"},
		{"unknown field", src, "good", chanMoveBody("plan", src, "proj-x", dst, map[string]any{"force": true}), http.StatusBadRequest, "bad_json"},
		{"no token", src, "", chanMoveBody("plan", src, "proj-x", dst, nil), http.StatusUnauthorized, "no_token"},
		{"not on the list", src, "other-sa", chanMoveBody("plan", src, "proj-x", dst, nil), http.StatusForbidden, "not_operator"},
		{"another workspace's host", dst, "good", chanMoveBody("plan", src, "proj-x", dst, nil), http.StatusForbidden, "tenant_mismatch"},
	} {
		code, out := opCall(t, e, c.host, http.MethodPost, moveURL, c.token, c.body)
		if code != c.code || out["error"] != c.errCode {
			t.Errorf("%s: %d %v, want %d %s", c.name, code, out, c.code, c.errCode)
		}
	}
}

func anyStrings(v any) []string {
	l, _ := v.([]any)
	out := make([]string, 0, len(l))
	for _, s := range l {
		out = append(out, s.(string))
	}
	return out
}

// C15: a step or a mark needs the owner's GO for THIS channel and target, and is
// refused before anything happens. The answer that stands reaches not_built
// today, which is past the check. Each row below is one way the GO is not it;
// the row with the right GO is the control that the refusals are not blanket.
func TestChannelMoveGoC15(t *testing.T) {
	op := newTenantID("op")
	e := chanMoveEnv(t, func(o *hub.Options) { o.OperatorTenant = op })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	owner := seat(t, e, op, rbac.BizOwner)
	dev := seat(t, e, op, rbac.Developer)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	other, _ := e.tenant()
	otherOwner := seat(t, e, other, rbac.BizOwner)
	moveChannel(t, e, src, "proj-x", seat(t, e, src, rbac.Admin))

	at := time.Now().UTC().Truncate(time.Second)
	form := func(text string) (string, string) {
		id, task := uuid4(), uuid4()
		movePost(t, e, op, id, task, "", "c-001", text, at)
		return id, task
	}
	formID, task := form("Move " + src + "/proj-x to " + dst + "?\n```poll\nGo?\n(GO) Go\n```")
	answer := func(tenant, from, task, body string) string {
		id := uuid4()
		movePost(t, e, tenant, id, task, "", from, body, at)
		return id
	}
	good := "Poll: " + formID + "\nAnswer: GO — Go"
	wrongCh, wrongChT := form("Move " + src + "/proj-x-2 to " + dst + "?")
	wrongDst, wrongDstT := form("Move " + src + "/proj-x to " + other + "?")
	_, otherTopic := form("another topic")

	for _, c := range []struct {
		name string
		id   any
		want string
	}{
		{"no id", nil, "go_required"},
		{"not a uuid", "go", "go_required"},
		{"no such message", uuid4(), "go_required"},
		{"a lane agent's answer", answer(op, "c-204", task, good), "go_required"},
		{"a developer's answer", answer(op, dev, task, good), "go_required"},
		{"the owner of another workspace", answer(other, otherOwner, task, good), "go_required"},
		{"answered Hold", answer(op, owner, task, "Poll: "+formID+"\nAnswer: HLD — Hold"), "go_required"},
		{"wants to discuss", answer(op, owner, task, "Chat: wants to discuss\nPoll: "+formID), "go_required"},
		{"plain words", answer(op, owner, task, "go ahead"), "go_required"},
		{"the form is in another topic", answer(op, owner, otherTopic, good), "go_required"},
		{"a GO for a longer channel id", answer(op, owner, wrongChT, "Poll: "+wrongCh+"\nAnswer: GO — Go"), "go_required"},
		{"a GO for another target", answer(op, owner, wrongDstT, "Poll: "+wrongDst+"\nAnswer: GO — Go"), "go_required"},
		{"the owner's GO", answer(op, owner, task, good), "not_built"},
	} {
		for _, opName := range []string{"step", "mark"} {
			_, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody(opName, src, "proj-x", dst, map[string]any{"go_msg_id": c.id, "step": "P1"}))
			if out["error"] != c.want {
				t.Errorf("%s (%s): %v, want %s", c.name, opName, out, c.want)
			}
		}
	}
	// A copied post has a human author and box-wui, the shape of a member's own
	// post (T11), so a copy of the owner's GO reads as his GO unless the row says
	// otherwise. The answer and the form each; "the owner's GO" above is the control.
	copiedAns := answer(op, owner, task, good)
	moveCopied(t, e, op, copiedAns)
	cForm, cTask := form("Move " + src + "/proj-x to " + dst + "?")
	moveCopied(t, e, op, cForm)
	for what, id := range map[string]string{"a copied answer": copiedAns, "a copied form": answer(op, owner, cTask, "Poll: "+cForm+"\nAnswer: GO — Go")} {
		_, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("step", src, "proj-x", dst, map[string]any{"go_msg_id": id, "step": "P1"}))
		if out["error"] != "go_required" {
			t.Errorf("%s: %v", what, out)
		}
	}
	// A step carrying a new name is refused, never moved under the old one: T5
	// does not build TO_NAME.
	_, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("step", src, "proj-x", dst,
		map[string]any{"go_msg_id": answer(op, owner, task, good), "step": "P1", "to_name": "proj-y"}))
	if out["error"] != "not_built" || !strings.Contains(out["detail"].(string), "TO_NAME") {
		t.Errorf("TO_NAME on a step: %v", out)
	}
	// Plan needs no GO (8.1: the orchestrator seat may run it).
	if code, out := opCall(t, e, src, http.MethodPost, moveURL, "good", chanMoveBody("plan", src, "proj-x", dst, nil)); code != http.StatusOK {
		t.Errorf("plan without a GO: %d %v", code, out)
	}
}

// moveCopied marks a stored row as a copy (rdb 0250), as T11 writes it.
func moveCopied(t *testing.T, e *env, tenant, msgID string) {
	t.Helper()
	if m, ok := e.st.(*store.Memory); ok {
		m.MarkMessageCopied(tenant, msgID)
		return
	}
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE messages SET copied_from = $3 WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID, uuid4())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// moveRedirect holds one redirect row, as P4 writes it.
func moveRedirect(t *testing.T, e *env, src, task, dst string, age, ttl time.Duration) {
	t.Helper()
	now := time.Now().UTC()
	if m, ok := e.st.(*store.Memory); ok {
		m.PutChannelMoveRedirect(src, task, store.ChannelMoveRedirect{Dst: dst, NewRef: task, MoveID: uuid4(), ExpiresAt: now.Add(ttl - age)})
		return
	}
	err := pgx.BeginFunc(context.Background(), e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(), `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `INSERT INTO channel_move_redirects (src_tenant_id, kind, old_ref, dst_tenant_id, new_ref, move_id, created_at, expires_at)
			VALUES ($1, 'task', $2, $3, $2, $4, $5, $6)`, src, task, dst, uuid4(), now.Add(-age), now.Add(ttl-age))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// taskRows counts a task's rows in one workspace.
func taskRows(t *testing.T, e *env, tenant, task string) int {
	t.Helper()
	got, err := e.st.ViewTopic(context.Background(), tenant, store.TopicMsgQuery{TaskID: task, Limit: 50, Now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	return len(got)
}

// boxSend sends one post from b over a cli session; the frame or the refusal.
func boxSend(t *testing.T, e *env, b *box, tenant, task, to, channel string) (wire.Frame, *hubclient.HubError) {
	t.Helper()
	ctx := context.Background()
	b.c.Cfg.HubURL = e.url(tenant)
	sess, err := b.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	f, err := sess.Send(ctx, signedIn(t, b, "box-b", channel, "", chanMsg(task, to, "note", "into the moved topic")))
	var he *hubclient.HubError
	if errors.As(err, &he) {
		return f, he
	}
	if err != nil {
		t.Fatal(err)
	}
	return f, nil
}

// moveBoxes pins the sender in the first workspace, and in the others a box of
// the same id with its own key: a key is live in one workspace only (rdb 0154).
func moveBoxes(t *testing.T, e *env, tenants ...string) *box {
	t.Helper()
	a := e.box(tenants[0], "box-a", "GRK-03")
	e.pin(tenants[0], a)
	for i, tid := range tenants {
		if i > 0 {
			e.pin(tid, e.box(tid, "box-a", "GRK-03"))
		}
		e.pin(tid, e.box(tid, "box-b", "c-120"))
	}
	return a
}

// C8, a lane's post to a moved task at <SRC>: never a row anywhere. A live row
// refuses with the destination link and nothing else (C13); an expired one with
// 404 and no link. The sender's key is live in <SRC>, so it cannot be pinned in
// <DST> and <DST> could not verify the envelope. CONTROLS: with no redirect row
// the same post does open a <SRC> topic (the red of C8, and proof the counts can
// move); a task with rows here is at home whatever its old row says.
func TestChannelMovePostC8(t *testing.T) {
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	a := moveBoxes(t, e, src, dst)
	const hour = time.Hour
	const month = 30 * 24 * hour

	fresh := uuid4()
	if f, he := boxSend(t, e, a, src, fresh, "c-120", ""); he != nil || f.Delivery == "" {
		t.Fatalf("control, a new task: %v %+v", he, f)
	}
	if taskRows(t, e, src, fresh) != 1 {
		t.Fatal("control: the post did not open a topic")
	}

	live := uuid4()
	moveRedirect(t, e, src, live, dst, hour, month)
	_, he := boxSend(t, e, a, src, live, "c-120", "")
	if he == nil || he.Status != http.StatusConflict || he.Token != wire.TokenTopicMoved {
		t.Fatalf("live: %+v", he)
	}
	if ten, link, ok := wire.ParseMovedDetail(he.Detail); !ok || ten != dst || !strings.HasSuffix(link, "/t/"+live) {
		t.Fatalf("live, the destination a client reads: %q", he.Detail)
	}
	if s, d := taskRows(t, e, src, live), taskRows(t, e, dst, live); s != 0 || d != 0 {
		t.Fatalf("live: %d rows in <SRC>, %d in <DST>", s, d)
	}

	expired := uuid4()
	moveRedirect(t, e, src, expired, dst, month+hour, month)
	_, he = boxSend(t, e, a, src, expired, "c-120", "")
	if he == nil || he.Status != http.StatusNotFound || he.Token != "topic_moved" || strings.Contains(he.Detail, dst) {
		t.Fatalf("expired: %+v", he)
	}
	if s, d := taskRows(t, e, src, expired), taskRows(t, e, dst, expired); s != 0 || d != 0 {
		t.Fatalf("expired: %d rows in <SRC>, %d in <DST>", s, d)
	}

	// Deliver (hub-originated, a task id from the request): the same refusal.
	viaBus := uuid4()
	moveRedirect(t, e, src, viaBus, dst, hour, month)
	if _, err := e.srv.Deliver(context.Background(), src, signedIn(t, a, "box-b", "", "", chanMsg(viaBus, "c-120", "note", "a ci log"))); err == nil {
		t.Fatal("Deliver stored a post to a moved task")
	}
	if s, d := taskRows(t, e, src, viaBus), taskRows(t, e, dst, viaBus); s != 0 || d != 0 {
		t.Fatalf("Deliver: %d rows in <SRC>, %d in <DST>", s, d)
	}
	viaBusNew := uuid4()
	if _, err := e.srv.Deliver(context.Background(), src, signedIn(t, a, "box-b", "", "", chanMsg(viaBusNew, "c-120", "note", "a ci log"))); err != nil {
		t.Fatalf("control, Deliver of a new task: %v", err)
	}

	home := uuid4()
	movePost(t, e, src, uuid4(), home, "", "GRK-03", "still here", time.Now().UTC())
	moveRedirect(t, e, src, home, dst, hour, month)
	if _, he := boxSend(t, e, a, src, home, "c-120", ""); he != nil {
		t.Fatalf("a task with rows here: %+v", he)
	}
	if n := taskRows(t, e, dst, home); n != 0 {
		t.Fatalf("a task with rows here went to <DST>: %d", n)
	}
}

// C8, the browser's post and the old permalink. A browser post is signed as a
// <SRC> member and cannot go on under <DST>: it is refused, with the link only.
// CONTROLS: a brand-new task posts; an unknown task reads as before.
func TestChannelMoveBrowserAndPermalinkC8(t *testing.T) {
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	hum := seat(t, e, src, rbac.Admin)
	moveChannel(t, e, src, "proj-x", hum)
	c := dialMember(t, e, src, "", hum)

	send := func(task string) map[string]any {
		wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": uuid4(), "task_id": task, "kind": "note", "body": "hello", "channel": "proj-x"}) //nolint:errcheck
		return readType(t, c, "ack")
	}
	if f := send(uuid4()); f["type"] != "ack" {
		t.Fatalf("control, a new topic: %v", f)
	}
	const month = 30 * 24 * time.Hour
	live, expired := uuid4(), uuid4()
	moveRedirect(t, e, src, live, dst, time.Hour, month)
	moveRedirect(t, e, src, expired, dst, month+time.Hour, month)

	f := send(live)
	if f["type"] != "error" || f["error"] != "topic_moved" || !strings.Contains(f["detail"].(string), dst) || !strings.Contains(f["detail"].(string), "/t/"+live) ||
		strings.Contains(f["detail"].(string), "proj-x") {
		t.Fatalf("live: %v", f)
	}
	f = send(expired)
	if f["type"] != "error" || f["error"] != "topic_moved" || strings.Contains(f["detail"].(string), dst) {
		t.Fatalf("expired: %v", f)
	}
	if s, d := taskRows(t, e, src, live), taskRows(t, e, dst, live); s != 0 || d != 0 {
		t.Fatalf("a browser post: %d rows in <SRC>, %d in <DST>", s, d)
	}

	code, out := call(t, e, src, http.MethodGet, "/v1/view/topics/"+live, hum, nil)
	if code != http.StatusNotFound || out["error"] != "topic_moved" || !strings.HasSuffix(out["moved_to"].(string), "/t/"+live) || !strings.Contains(out["moved_to"].(string), dst) {
		t.Fatalf("permalink, live: %d %v", code, out)
	}
	code, out = call(t, e, src, http.MethodGet, "/v1/view/topics/"+expired, hum, nil)
	if _, has := out["moved_to"]; code != http.StatusNotFound || out["error"] != "topic_moved" || has {
		t.Fatalf("permalink, expired: %d %v", code, out)
	}
	if code, out = call(t, e, src, http.MethodGet, "/v1/view/topics/"+uuid4(), hum, nil); out["error"] == "topic_moved" {
		t.Fatalf("control, an unknown task: %d %v", code, out)
	}
}

// movedCounter counts the send path's reads and can fail them.
type movedCounter struct {
	*store.Memory
	moveReads, firstReads atomic.Int64
	failMove, failTopic   atomic.Bool
}

func (c *movedCounter) TaskMoveState(ctx context.Context, tenant, task string) (store.TaskMoveState, error) {
	c.moveReads.Add(1)
	if c.failMove.Load() {
		return store.TaskMoveState{}, errors.New("planted read failure")
	}
	return c.Memory.TaskMoveState(ctx, tenant, task)
}

func (c *movedCounter) TaskFirstChannel(ctx context.Context, tenant, task string) (string, error) {
	c.firstReads.Add(1)
	return c.Memory.TaskFirstChannel(ctx, tenant, task)
}

func (c *movedCounter) TopicChannel(ctx context.Context, tenant, task string) (string, error) {
	if c.failTopic.Load() {
		return "", errors.New("planted read failure")
	}
	return c.Memory.TopicChannel(ctx, tenant, task)
}

// counterEnv is chanMoveEnv on Memory with the counting store in front of it.
func counterEnv(t *testing.T) (*env, *movedCounter) {
	t.Helper()
	t.Setenv("SPOOL_TEST_PG_DSN", "")
	mc := &movedCounter{}
	e := chanMoveEnv(t, func(o *hub.Options) {
		mc.Memory = o.Store.(*store.Memory)
		o.Store = mc
	})
	return e, mc
}

// Condition 2: a post to a topic that exists spends no new read. A box post
// into a channel topic reads no redirect at all; a post to an existing DM reads
// it in the one read that replaced boxLevel's TaskFirstChannel, so its reads are
// what they were on bf92fe1b6: 2 TaskFirstChannel (boxLevel, channelOf), now
// 1 + 1 TaskMoveState. A browser reply into a rooted topic reads no redirect.
// The control is the new-task line: the counter does see a redirect read.
func TestChannelMoveSendReadsCounted(t *testing.T) {
	e, mc := counterEnv(t)
	src, _ := e.tenant()
	a := moveBoxes(t, e, src)
	hum := seat(t, e, src, rbac.Admin)
	roomTask := moveChannel(t, e, src, "proj-x", hum)
	dm := uuid4()
	if _, he := boxSend(t, e, a, src, dm, "c-120", ""); he != nil {
		t.Fatal(he)
	}
	count := func(what string, wantMove, wantFirst int64, post func()) {
		t.Helper()
		m, f := mc.moveReads.Load(), mc.firstReads.Load()
		post()
		if gotM, gotF := mc.moveReads.Load()-m, mc.firstReads.Load()-f; gotM != wantMove || gotF != wantFirst {
			t.Errorf("%s: %d redirect reads, %d TaskFirstChannel; want %d, %d", what, gotM, gotF, wantMove, wantFirst)
		}
	}
	count("a box post to a new task (control)", 1, 1, func() { boxSend(t, e, a, src, uuid4(), "c-120", "") }) //nolint:errcheck
	count("a box post to an existing DM", 1, 1, func() { boxSend(t, e, a, src, dm, "c-120", "") })            //nolint:errcheck
	count("a box post into a channel topic", 0, 0, func() { boxSend(t, e, a, src, roomTask, "c-120", "") })   //nolint:errcheck

	c := dialMember(t, e, src, "", hum)
	count("a browser reply into a rooted topic", 0, 0, func() {
		wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": uuid4(), "task_id": roomTask, "kind": "note", //nolint:errcheck
			"body": "a reply", "channel": "proj-x", "is_parent": 0})
		if f := readType(t, c, "ack"); f["type"] != "ack" {
			t.Fatalf("reply: %v", f)
		}
	})
}

// Condition 3: a failed read cannot say "not moved". The post is refused with
// a 503, which a box keeps pending and retries (hubclient flush.go, HubError
// clientError), and creates nothing; both reads of boxTopic, and the browser's.
// CONTROL: with the failure off, the same post goes through.
func TestChannelMoveFailedReadRefuses(t *testing.T) {
	e, mc := counterEnv(t)
	src, _ := e.tenant()
	a := moveBoxes(t, e, src)
	hum := seat(t, e, src, rbac.Admin)
	moveChannel(t, e, src, "proj-x", hum)
	dm := uuid4()
	if _, he := boxSend(t, e, a, src, dm, "c-120", ""); he != nil {
		t.Fatal(he)
	}
	for _, c := range []struct {
		name string
		fail *atomic.Bool
		task string
		rows int
	}{
		{"redirect read, a new task", &mc.failMove, uuid4(), 0},
		{"redirect read, an existing DM", &mc.failMove, dm, 1},
		{"TopicChannel, a new task", &mc.failTopic, uuid4(), 0},
	} {
		before := taskRows(t, e, src, c.task)
		c.fail.Store(true)
		_, he := boxSend(t, e, a, src, c.task, "c-120", "")
		c.fail.Store(false)
		if he == nil || he.Status != http.StatusServiceUnavailable || he.Token != "moved_check_failed" {
			t.Errorf("%s: %+v", c.name, he)
		}
		if n := taskRows(t, e, src, c.task); n != before {
			t.Errorf("%s: rows %d -> %d", c.name, before, n)
		}
		if _, he := boxSend(t, e, a, src, c.task, "c-120", ""); he != nil {
			t.Errorf("%s, control with the read back: %+v", c.name, he)
		}
	}
	task := uuid4()
	ws := dialMember(t, e, src, "", hum)
	mc.failMove.Store(true)
	wsjson.Write(context.Background(), ws, map[string]any{"type": "send", "msg_id": uuid4(), "task_id": task, "kind": "note", "body": "x", "channel": "proj-x"}) //nolint:errcheck
	f := readType(t, ws, "ack")
	mc.failMove.Store(false)
	if f["type"] != "error" || f["error"] != "moved_check_failed" {
		t.Errorf("browser: %v", f)
	}
	if n := taskRows(t, e, src, task); n != 0 {
		t.Errorf("browser: %d rows", n)
	}
}

// g-381 N2: an operator sees T9b's retention lines from a real MOVE_CMD=plan once
// the endpoint answers: the real action, this hub behind CHANNEL_MOVE_HUB_CMD,
// gcloud stubbed. CONTROL: a plan the hub refuses prints no retention line, so the
// lines above did come through the answered plan.
func TestChannelMovePlanRetentionLines(t *testing.T) {
	for _, tool := range []string{"bash", "jq", "curl"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("no " + tool)
		}
	}
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	moveChannel(t, e, src, "proj-x", seat(t, e, src, rbac.Admin))

	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		req, _ := http.NewRequest(http.MethodPost, e.url(src)+moveURL, r.Body)
		req.Header.Set("Authorization", "Bearer good")
		resp, err := e.client.Do(req)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		body := make([]byte, 1<<20)
		n, _ := resp.Body.Read(body)
		w.Write(body[:n]) //nolint:errcheck
	}))
	defer proxy.Close()

	orc, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-orc"))
	if err != nil {
		t.Fatal(err)
	}
	tmp := t.TempDir()
	stub := filepath.Join(tmp, "stub")
	os.MkdirAll(stub, 0o755) //nolint:errcheck
	gcloud := `#!/usr/bin/env bash
case "$*" in
  "sql instances describe "*) echo '{"settings":{"backupConfiguration":{"enabled":true,"transactionLogRetentionDays":6,"backupRetentionSettings":{"retainedBackups":7,"retentionUnit":"COUNT"}}}}' ;;
  "logging buckets list "*) echo '[{"name":"projects/p/locations/global/buckets/_Default","retentionDays":30}]' ;;
  *) exit 9 ;;
esac
`
	if err := os.WriteFile(filepath.Join(stub, "gcloud"), []byte(gcloud), 0o755); err != nil {
		t.Fatal(err)
	}
	run := func(channel string) (string, error) {
		cmd := exec.Command("bash", "-c", `set -uo pipefail
do_log() { echo "$*"; }
for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
do_spl_channel_workspace_move`)
		cmd.Env = append(os.Environ(), "PATH="+stub+":"+os.Getenv("PATH"), "HOME="+tmp, "APP_PATH="+filepath.Dir(orc), "SPL_PRIVATE_WARN=0",
			"GCP_ACCOUNT=pinned@example.com", "SPOOL_TEST=1", "SPOOL_ROOT="+tmp, "SPOOL_CHANNEL_RULES_MAP="+filepath.Join(tmp, "channel-rules.tsv"), "PROJ_PATH="+orc, "ENV=dev",
			"CHANNEL="+src+"/"+channel, "TO="+dst,
			"CHANNEL_MOVE_HUB_CMD=curl -sS --fail-with-body -X POST --data-binary @- "+proxy.URL)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	out, err := run("proj-x")
	if err != nil {
		t.Fatalf("plan: %v\n%s", err, out)
	}
	for _, want := range []string{"PLAN count messages 1", "PLAN retention Cloud SQL backups:", "PLAN retention log"} {
		if !strings.Contains(out, want) {
			t.Errorf("plan prints no %q:\n%s", want, out)
		}
	}
	out, err = run("nope")
	if err == nil || strings.Contains(out, "PLAN retention") {
		t.Errorf("control, a refused plan: %v\n%s", err, out)
	}
}
