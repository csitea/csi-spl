package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 155 B4: the Notes realm routes (cases C10-C16). Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full, hub-live-stack.sh).

const notesBase = "/v1/me/realm/notes"

// notesCloneStore is the hub's store with one human marked as a live act-as
// clone (the act-as door, spec 054); every other call is the real store's.
type notesCloneStore struct {
	store.Store
	store.Realm
	store.Notes
	store.MembershipLister
	clone string
}

func (s *notesCloneStore) Clone(_ context.Context, tenant, clone string) (store.Clone, error) {
	if s.clone != "" && clone == s.clone {
		return store.Clone{CloneHum: clone, TenantID: tenant}, nil
	}
	return store.Clone{}, store.ErrNotFound
}

// notesRig is a realm rig with Notes on (unless off) and P1, a fresh person,
// signed in as the owner of a fresh workspace W1.
type notesRig struct {
	r    *doorRig
	logs *lockedBuf
	w1   string
	p1   string
	cs   *notesCloneStore
}

func newNotesRig(t *testing.T, on bool) *notesRig {
	t.Helper()
	cs := &notesCloneStore{}
	buf := &lockedBuf{}
	r, _, w1 := realmRigAs(t, buf, "notes-p1-"+freshEmail(), func(o *hub.Options) {
		o.NotesEnabled = on
		cs.Store, cs.Realm, cs.Notes, cs.MembershipLister = o.Store, o.Store.(store.Realm), o.Store.(store.Notes), o.Store.(store.MembershipLister)
		o.Store = cs
	})
	return &notesRig{r: r, logs: buf, w1: w1, p1: r.session(t).HumanID, cs: cs}
}

// realmRigAs is realmRig with the IdP person sub, so the signed-in person is
// a fresh human on every run (on Postgres the default one keeps its notes).
func realmRigAs(t *testing.T, buf *lockedBuf, sub string, mut func(*hub.Options)) (*doorRig, *lockedBuf, string) {
	t.Helper()
	sub = strings.TrimSuffix(sub, "@example.com")
	r := newDoorRig(t, func(o *hub.Options) { o.Log = zerolog.New(buf) }, mut)
	tid, _ := r.e.tenant()
	r.fake.Set(fakeidp.Person{Subject: sub, Email: sub + "@example.com", EmailVerified: true, Name: "FirstName LastName"}, false)
	if landed := r.signIn(t, tid); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	return r, buf, tid
}

// browserAs is a second browser signed in to tid as a fresh person seated
// there with role (an operator invite); role "" = a fresh workspace of its
// own, as its owner.
func (n *notesRig) browserAs(t *testing.T, tid, role string) (*http.Client, string) {
	t.Helper()
	email := freshEmail()
	sub := "s-" + email
	if role != "" {
		h := n.r.e.st.(store.Humans)
		now := time.Now()
		if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		if _, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: sub, Email: email}, tid, store.AdmitPolicy{}, now); err != nil {
			t.Fatal(err)
		}
	} else {
		tid, _ = n.r.e.tenant()
	}
	n.r.fake.Set(fakeidp.Person{Subject: sub, Email: email, EmailVerified: true, Name: "FirstName LastName"}, false)
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar, Transport: n.r.browser.Transport}
	resp, err := c.Get("http://" + loginHost + "/api/v1/auth/google/start?redirect=/t&tenant=" + tid)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if strings.Contains(resp.Request.URL.String(), "auth_error") {
		t.Fatalf("second sign-in landed on %s", resp.Request.URL)
	}
	return c, (&doorRig{e: n.r.e, browser: c}).session(t).HumanID
}

// do sends one notes request from browser c (nil = P1's) and answers the
// status, the decoded body and the response headers.
func (n *notesRig) do(t *testing.T, c *http.Client, method, path string, body any, hdr map[string]string) (int, map[string]any, http.Header) {
	t.Helper()
	if c == nil {
		c = n.r.browser
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, "http://api"+domain+path, rd)
	req.Header.Set("Origin", wuiOrigin)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out, resp.Header
}

// create makes a note as P1 and answers its id.
func (n *notesRig) create(t *testing.T, body map[string]any) string {
	t.Helper()
	code, out, _ := n.do(t, nil, http.MethodPost, notesBase, body, nil)
	id, _ := out["id"].(string)
	if code != http.StatusCreated || id == "" {
		t.Fatalf("POST note = %d %v", code, out)
	}
	return id
}

// noteLinks is the links of a note answer, by ref.
func noteLinks(out map[string]any) map[string]map[string]any {
	got := map[string]map[string]any{}
	ls, _ := out["links"].([]any)
	for _, l := range ls {
		m, _ := l.(map[string]any)
		got[m["workspace_id"].(string)] = m
	}
	return got
}

