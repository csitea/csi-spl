package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 B3: the contacts routes (cases C4-C7d, C6b, C8e, C12). Memory,
// and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full). Fixtures are
// FirstName LastName and example.com only (spec 154 section 6).

const contactsBase = "/v1/me/contacts"

// The C5 fixture: the four values.
const (
	ctFirst = "FirstName"
	ctLast  = "LastName"
	ctEmail = "first.last@example.com"
	ctPhone = "+1 555 010 0000"
)

// contactsCloneStore is the hub's store with one human marked as a live
// act-as clone (spec 054); every other call is the real store's.
type contactsCloneStore struct {
	store.Store
	store.Humans
	store.PersonalContacts
	store.ContactsSyncs
	store.Gcal
	store.MembershipLister
	mu    sync.Mutex
	clone string
}

func (s *contactsCloneStore) Clone(_ context.Context, tenant, clone string) (store.Clone, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.clone != "" && clone == s.clone {
		return store.Clone{CloneHum: clone, TenantID: tenant}, nil
	}
	return store.Clone{}, store.ErrNotFound
}

func (s *contactsCloneStore) setClone(h string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clone = h
}

// contactsClock is the hub's settable clock (C7c).
type contactsClock struct {
	mu sync.Mutex
	at time.Time
}

func (c *contactsClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.at.IsZero() {
		return time.Now()
	}
	return c.at
}

func (c *contactsClock) set(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = t
}

// contactsRig: P1, a fresh person, owns W1 and is a developer in W2; b1 is
// P1's browser in W1, b2 the same person's browser in W2.
type contactsRig struct {
	r      *doorRig
	logs   *lockedBuf
	cs     *contactsCloneStore
	clk    *contactsClock
	w1, w2 string
	p1     string
	email  string
	b1, b2 *http.Client
}

func contactsTenantID() string {
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	return "t" + hex.EncodeToString(b)
}

// newContactsRig builds the rig; on names the workspaces of the switch from
// W1 and W2.
func newContactsRig(t *testing.T, on func(w1, w2 string) []string) *contactsRig {
	t.Helper()
	c := &contactsRig{logs: &lockedBuf{}, cs: &contactsCloneStore{}, clk: &contactsClock{},
		w1: contactsTenantID(), w2: contactsTenantID()}
	c.r = newDoorRig(t, func(o *hub.Options) {
		o.Log = zerolog.New(c.logs)
		o.Now = c.clk.now
		o.ContactsWorkspaces = on(c.w1, c.w2)
		c.cs.Store, c.cs.Humans = o.Store, o.Store.(store.Humans)
		c.cs.PersonalContacts, c.cs.ContactsSyncs, c.cs.Gcal = o.Store.(store.PersonalContacts), o.Store.(store.ContactsSyncs), o.Store.(store.Gcal)
		c.cs.MembershipLister = o.Store.(store.MembershipLister)
		o.Store = c.cs
	})
	for _, id := range []string{c.w1, c.w2} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := c.r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	sub := "contacts-p1-" + strings.TrimSuffix(freshEmail(), "@example.com")
	c.email = sub + "@example.com"
	c.r.fake.Set(fakeidp.Person{Subject: sub, Email: c.email, EmailVerified: true, Name: "Contacts Rig"}, false)
	if landed := c.r.signIn(t, c.w1); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	c.b1, c.p1 = c.r.browser, c.r.session(t).HumanID
	if hum := join(t, c.r.e, c.email, c.w2); hum != c.p1 {
		t.Fatalf("join W2 seated %s, want P1 %s", hum, c.p1)
	}
	c.b2 = c.signedIn(t, c.w2)
	return c
}

// signedIn is a new browser of the IdP's current person, signed in to tid.
func (c *contactsRig) signedIn(t *testing.T, tid string) *http.Client {
	t.Helper()
	jar, _ := cookiejar.New(nil)
	b := &http.Client{Jar: jar, Transport: c.r.browser.Transport}
	resp, err := b.Get("http://" + loginHost + "/api/v1/auth/google/start?redirect=/t&tenant=" + tid)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if strings.Contains(resp.Request.URL.String(), "auth_error") {
		t.Fatalf("sign-in to %s landed on %s", tid, resp.Request.URL)
	}
	return b
}

// other is a browser of another person: role "" = a fresh workspace of
// their own, else seated in W1 with role.
func (c *contactsRig) other(t *testing.T, role string) (*http.Client, string) {
	t.Helper()
	n := &notesRig{r: c.r}
	if role == "" {
		return n.browserAs(t, "", "")
	}
	return n.browserAs(t, c.w1, role)
}

