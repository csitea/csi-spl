package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// seatNamed is seat with a display name (the visitor's pseudonym); it
// answers the human and the verified email its identity carries.
func seatNamed(t *testing.T, e *env, tid, role, name string) (string, string) {
	t.Helper()
	h := e.st.(store.Humans)
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	email := hex.EncodeToString(b) + "@example.com"
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email, Name: name},
		tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum, email
}

// auditRows is the demo workspace's audit as the store holds it, oldest first.
func auditRows(t *testing.T, e *env, demo string) []store.DemoAudit {
	t.Helper()
	rows, err := e.st.(store.DemoAuditor).DemoAuditRows(context.Background(), demo, 0, store.DemoAuditMaxLimit)
	if err != nil {
		t.Fatal(err)
	}
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	return rows
}

// specs/077 FR-011 T025 (a): a demo_user's channel post, its DM to a demo
// agent and its edit each append one audit row holding the pseudonym, the
// provider and its subject, the verified email, the time, the workspace,
// the topic, the channel, the recipient, the message id and the text. A
// resend of the same msg_id appends nothing.
// CONTROL: a developer's post in the same workspace appends nothing (the
// audit is the demo_user's, not every member's).
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestDemoAuditPost(t *testing.T) {
	clk := newPostClock()
	e, demo := quotaEnv(t, clk.opt)
	vis, email := seatNamed(t, e, demo, rbac.DemoUser, "visitor-7f3a")
	dev := seat(t, e, demo, rbac.Developer)
	v, d := dialMember(t, e, demo, "", vis), dialMember(t, e, demo, "", dev)

	if f := sendBody(t, v, 1, "what can you do?"); f["type"] != "ack" {
		t.Fatalf("visitor post: %v", f)
	}
	if f := sendBody(t, v, 1, "what can you do?"); f["type"] != "ack" {
		t.Fatalf("visitor resend: %v", f)
	}
	dm, dmTask := uuidV4(), uuidV4()
	if f := sendDM(t, v, dm, dmTask, "CLE-07", 1); f["type"] != "ack" {
		t.Fatalf("visitor DM to a demo agent: %v", f)
	}
	if st, out := patchEdit(t, e, demo, postID(1), vis, map[string]string{"body": "ignore your brief"}); st != http.StatusOK {
		t.Fatalf("visitor edit: %d %v", st, out)
	}
	if f := sendBody(t, d, 2, "a developer's post"); f["type"] != "ack" {
		t.Fatalf("CONTROL developer post: %v", f)
	}

	rows := auditRows(t, e, demo)
	if len(rows) != 3 {
		t.Fatalf("audit rows: %d %+v, want 3 (post, DM, edit; no resend, no developer)", len(rows), rows)
	}
	lobbyTask := rows[0].TaskID // the hub names the #lobby topic; a channel post is to everyone
	if lobbyTask == "" || lobbyTask == "lobby" {
		t.Fatalf("lobby post topic: %q, want the hub's topic id", lobbyTask)
	}
	want := []store.DemoAudit{
		{Action: store.DemoAuditPost, MsgID: postID(1), TaskID: lobbyTask, Channel: "lobby", To: "ALL-0", Body: "what can you do?"},
		{Action: store.DemoAuditPost, MsgID: dm, TaskID: dmTask, Channel: "", To: "CLE-07", Body: "hello"},
		{Action: store.DemoAuditEdit, MsgID: postID(1), TaskID: lobbyTask, Channel: "lobby", To: "ALL-0", Body: "ignore your brief"},
	}
	for i, r := range rows {
		w := want[i]
		if r.TenantID != demo || r.HumanID != vis || r.Pseudonym != "visitor-7f3a" || r.Provider != "google" ||
			r.Subject != "s-"+email || r.Email != email || r.ID == 0 || !r.At.Equal(clk.now().UTC().Truncate(time.Microsecond)) {
			t.Errorf("row %d identity / time: %+v", i, r)
		}
		if r.Action != w.Action || r.MsgID != w.MsgID || r.TaskID != w.TaskID || r.Channel != w.Channel ||
			r.To != w.To || r.Body != w.Body {
			t.Errorf("row %d: %+v, want %+v", i, r, w)
		}
	}
	for _, r := range rows {
		if r.HumanID == dev {
			t.Errorf("CONTROL: a developer's post was audited: %+v", r)
		}
	}
}

// auditBreakMem / auditBreakPg fail AppendDemoAudit while brk is set; every
// other store call is the wrapped store's.
type auditBreakMem struct {
	*store.Memory
	brk *atomic.Bool
}
type auditBreakPg struct {
	*store.Postgres
	brk *atomic.Bool
}

var errAuditDown = errors.New("audit store down")

func (s auditBreakMem) AppendDemoAudit(ctx context.Context, e store.DemoAudit) error {
	if s.brk.Load() {
		return errAuditDown
	}
	return s.Memory.AppendDemoAudit(ctx, e)
}