// C10: another person, and an admin of P1's own workspace, read, patch and
// delete P1's note as 404, and nothing changes; twin: P1 gets 200.
func TestNotesOtherPersonIs404(t *testing.T) {
	n := newNotesRig(t, true)
	id := n.create(t, map[string]any{"title": "mine"})
	stranger, _ := n.browserAs(t, "", "")
	admin, _ := n.browserAs(t, n.w1, "admin")
	for name, c := range map[string]*http.Client{"P2": stranger, "admin of W1": admin} {
		for _, m := range []string{http.MethodGet, http.MethodPatch, http.MethodDelete} {
			var body any
			if m == http.MethodPatch {
				body = map[string]any{"title": "theirs"}
			}
			if code, out, _ := n.do(t, c, m, notesBase+"/"+id, body, nil); code != http.StatusNotFound || realmToken(out) != "not_found" {
				t.Errorf("%s %s P1's note = %d %v, want 404 not_found", name, m, code, out)
			}
		}
		if code, out, _ := n.do(t, c, http.MethodGet, notesBase, nil, nil); code != http.StatusOK || len(out["notes"].([]any)) != 0 {
			t.Errorf("%s list = %d %v, want 200 and none of P1's", name, code, out)
		}
	}
	code, out, _ := n.do(t, nil, http.MethodGet, notesBase+"/"+id, nil, nil)
	if code != http.StatusOK || out["title"] != "mine" {
		t.Fatalf("CONTROL: P1 GET own note = %d %v, want 200 'mine'", code, out)
	}
}

// C11: the workspace header is 400 tenant_named; an act-as clone and an
// agent (a box token) are 403 person_only; twin: P1's own session gets 200.
func TestNotesRealmRefusals(t *testing.T) {
	n := newNotesRig(t, true)
	id := n.create(t, map[string]any{"title": "c11"})
	for _, p := range []string{notesBase, notesBase + "/" + id, notesBase + "/export"} {
		if code, out, _ := n.do(t, nil, http.MethodGet, p, nil, map[string]string{hub.TenantHeader: n.w1}); code != http.StatusBadRequest || realmToken(out) != "tenant_named" {
			t.Errorf("X-Spool-Tenant GET %s = %d %v, want 400 tenant_named", p, code, out)
		}
		if code, out, _ := n.do(t, nil, http.MethodGet, p, nil, map[string]string{"Authorization": "Bearer box-agent-token"}); code != http.StatusForbidden || realmToken(out) != "person_only" {
			t.Errorf("agent token GET %s = %d %v, want 403 person_only", p, code, out)
		}
		if code, out, _ := n.do(t, nil, http.MethodGet, p, nil, nil); code != http.StatusOK {
			t.Errorf("CONTROL: P1 GET %s = %d %v, want 200", p, code, out)
		}
	}
	if code, out, _ := n.do(t, nil, http.MethodPost, notesBase, map[string]any{"title": "x", "person_id": "HUM-1"}, nil); code != http.StatusBadRequest {
		t.Errorf("a person_id in the body = %d %v, want 400", code, out)
	}
	n.cs.clone = n.p1 // P1's session is now an act-as clone's
	for _, p := range []string{notesBase, notesBase + "/" + id} {
		if code, out, _ := n.do(t, nil, http.MethodGet, p, nil, nil); code != http.StatusForbidden || realmToken(out) != "person_only" {
			t.Errorf("act-as clone GET %s = %d %v, want 403 person_only", p, code, out)
		}
	}
	if code, out, _ := n.do(t, nil, http.MethodPost, notesBase, map[string]any{"title": "as clone"}, nil); code != http.StatusForbidden {
		t.Errorf("act-as clone POST = %d %v, want 403", code, out)
	}
}