// do sends one request from browser b and answers the status, the raw body
// and the decoded body.
func (c *contactsRig) do(t *testing.T, b *http.Client, method, path string, body any, hdr map[string]string) (int, []byte, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, "http://api"+domain+path, rd)
	req.Header.Set("Origin", wuiOrigin)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := b.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, raw, out
}

// create adds a contact from browser b and answers its id.
func (c *contactsRig) create(t *testing.T, b *http.Client, body map[string]any) string {
	t.Helper()
	code, _, out := c.do(t, b, http.MethodPost, contactsBase, body, nil)
	id, _ := out["contact_id"].(string)
	if code != http.StatusCreated || id == "" {
		t.Fatalf("POST contact = %d %v", code, out)
	}
	return id
}

func contactsOf(t *testing.T, out map[string]any) []map[string]any {
	t.Helper()
	l, ok := out["contacts"].([]any)
	if !ok {
		t.Fatalf("no contacts list in %v", out)
	}
	got := make([]map[string]any, 0, len(l))
	for _, x := range l {
		got = append(got, x.(map[string]any))
	}
	return got
}

// connect gives P1 a Google connection in tid (the 149 row; tokens are
// opaque strings to the store).
func (c *contactsRig) connect(t *testing.T, tid, googleEmail string) {
	t.Helper()
	if _, err := c.r.e.st.(store.Gcal).ConnectGcal(context.Background(),
		store.GcalConnection{Tenant: tid, Human: c.p1, GoogleEmail: googleEmail},
		store.GcalTokens{AccessSealed: "sealed-access", RefreshSealed: "sealed-refresh", KMSKeyID: "k", AccessExpiry: time.Now().Add(time.Hour)},
		time.Now()); err != nil {
		t.Fatal(err)
	}
}

// link links P1's contact to Google under account (the sync cycle's store
// call, B8a).
func (c *contactsRig) link(t *testing.T, id, account, resource string) {
	t.Helper()
	if _, err := c.r.e.st.(store.ContactsCycle).LinkContact(context.Background(), c.p1, id,
		store.ContactLink{Account: account, Resource: resource, ETag: "etag-1"}); err != nil {
		t.Fatal(err)
	}
}

// pending is P1's rows the sync cycle would read, soft-deleted ones too,
// by id: true = soft-deleted.
func (c *contactsRig) pending(t *testing.T) map[string]bool {
	t.Helper()
	rows, err := c.r.e.st.(store.ContactsCycle).ContactsChangedSince(context.Background(), c.p1, nil)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, r := range rows {
		got[r.ID] = r.DeletedAt != nil
	}
	return got
}

func onAll(_, _ string) []string { return []string{"all"} }