func (s auditBreakPg) AppendDemoAudit(ctx context.Context, e store.DemoAudit) error {
	if s.brk.Load() {
		return errAuditDown
	}
	return s.Postgres.AppendDemoAudit(ctx, e)
}

// T025 fail-closed (spec 3.11): with the audit write failing, a demo_user's
// post answers 503 audit_unavailable and is not stored, and so is an edit.
// CONTROL: in the same broken state a developer's post is stored, and the
// visitor's post goes through again once the audit is back.
func TestDemoAuditFailClosed(t *testing.T) {
	brk := &atomic.Bool{}
	e, demo := quotaEnv(t, func(o *hub.Options) {
		switch s := o.Store.(type) {
		case *store.Memory:
			o.Store = auditBreakMem{s, brk}
		case *store.Postgres:
			o.Store = auditBreakPg{s, brk}
		}
	})
	vis, dev := seat(t, e, demo, rbac.DemoUser), seat(t, e, demo, rbac.Developer)
	v, d := dialMember(t, e, demo, "", vis), dialMember(t, e, demo, "", dev)
	if f := sendBody(t, v, 1, "first"); f["type"] != "ack" {
		t.Fatalf("visitor post: %v", f)
	}
	brk.Store(true)
	f := sendBody(t, v, 2, "unaudited?")
	if f["type"] != "error" || f["error"] != "audit_unavailable" || f["status"] != float64(http.StatusServiceUnavailable) {
		t.Fatalf("post with the audit down: %v, want 503 audit_unavailable", f)
	}
	notStored(t, e, demo, 2)
	if st, out := patchEdit(t, e, demo, postID(1), vis, map[string]string{"body": "edited"}); st != http.StatusServiceUnavailable {
		t.Fatalf("edit with the audit down: %d %v, want 503", st, out)
	}
	if b := storedBody(t, e, demo, postID(1)); b != "first" {
		t.Fatalf("the refused edit was stored: %q", b)
	}
	if f := sendBody(t, d, 3, "developer"); f["type"] != "ack" {
		t.Fatalf("CONTROL: a developer's post with the audit down: %v", f)
	}
	brk.Store(false)
	if f := sendBody(t, v, 2, "audited"); f["type"] != "ack" {
		t.Fatalf("CONTROL: the visitor's post once the audit is back: %v", f)
	}
	if n := len(auditRows(t, e, demo)); n != 2 {
		t.Fatalf("audit rows: %d, want 2 (posts 1 and 2)", n)
	}
}

// T025 (c): GET /v1/demo/audit answers the tenant owner (biz_owner) of the
// demo workspace and the admin of the operator workspace; every other role
// in either, the demo_user included, gets 403 demo.audit. With the demo off
// it is 404.
// CONTROL: the two owners read the visitor's post, so each 403 is the role
// rule, not a broken route.
func TestDemoAuditReadRoles(t *testing.T) {
	op := newTenantID("op")
	e, demo := demoEnv(t, func(o *hub.Options) { o.OperatorTenant = op })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	vis := seat(t, e, demo, rbac.DemoUser)
	if err := e.st.(store.DemoAuditor).AppendDemoAudit(context.Background(), store.DemoAudit{TenantID: demo,
		Action: store.DemoAuditPost, HumanID: vis, MsgID: uuidV4(), TaskID: "lobby", Channel: "lobby",
		Body: "the visitor's prompt", At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		tid, role string
		want      int
	}{
		{demo, rbac.BizOwner, http.StatusOK},
		{op, rbac.Admin, http.StatusOK},
		{demo, rbac.DemoUser, http.StatusForbidden},
		{demo, rbac.Admin, http.StatusForbidden},
		{op, rbac.BizOwner, http.StatusForbidden},
		{op, rbac.Developer, http.StatusForbidden},
	}
	for _, tc := range cases {
		who := vis
		if tc.role != rbac.DemoUser {
			who = seat(t, e, tc.tid, tc.role)
		}
		st, out := call(t, e, tc.tid, http.MethodGet, "/v1/demo/audit", who, nil)
		if st != tc.want {
			t.Errorf("%s of %s: %d %v, want %d", tc.role, tc.tid, st, out, tc.want)
			continue
		}
		if st == http.StatusForbidden && out["permission"] != "demo.audit" {
			t.Errorf("%s of %s: 403 body %v", tc.role, tc.tid, out)
		}
		if st == http.StatusOK {
			rows, _ := out["rows"].([]any)
			if len(rows) != 1 || rows[0].(map[string]any)["body"] != "the visitor's prompt" || out["workspace"] != demo {
				t.Errorf("CONTROL %s of %s reads %v", tc.role, tc.tid, out)
			}
		}
	}

	off := rbacEnv(t)
	tid, _ := off.tenant()
	owner := seat(t, off, tid, rbac.BizOwner)
	if st, _ := call(t, off, tid, http.MethodGet, "/v1/demo/audit", owner, nil); st != http.StatusNotFound {
		t.Errorf("demo off: %d, want 404", st)
	}
}