// C12 (D4): P1 left W2; a link into W2 comes back with label "" and left
// true, its stored label stays until the next write, which erases it; twin:
// the link into W1 keeps "Plan".
func TestNotesLabelAfterLeave(t *testing.T) {
	n := newNotesRig(t, true)
	w2, _ := n.r.e.tenant()
	sess := n.r.session(t)
	email := sess.Email
	if email == "" {
		t.Fatalf("the session carries no email: %+v", sess)
	}
	if hum := join(t, n.r.e, email, w2); hum != n.p1 {
		t.Fatalf("join W2 seated %s, want P1 %s", hum, n.p1)
	}
	topic := "11111111-2222-4333-8444-555555555555"
	id := n.create(t, map[string]any{"title": "c12", "links": []map[string]any{
		{"kind": "topic", "workspace_id": n.w1, "ref": topic, "label": "Plan"},
		{"kind": "topic", "workspace_id": w2, "ref": topic, "label": "Plan"},
	}})
	_, out, _ := n.do(t, nil, http.MethodGet, notesBase+"/"+id, nil, nil)
	if l := noteLinks(out)[w2]; l["label"] != "Plan" || l["left"] != false {
		t.Fatalf("CONTROL: before the leave the W2 link = %v, want label Plan, left false", l)
	}
	if err := n.r.e.st.(interface {
		RemoveMember(ctx context.Context, tenant, humanID string) error
	}).RemoveMember(context.Background(), w2, n.p1); err != nil {
		t.Fatal(err)
	}
	_, out, _ = n.do(t, nil, http.MethodGet, notesBase+"/"+id, nil, nil)
	got := noteLinks(out)
	if l := got[w2]; l["label"] != "" || l["left"] != true {
		t.Errorf("after the leave the W2 link = %v, want label \"\", left true", l)
	}
	if l := got[n.w1]; l["label"] != "Plan" || l["left"] != false {
		t.Errorf("twin: the W1 link = %v, want label Plan, left false", l)
	}
	stored := func() map[string]string {
		nt, err := n.r.e.st.(store.Notes).NoteOf(context.Background(), n.p1, id)
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]string{}
		for _, l := range nt.Links {
			m[l.WorkspaceID] = l.Label
		}
		return m
	}
	if s := stored(); s[w2] != "Plan" {
		t.Fatalf("a GET changed the stored W2 label: %v", s)
	}
	if code, out, _ := n.do(t, nil, http.MethodPatch, notesBase+"/"+id, map[string]any{"title": "c12 b"}, nil); code != http.StatusOK || noteLinks(out)[w2]["left"] != true {
		t.Fatalf("PATCH = %d %v", code, out)
	}
	if s := stored(); s[w2] != "" || s[n.w1] != "Plan" {
		t.Errorf("after the PATCH the stored labels = %v, want W2 \"\" and W1 Plan", s)
	}
}

// C13: a 201-character title and the 101st link are 400; twin: 200
// characters and the 100th link pass.
func TestNotesLimits(t *testing.T) {
	n := newNotesRig(t, true)
	if code, out, _ := n.do(t, nil, http.MethodPost, notesBase, map[string]any{"title": strings.Repeat("é", 201)}, nil); code != http.StatusBadRequest || realmToken(out) != "bad_note" {
		t.Errorf("201-character title = %d %v, want 400 bad_note", code, out)
	}
	id := n.create(t, map[string]any{"title": strings.Repeat("é", 200)})
	if code, out, _ := n.do(t, nil, http.MethodPatch, notesBase+"/"+id, map[string]any{"title": strings.Repeat("a", 201)}, nil); code != http.StatusBadRequest {
		t.Errorf("PATCH 201-character title = %d %v, want 400", code, out)
	}
	links := make([]map[string]any, 99)
	for i := range links {
		links[i] = map[string]any{"kind": "url", "ref": "https://example.com/" + strings.Repeat("x", i)}
	}
	id = n.create(t, map[string]any{"title": "links", "links": links})
	if code, out, _ := n.do(t, nil, http.MethodPost, notesBase+"/"+id+"/links", map[string]any{"kind": "url", "ref": "https://example.com/100"}, nil); code != http.StatusCreated {
		t.Fatalf("twin: the 100th link = %d %v, want 201", code, out)
	}
	if code, out, _ := n.do(t, nil, http.MethodPost, notesBase+"/"+id+"/links", map[string]any{"kind": "url", "ref": "https://example.com/101"}, nil); code != http.StatusBadRequest {
		t.Errorf("the 101st link = %d %v, want 400", code, out)
	}
	if code, out, _ := n.do(t, nil, http.MethodPost, notesBase+"/"+id+"/links", map[string]any{"kind": "url", "ref": "javascript:alert(1)"}, nil); code != http.StatusBadRequest {
		t.Errorf("a javascript: url = %d %v, want 400", code, out)
	}
}