// C5 and C12: the four values back from the create, the read, the list
// and a search of the list; no log line carries one of them, and the
// create's log line carries the person and the contact id.
func TestContactsCreateAndRead(t *testing.T) {
	c := newContactsRig(t, onAll)
	code, _, out := c.do(t, c.b1, http.MethodPost, contactsBase,
		map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone}, nil)
	if code != http.StatusCreated {
		t.Fatalf("POST = %d %v, want 201", code, out)
	}
	id, _ := out["contact_id"].(string)
	want := map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone, "google": false, "member_id": nil}
	for k, v := range want {
		if out[k] != v {
			t.Errorf("POST answer %s = %v, want %v", k, out[k], v)
		}
	}
	if code, _, got := c.do(t, c.b1, http.MethodGet, contactsBase+"/"+id, nil, nil); code != http.StatusOK || got["email"] != ctEmail {
		t.Errorf("GET = %d %v", code, got)
	}
	code, _, out = c.do(t, c.b1, http.MethodGet, contactsBase+"?q="+ctFirst, nil, nil)
	if l := contactsOf(t, out); code != http.StatusOK || len(l) != 1 || l[0]["contact_id"] != id || out["next"] != nil {
		t.Errorf("GET ?q= = %d %v, want the one contact", code, out)
	}
	code, _, out = c.do(t, c.b1, http.MethodPatch, contactsBase+"/"+id, map[string]any{"phone": ""}, nil)
	if code != http.StatusOK || out["phone"] != nil || out["first_name"] != ctFirst {
		t.Errorf("PATCH phone \"\" = %d %v, want the phone cleared", code, out)
	}
	if code, _, out = c.do(t, c.b1, http.MethodPost, contactsBase, map[string]any{"first_name": " "}, nil); code != http.StatusBadRequest || realmToken(out) != "contact_empty" {
		t.Errorf("POST empty = %d %v, want 400 contact_empty", code, out)
	}
	if code, _, out = c.do(t, c.b1, http.MethodPost, contactsBase, map[string]any{"email": "no-at-sign"}, nil); code != http.StatusBadRequest || realmToken(out) != "bad_email" {
		t.Errorf("POST bad email = %d %v, want 400 bad_email", code, out)
	}
	if code, _, out = c.do(t, c.b1, http.MethodPost, contactsBase, map[string]any{"phone": "call me"}, nil); code != http.StatusBadRequest || realmToken(out) != "bad_phone" {
		t.Errorf("POST bad phone = %d %v, want 400 bad_phone", code, out)
	}
	if code, _, out = c.do(t, c.b1, http.MethodPost, contactsBase, map[string]any{"first_name": "x", "person_id": "HUM-1"}, nil); code != http.StatusBadRequest {
		t.Errorf("a person_id in the body = %d %v, want 400", code, out)
	}

	logs := realmLogs(c.logs)
	for _, banned := range []string{ctFirst, ctLast, ctEmail, ctPhone, "5550100000"} {
		if strings.Contains(logs, banned) {
			t.Errorf("C12: a log line carries the contact value %q", banned)
		}
	}
	found := false
	for _, line := range strings.Split(strings.TrimSpace(logs), "\n") {
		var ev map[string]any
		if json.Unmarshal([]byte(line), &ev) == nil && ev["op"] == "contacts_create" {
			found = found || (ev["person"] == c.p1 && ev["contact"] == id)
		}
	}
	if !found {
		t.Errorf("CONTROL: no contacts_create log line holds person %s and contact %s", c.p1, id)
	}
}

// C4: an admin of P1's own workspace, and a stranger, read, patch and
// delete P1's contact as 404 and list none of P1's; twin: P1 gets 200.
func TestContactsOtherPersonIs404(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "email": ctEmail})
	admin, _ := c.other(t, "admin")
	stranger, _ := c.other(t, "")
	for name, b := range map[string]*http.Client{"admin of W1": admin, "stranger": stranger} {
		for _, m := range []string{http.MethodGet, http.MethodPatch, http.MethodDelete} {
			var body any
			if m == http.MethodPatch {
				body = map[string]any{"first_name": "theirs"}
			}
			if code, _, out := c.do(t, b, m, contactsBase+"/"+id, body, nil); code != http.StatusNotFound || realmToken(out) != "not_found" {
				t.Errorf("%s %s P1's contact = %d %v, want 404 not_found", name, m, code, out)
			}
		}
		if code, _, out := c.do(t, b, http.MethodGet, contactsBase, nil, nil); code != http.StatusOK || len(contactsOf(t, out)) != 0 {
			t.Errorf("%s list = %d %v, want 200 and none of P1's", name, code, out)
		}
	}
	if code, _, out := c.do(t, c.b1, http.MethodGet, contactsBase+"/"+id, nil, nil); code != http.StatusOK || out["first_name"] != ctFirst {
		t.Fatalf("twin: P1 GET own contact = %d %v, want 200", code, out)
	}
}

// C4b: an act-as clone session and an agent (a box token) are 403
// person_only; twin: the admin's own session (P1 owns W1) gets 201.
func TestContactsPersonOnly(t *testing.T) {
	c := newContactsRig(t, onAll)
	body := map[string]any{"first_name": ctFirst}
	if code, _, out := c.do(t, c.b1, http.MethodPost, contactsBase, body, nil); code != http.StatusCreated {
		t.Fatalf("twin: the admin's own POST = %d %v, want 201", code, out)
	}
	if code, _, out := c.do(t, c.b1, http.MethodPost, contactsBase, body, map[string]string{"Authorization": "Bearer box-agent-token"}); code != http.StatusForbidden || realmToken(out) != "person_only" {
		t.Errorf("agent POST = %d %v, want 403 person_only", code, out)
	}
	c.cs.setClone(c.p1) // P1's session is now an act-as clone's
	for _, rt := range [][2]string{{http.MethodPost, contactsBase}, {http.MethodGet, contactsBase}, {http.MethodGet, contactsBase + "/export"}} {
		var b any
		if rt[0] == http.MethodPost {
			b = body
		}
		if code, _, out := c.do(t, c.b1, rt[0], rt[1], b, nil); code != http.StatusForbidden || realmToken(out) != "person_only" {
			t.Errorf("act-as clone %s %s = %d %v, want 403 person_only", rt[0], rt[1], code, out)
		}
	}
}

// C6 and C6b: W1 is outside contacts.workspaces, W2 inside. In W1 every
// route is 404 and /v1/view/me says contacts false; in W2 true, and the
// person's list read from W2 is unchanged by the refused W1 calls.
func TestContactsKillSwitch(t *testing.T) {
	c := newContactsRig(t, func(_, w2 string) []string { return []string{w2} })
	id := c.create(t, c.b2, map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone})
	routes := [][2]string{
		{http.MethodGet, contactsBase}, {http.MethodPost, contactsBase}, {http.MethodDelete, contactsBase + "?scope=spool"},
		{http.MethodGet, contactsBase + "/export"}, {http.MethodGet, contactsBase + "/" + id},
		{http.MethodPatch, contactsBase + "/" + id}, {http.MethodDelete, contactsBase + "/" + id},
		{http.MethodPut, contactsBase + "/sync"}, {http.MethodPost, contactsBase + "/sync"},
	}
	for _, rt := range routes {
		var body any
		if rt[0] == http.MethodPost || rt[0] == http.MethodPatch || rt[0] == http.MethodPut {
			body = map[string]any{"first_name": ctFirst, "enabled": true}
		}
		if code, _, out := c.do(t, c.b1, rt[0], rt[1], body, nil); code != http.StatusNotFound || realmToken(out) != "not_found" {
			t.Errorf("W1 (off): %s %s = %d %v, want 404 not_found", rt[0], rt[1], code, out)
		}
	}
	for b, want := range map[*http.Client]bool{c.b1: false, c.b2: true} {
		code, _, out := c.do(t, b, http.MethodGet, "/v1/view/me", nil, nil)
		if code != http.StatusOK || out["contacts"] != want {
			t.Errorf("GET /v1/view/me = %d contacts=%v, want %v", code, out["contacts"], want)
		}
	}
	code, _, out := c.do(t, c.b2, http.MethodGet, contactsBase, nil, nil)
	if l := contactsOf(t, out); code != http.StatusOK || len(l) != 1 || l[0]["contact_id"] != id || l[0]["phone"] != ctPhone {
		t.Errorf("twin: W2 list = %d %v, want the one unchanged contact", code, out)
	}
}

// C7: the export is the CSV header and P1's own rows only (two persons).
func TestContactsExport(t *testing.T) {
	c := newContactsRig(t, onAll)
	c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone})
	c.create(t, c.b1, map[string]any{"first_name": "Second"})
	stranger, _ := c.other(t, "")
	c.create(t, stranger, map[string]any{"first_name": "Stranger", "email": "stranger@example.com"})

	code, raw, _ := c.do(t, c.b1, http.MethodGet, contactsBase+"/export", nil, nil)
	if code != http.StatusOK {
		t.Fatalf("export = %d %s", code, raw)
	}
	rows, err := csv.NewReader(bytes.NewReader(raw)).ReadAll()
	if err != nil {
		t.Fatalf("export is no CSV: %v: %s", err, raw)
	}
	if len(rows) != 3 || strings.Join(rows[0], ",") != "first_name,last_name,email,phone,google_resource" {
		t.Fatalf("export = %q, want the header and 2 rows", rows)
	}
	if strings.Join(rows[1], ",") != ctFirst+","+ctLast+","+ctEmail+","+ctPhone+"," {
		t.Errorf("first row = %q", rows[1])
	}
	if strings.Contains(string(raw), "Stranger") || strings.Contains(string(raw), "stranger@example.com") {
		t.Error("the export carries another person's contact")
	}
}