// C14: the export holds every note, the archived one too, as an attachment;
// the erase leaves none.
func TestNotesExportErase(t *testing.T) {
	n := newNotesRig(t, true)
	a := n.create(t, map[string]any{"title": "kept", "items": []map[string]any{{"text": "one"}, {"text": "two", "done": true}}})
	b := n.create(t, map[string]any{"title": "archived"})
	if code, out, _ := n.do(t, nil, http.MethodPatch, notesBase+"/"+b, map[string]any{"archived": true}, nil); code != http.StatusOK || out["archived"] != true {
		t.Fatalf("archive = %d %v", code, out)
	}
	code, out, hdr := n.do(t, nil, http.MethodGet, notesBase+"/export", nil, nil)
	if code != http.StatusOK || !strings.HasPrefix(hdr.Get("Content-Disposition"), `attachment; filename="notes-`) {
		t.Fatalf("export = %d %v %q", code, out, hdr.Get("Content-Disposition"))
	}
	if got := hdr.Get("Access-Control-Expose-Headers"); !strings.Contains(got, "Content-Disposition") {
		t.Errorf("export Access-Control-Expose-Headers = %q, want it to name Content-Disposition (the realm routes are cross-origin)", got)
	}
	got := map[string]map[string]any{}
	for _, x := range out["notes"].([]any) {
		m := x.(map[string]any)
		got[m["id"].(string)] = m
	}
	if len(got) != 2 || got[b]["archived"] != true || len(got[a]["items"].([]any)) != 2 {
		t.Fatalf("export notes = %v, want both with the archived one and 2 items", got)
	}
	if code, out, _ = n.do(t, nil, http.MethodGet, notesBase, nil, nil); code != http.StatusOK || len(out["notes"].([]any)) != 2 {
		t.Fatalf("list = %d %v, want 2", code, out)
	}
	if code, out, _ = n.do(t, nil, http.MethodDelete, notesBase, nil, nil); code != http.StatusNoContent {
		t.Fatalf("erase = %d %v, want 204", code, out)
	}
	if code, out, _ = n.do(t, nil, http.MethodGet, notesBase, nil, nil); code != http.StatusOK || len(out["notes"].([]any)) != 0 {
		t.Errorf("list after erase = %d %v, want 0", code, out)
	}
	if code, out, _ = n.do(t, nil, http.MethodGet, notesBase+"/export", nil, nil); len(out["notes"].([]any)) != 0 {
		t.Errorf("export after erase = %d %v, want 0", code, out)
	}
}

// C15: SPOOL_HUB_NOTES_ENABLED=false answers every notes route 404
// notes_off; twin: true answers 200.
func TestNotesKillSwitch(t *testing.T) {
	off := newNotesRig(t, false)
	id := "11111111-2222-4333-8444-555555555555"
	routes := [][2]string{
		{http.MethodGet, notesBase}, {http.MethodPost, notesBase}, {http.MethodDelete, notesBase},
		{http.MethodGet, notesBase + "/export"}, {http.MethodGet, notesBase + "/" + id},
		{http.MethodPatch, notesBase + "/" + id}, {http.MethodDelete, notesBase + "/" + id},
		{http.MethodPut, notesBase + "/" + id + "/items"}, {http.MethodPost, notesBase + "/" + id + "/links"},
		{http.MethodPatch, notesBase + "/" + id + "/links/" + id}, {http.MethodDelete, notesBase + "/" + id + "/links/" + id},
	}
	for _, rt := range routes {
		var body any
		if rt[0] == http.MethodPost || rt[0] == http.MethodPatch || rt[0] == http.MethodPut {
			body = map[string]any{}
		}
		if code, out, _ := off.do(t, nil, rt[0], rt[1], body, nil); code != http.StatusNotFound || realmToken(out) != "notes_off" {
			t.Errorf("off: %s %s = %d %v, want 404 notes_off", rt[0], rt[1], code, out)
		}
	}
	on := newNotesRig(t, true)
	if code, out, _ := on.do(t, nil, http.MethodGet, notesBase, nil, nil); code != http.StatusOK {
		t.Fatalf("twin: on GET = %d %v, want 200", code, out)
	}
}

// C16: the create's log line holds the person and the note id, never the
// title, the body, a checklist line, a label or a ref.
func TestNotesLogHoldsIDsOnly(t *testing.T) {
	n := newNotesRig(t, true)
	id := n.create(t, map[string]any{"title": "note-title-sentinel", "body": "note-body-sentinel",
		"items": []map[string]any{{"text": "note-item-sentinel"}},
		"links": []map[string]any{{"kind": "url", "ref": "https://example.com/note-ref-sentinel", "label": "note-label-sentinel"}}})
	logs := realmLogs(n.logs)
	found := false
	for _, line := range strings.Split(strings.TrimSpace(logs), "\n") {
		var ev map[string]any
		if json.Unmarshal([]byte(line), &ev) == nil && ev["op"] == "notes_create" {
			found = ev["person"] == n.p1 && ev["note"] == id
		}
	}
	if !found {
		t.Errorf("no notes_create log line holds person %s and note %s: %s", n.p1, id, logs)
	}
	for _, banned := range []string{"note-title-sentinel", "note-body-sentinel", "note-item-sentinel", "note-ref-sentinel", "note-label-sentinel"} {
		if strings.Contains(logs, banned) {
			t.Errorf("a log line carries %q", banned)
		}
	}
}