// C7b: a contact not linked under the bound account is gone at once (hard);
// twin: linked under the account of P1's enabled binding, it is a soft
// delete the sync cycle still reads (its Google delete to send).
func TestContactsDeleteHardOrSoft(t *testing.T) {
	c := newContactsRig(t, onAll)
	const account = "p1.google@example.com"
	c.connect(t, c.w1, account)
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", map[string]any{"enabled": true}, nil); code != http.StatusNoContent {
		t.Fatalf("PUT sync on = %d %v", code, out)
	}
	plain := c.create(t, c.b1, map[string]any{"first_name": "Plain"})
	other := c.create(t, c.b1, map[string]any{"first_name": "OtherAccount"})
	linked := c.create(t, c.b1, map[string]any{"first_name": "Linked"})
	c.link(t, other, "another.account@example.com", "people/c2")
	c.link(t, linked, account, "people/c1")
	for _, id := range []string{plain, other, linked} {
		if code, _, out := c.do(t, c.b1, http.MethodDelete, contactsBase+"/"+id, nil, nil); code != http.StatusNoContent {
			t.Fatalf("DELETE = %d %v", code, out)
		}
		if code, _, _ := c.do(t, c.b1, http.MethodGet, contactsBase+"/"+id, nil, nil); code != http.StatusNotFound {
			t.Errorf("GET after DELETE = %d, want 404 at once", code)
		}
	}
	got := c.pending(t)
	if _, kept := got[plain]; kept {
		t.Error("C7b: an unlinked contact was kept after its delete, want it hard-deleted")
	}
	if _, kept := got[other]; kept {
		t.Error("C7b: a contact linked under another account was kept, want it hard-deleted")
	}
	if !got[linked] {
		t.Errorf("twin: the linked contact under the bound account = %v, want a soft delete", got)
	}
}

// C7c: a member-deleted, linked contact 31 days old whose Google delete
// never went out is purged by the sweep and the binding's status_detail
// says so; twin: one 29 days old stays.
func TestContactsPurgeSweep(t *testing.T) {
	c := newContactsRig(t, onAll)
	const account = "p1.google@example.com"
	c.connect(t, c.w1, account)
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", map[string]any{"enabled": true}, nil); code != http.StatusNoContent {
		t.Fatalf("PUT sync on = %d %v", code, out)
	}
	old := c.create(t, c.b1, map[string]any{"first_name": "Old"})
	young := c.create(t, c.b1, map[string]any{"first_name": "Young"})
	c.link(t, old, account, "people/c-old")
	c.link(t, young, account, "people/c-young")
	now := time.Now().UTC().Truncate(time.Second)
	for id, age := range map[string]time.Duration{old: 31 * 24 * time.Hour, young: 29 * 24 * time.Hour} {
		c.clk.set(now.Add(-age))
		if code, _, out := c.do(t, c.b1, http.MethodDelete, contactsBase+"/"+id, nil, nil); code != http.StatusNoContent {
			t.Fatalf("DELETE = %d %v", code, out)
		}
	}
	if got := c.pending(t); !got[old] || !got[young] {
		t.Fatalf("CONTROL: before the sweep both soft deletes are held: %v", got)
	}
	c.clk.set(now)
	c.r.e.srv.SweepContacts(context.Background())
	got := c.pending(t)
	if _, kept := got[old]; kept {
		t.Error("C7c: the 31-day-old soft delete was not purged")
	}
	if !got[young] {
		t.Error("twin: the 29-day-old soft delete was purged")
	}
	b, err := c.r.e.st.(store.ContactsSyncs).ContactsSyncOf(context.Background(), c.p1)
	if err != nil || b.StatusDetail != store.ContactsPurgePendingDetail {
		t.Errorf("C7c: the binding = %+v %v, want status_detail %q", b, err, store.ContactsPurgePendingDetail)
	}
}

// C7d: the switch in W2 while P1's binding is in W1 is 409
// contacts_sync_elsewhere and W1's binding is unchanged; twin: with no
// binding elsewhere the switch in W1 is 204. Sync now: 202 where the
// binding is, 409 gcal_not_connected elsewhere.
func TestContactsSyncElsewhere(t *testing.T) {
	c := newContactsRig(t, onAll)
	on := map[string]any{"enabled": true}
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", on, nil); code != http.StatusConflict || realmToken(out) != "gcal_not_connected" {
		t.Errorf("PUT sync with no Google connection = %d %v, want 409 gcal_not_connected", code, out)
	}
	c.connect(t, c.w1, "p1.google@example.com")
	c.connect(t, c.w2, "p1.google@example.com")
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", on, nil); code != http.StatusNoContent {
		t.Fatalf("twin: PUT sync in W1 = %d %v, want 204", code, out)
	}
	if code, _, out := c.do(t, c.b2, http.MethodPut, contactsBase+"/sync", on, nil); code != http.StatusConflict || realmToken(out) != "contacts_sync_elsewhere" {
		t.Errorf("C7d: PUT sync in W2 = %d %v, want 409 contacts_sync_elsewhere", code, out)
	}
	b, err := c.r.e.st.(store.ContactsSyncs).ContactsSyncOf(context.Background(), c.p1)
	if err != nil || b.Tenant != c.w1 || !b.Enabled {
		t.Errorf("C7d: P1's binding = %+v %v, want W1's, enabled", b, err)
	}
	if code, _, out := c.do(t, c.b1, http.MethodPost, contactsBase+"/sync", nil, nil); code != http.StatusAccepted {
		t.Errorf("Sync now in W1 = %d %v, want 202", code, out)
	}
	if code, _, out := c.do(t, c.b2, http.MethodPost, contactsBase+"/sync", nil, nil); code != http.StatusConflict || realmToken(out) != "gcal_not_connected" {
		t.Errorf("Sync now in W2 = %d %v, want 409 gcal_not_connected", code, out)
	}
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", map[string]any{"enabled": false}, nil); code != http.StatusNoContent {
		t.Errorf("PUT sync off in W1 = %d %v, want 204", code, out)
	}
	if b, _ := c.r.e.st.(store.ContactsSyncs).ContactsSyncOf(context.Background(), c.p1); b.Enabled {
		t.Error("the binding is still enabled after the switch off")
	}
}

// C8e: DELETE ?scope=spool from W2 leaves 0 rows of P1's list from every
// workspace, a soft-deleted one too, and P1's binding (in W1) disabled;
// twin: another person's list stays.
func TestContactsEraseAll(t *testing.T) {
	c := newContactsRig(t, onAll)
	const account = "p1.google@example.com"
	c.connect(t, c.w1, account)
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", map[string]any{"enabled": true}, nil); code != http.StatusNoContent {
		t.Fatalf("PUT sync on = %d %v", code, out)
	}
	c.create(t, c.b1, map[string]any{"first_name": ctFirst})
	soft := c.create(t, c.b1, map[string]any{"first_name": "Soft"})
	c.link(t, soft, account, "people/c-soft")
	if code, _, _ := c.do(t, c.b1, http.MethodDelete, contactsBase+"/"+soft, nil, nil); code != http.StatusNoContent {
		t.Fatalf("DELETE soft = %d", code)
	}
	stranger, _ := c.other(t, "")
	c.create(t, stranger, map[string]any{"first_name": "Stranger"})

	if code, _, out := c.do(t, c.b2, http.MethodDelete, contactsBase, nil, nil); code != http.StatusBadRequest || realmToken(out) != "scope_required" {
		t.Errorf("DELETE without scope = %d %v, want 400 scope_required", code, out)
	}
	if len(c.pending(t)) != 2 {
		t.Fatalf("CONTROL: before the erase P1 holds 2 rows: %v", c.pending(t))
	}
	if code, _, out := c.do(t, c.b2, http.MethodDelete, contactsBase+"?scope=spool", nil, nil); code != http.StatusNoContent {
		t.Fatalf("DELETE ?scope=spool = %d %v, want 204", code, out)
	}
	if got := c.pending(t); len(got) != 0 {
		t.Errorf("C8e: P1 still holds rows after the erase: %v", got)
	}
	for _, b := range []*http.Client{c.b1, c.b2} {
		if code, _, out := c.do(t, b, http.MethodGet, contactsBase, nil, nil); code != http.StatusOK || len(contactsOf(t, out)) != 0 {
			t.Errorf("C8e: list after the erase = %d %v, want none", code, out)
		}
	}
	b, err := c.r.e.st.(store.ContactsSyncs).ContactsSyncOf(context.Background(), c.p1)
	if err != nil || b.Enabled {
		t.Errorf("C8e: P1's binding = %+v %v, want it disabled", b, err)
	}
	if code, _, out := c.do(t, stranger, http.MethodGet, contactsBase, nil, nil); code != http.StatusOK || len(contactsOf(t, out)) != 1 {
		t.Errorf("twin: the other person's list = %d %v, want 1", code, out)
	}
}

// The wrapper above must keep the stores the hub asserts: a missing one
// would turn every contacts route into 404 and pass C4/C6 for the wrong
// reason.
func TestContactsRigKeepsStores(t *testing.T) {
	var s store.Store = &contactsCloneStore{}
	for name, ok := range map[string]bool{
		"PersonalContacts": func() bool { _, ok := s.(store.PersonalContacts); return ok }(),
		"ContactsSyncs":    func() bool { _, ok := s.(store.ContactsSyncs); return ok }(),
		"Gcal":             func() bool { _, ok := s.(store.Gcal); return ok }(),
		"Humans":           func() bool { _, ok := s.(store.Humans); return ok }(),
		"MembershipLister": func() bool { _, ok := s.(store.MembershipLister); return ok }(),
	} {
		if !ok {
			t.Errorf("contactsCloneStore hides store.%s", name)
		}
	}
}
