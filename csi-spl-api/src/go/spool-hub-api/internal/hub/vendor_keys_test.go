package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/vendorkey"
)

// Spec 159 T1 with spec 127 H1: vendor_keys.manage for biz_owner and admin,
// GET / PUT / DELETE /v1/vendor-keys, the audit, the act-as refusal, the
// operator-made manager confirmation (127 Q-4 A, 159 section 3) and the
// mail to every admin and biz owner.
//
//   - RED CONTROL (159 T1): a biz_owner PUTs sk-test-0000 -> 204; with
//     vendor_keys.manage taken off biz_owner in rbac.Defaults (rdb 0232) it
//     is 403;
//   - L22 / 127 L3: an operator-made biz_owner or admin, in a workspace that
//     holds a key, PUTs -> 403 admin_unconfirmed until a confirmed manager
//     confirms it (drop the confirmation check and it is 204);
//   - 127 L4: sk-test-0000 is in no hub log line and no answer, on every
//     path that reads it (TestVendorKeysNeverLogTheKey).

const fakeVendorKey = "sk-test-0000"

// vkMail records every vendor key notice the hub sent.
type vkMail struct {
	mu   sync.Mutex
	sent []string // "<to> <action> <kind> <last4>"
}

func (m *vkMail) send(_ context.Context, to, _ string, n hub.VendorKeyNotice) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, to+" "+n.Action+" "+n.Kind+" "+n.Last4)
	return nil
}

func (m *vkMail) take() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := m.sent
	m.sent = nil
	return out
}

func vkSealer(t *testing.T) *vendorkey.Sealer {
	t.Helper()
	s, err := vendorkey.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k", []byte("test-pepper-0123456789"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func vkEnv(t *testing.T, mut ...func(*hub.Options)) (*env, *vkMail) {
	t.Helper()
	m := &vkMail{}
	return rbacEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
		o.VendorKeySealer = vkSealer(t)
		o.VendorKeyMail = m.send
	}}, mut...)...), m
}

// seatBy admits a fresh human to tid with role through an invite by `by`
// (a member HUM-* id: a confirmed membership; store.AdmittedOperator: an
// operator-made one, as seat does).
func seatBy(t *testing.T, e *env, tid, role, by string) (hum, email string) {
	t.Helper()
	h := e.st.(store.Humans)
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	email = hex.EncodeToString(b) + "@example.com"
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: by, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum, email
}

func putKey(t *testing.T, e *env, tid, kind, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	if body == nil {
		body = map[string]any{"key": fakeVendorKey}
	}
	return call(t, e, tid, http.MethodPut, "/v1/vendor-keys/"+kind, as, body)
}

func keyRow(t *testing.T, body map[string]any, kind string) map[string]any {
	t.Helper()
	list, _ := body["kinds"].([]any)
	for _, k := range list {
		if m := k.(map[string]any); m["kind"] == kind {
			return m
		}
	}
	t.Fatalf("kind %s not in %v", kind, body)
	return nil
}

// TestVendorKeysBizOwnerSets is the spec 159 T1 red control.
func TestVendorKeysBizOwnerSets(t *testing.T) {
	e, mail := vkEnv(t)
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	admin, adminMail := seatBy(t, e, tid, rbac.Admin, biz)
	dev := seat(t, e, tid, rbac.Developer)

	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("biz_owner PUT: %d %v, want 204", code, body)
	}
	code, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", biz, nil)
	if code != 200 {
		t.Fatalf("GET: %d %v", code, body)
	}
	row := keyRow(t, body, "claude")
	if row["set"] != true || row["last4"] != "0000" || row["set_by"] != biz || row["available"] != true {
		t.Fatalf("claude row: %v", row)
	}
	// 127 Q-4 A as written: the operator-made biz_owner was unaffected while
	// the workspace held no key, and is unconfirmed now that it holds one,
	// until the admin it invited (a confirmed member) confirms it.
	if body["confirmed"] != false {
		t.Fatalf("operator-made biz_owner after the first key: %v, want confirmed false", body)
	}
	// The mail of 159 section 3: every admin and biz owner, the developer not.
	sent := mail.take()
	if len(sent) != 2 || !strings.Contains(strings.Join(sent, "\n"), adminMail+" set claude 0000") {
		t.Fatalf("mail: %v", sent)
	}

	// A replace by the admin, then a remove.
	if code, body := putKey(t, e, tid, "claude", admin, map[string]any{"key": "sk-test-1111"}); code != http.StatusNoContent {
		t.Fatalf("admin replace: %d %v", code, body)
	}
	if sent := mail.take(); len(sent) != 2 || !strings.Contains(sent[0], " replace claude 1111") {
		t.Fatalf("replace mail: %v", sent)
	}
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/vendor-keys/claude", admin, nil); code != http.StatusNoContent {
		t.Fatalf("DELETE: %d %v", code, body)
	}
	if sent := mail.take(); len(sent) != 2 || !strings.Contains(sent[0], " remove claude 1111") {
		t.Fatalf("remove mail: %v", sent)
	}
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/vendor-keys/claude", admin, nil); code != http.StatusNotFound {
		t.Fatalf("second DELETE: %d, want 404", code)
	}
	_, body = call(t, e, tid, http.MethodGet, "/v1/vendor-keys", admin, nil)
	if row := keyRow(t, body, "claude"); row["set"] != false {
		t.Fatalf("after DELETE: %v", row)
	}

	// No vendor_keys.manage, no route.
	for _, c := range []struct{ method, path string }{
		{http.MethodGet, "/v1/vendor-keys"}, {http.MethodPut, "/v1/vendor-keys/claude"}, {http.MethodDelete, "/v1/vendor-keys/claude"},
	} {
		if code, body := call(t, e, tid, c.method, c.path, dev, map[string]any{"key": fakeVendorKey}); code != http.StatusForbidden || body["permission"] != rbac.VendorKeysManage {
			t.Fatalf("developer %s %s: %d %v, want 403 %s", c.method, c.path, code, body, rbac.VendorKeysManage)
		}
	}
}

// TestVendorKeysOperatorMadeUnconfirmed is spec 159 L22 and spec 127 L3's
// "that admin PUTs a key -> 403 admin_unconfirmed".
func TestVendorKeysOperatorMadeUnconfirmed(t *testing.T) {
	e, _ := vkEnv(t)
	tid, _ := e.tenant()
	first := seat(t, e, tid, rbac.BizOwner) // operator-made, the bootstrap case
	if code, body := putKey(t, e, tid, "claude", first, nil); code != http.StatusNoContent {
		t.Fatalf("operator-made biz_owner, no key yet: %d %v, want 204 (127 5.1: a workspace with no key is unaffected)", code, body)
	}
	confirmed, _ := seatBy(t, e, tid, rbac.Admin, first) // invited by a member: confirmed
	for _, role := range []string{rbac.BizOwner, rbac.Admin} {
		late := seat(t, e, tid, role) // operator-made, the workspace holds a key now
		code, body := putKey(t, e, tid, "qwen", late, map[string]any{"key": fakeVendorKey, "base_url": "https://example.com/v1"})
		if code != http.StatusForbidden || body["error"] != "admin_unconfirmed" {
			t.Fatalf("operator-made %s PUT: %d %v, want 403 admin_unconfirmed", role, code, body)
		}
		if code, body := call(t, e, tid, http.MethodDelete, "/v1/vendor-keys/claude", late, nil); code != http.StatusForbidden || body["error"] != "admin_unconfirmed" {
			t.Fatalf("operator-made %s DELETE: %d %v", role, code, body)
		}
		// Read-only for the unconfirmed (127 8).
		if code, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", late, nil); code != 200 || body["confirmed"] != false {
			t.Fatalf("operator-made %s GET: %d %v, want 200 confirmed false", role, code, body)
		}
		// An unconfirmed manager cannot confirm another, nor itself.
		if code, body := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/managers/"+late, late, map[string]any{}); code != http.StatusForbidden || body["error"] != "admin_unconfirmed" {
			t.Fatalf("self-confirm: %d %v", code, body)
		}
		if code, body := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/managers/"+late, confirmed, map[string]any{}); code != http.StatusNoContent {
			t.Fatalf("confirm %s: %d %v", role, code, body)
		}
		if code, body := putKey(t, e, tid, "qwen", late, map[string]any{"key": fakeVendorKey, "base_url": "https://example.com/v1"}); code != http.StatusNoContent {
			t.Fatalf("confirmed %s PUT: %d %v, want 204", role, code, body)
		}
	}
	dev := seat(t, e, tid, rbac.Developer)
	if code, body := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/managers/"+dev, confirmed, map[string]any{}); code != http.StatusNotFound || body["error"] != "not_a_manager" {
		t.Fatalf("confirm a developer: %d %v, want 404 not_a_manager", code, body)
	}
}

// TestVendorKeysKinds: claude and qwen take keys; grok and mistral wait for
// the vendor's terms (159 4.2) and agy for the B0c gate (127 R5.2); qwen
// needs its https base_url and only qwen takes one.
func TestVendorKeysKinds(t *testing.T) {
	e, _ := vkEnv(t)
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	for _, kind := range []string{"grok", "mistral", "agy"} {
		if code, body := putKey(t, e, tid, kind, biz, nil); code != http.StatusConflict || body["error"] != "kind_not_available" {
			t.Fatalf("%s: %d %v, want 409 kind_not_available", kind, code, body)
		}
	}
	if code, body := putKey(t, e, tid, "nope", biz, nil); code != http.StatusNotFound || body["error"] != "unknown_kind" {
		t.Fatalf("unknown kind: %d %v", code, body)
	}
	for name, b := range map[string]map[string]any{
		"qwen without base_url": {"key": fakeVendorKey},
		"qwen http base_url":    {"key": fakeVendorKey, "base_url": "http://example.com"},
	} {
		if code, body := putKey(t, e, tid, "qwen", biz, b); code != http.StatusUnprocessableEntity {
			t.Fatalf("%s: %d %v, want 422", name, code, body)
		}
	}
	for name, b := range map[string]map[string]any{
		"claude with base_url": {"key": fakeVendorKey, "base_url": "https://example.com"},
		"empty key":            {"key": ""},
		"key with a space":     {"key": "sk-test 0000"},
	} {
		if code, body := putKey(t, e, tid, "claude", biz, b); code != http.StatusUnprocessableEntity {
			t.Fatalf("%s: %d %v, want 422", name, code, body)
		}
	}
	_, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", biz, nil)
	for kind, avail := range map[string]bool{"claude": true, "qwen": true, "grok": false, "mistral": false, "agy": false} {
		if row := keyRow(t, body, kind); row["available"] != avail || row["set"] != false {
			t.Fatalf("%s row: %v", kind, row)
		}
	}
}

// TestVendorKeysOffWithoutSealer: no KMS key or pepper configured -> 503,
// never an unsealed write.
func TestVendorKeysOffWithoutSealer(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusServiceUnavailable || body["error"] != "vendor_keys_off" {
		t.Fatalf("PUT with no sealer: %d %v, want 503 vendor_keys_off", code, body)
	}
}

// cloneMemory marks one human as a live act-as clone, on the memory store.
type cloneMemory struct {
	*store.Memory
	clone string
}

func (c cloneMemory) Clone(_ context.Context, _, hum string) (store.Clone, error) {
	if hum == c.clone {
		return store.Clone{CloneHum: hum}, nil
	}
	return store.Clone{}, store.ErrNotFound
}

// TestVendorKeysActAsRefused: an act-as session gets no vendor key route
// (127 5.1), whatever its role grants.
func TestVendorKeysActAsRefused(t *testing.T) {
	mem := store.NewMemory()
	cm := &cloneMemory{Memory: mem}
	e, _ := vkEnv(t, func(o *hub.Options) { o.Store = cm })
	e.st = cm
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	cm.clone = biz
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusForbidden || body["error"] != "act_as_refused" {
		t.Fatalf("clone PUT: %d %v, want 403 act_as_refused", code, body)
	}
	if code, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", biz, nil); code != http.StatusForbidden || body["error"] != "act_as_refused" {
		t.Fatalf("clone GET: %d %v", code, body)
	}
	cm.clone = ""
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("same member, no clone: %d %v", code, body)
	}
}

// TestVendorKeysNeverLogTheKey is spec 127 L4 (hub half): the fake key goes
// through every path that reads a body (set, replace, refused kind, refused
// shape, unconfirmed, a failing mail relay) with the hub logging at debug;
// no log line and no answer carries it.
func TestVendorKeysNeverLogTheKey(t *testing.T) {
	logs := &syncBuf{}
	e, _ := vkEnv(t, func(o *hub.Options) {
		o.Log = zerolog.New(logs).Level(zerolog.DebugLevel)
		o.VendorKeyMail = func(context.Context, string, string, hub.VendorKeyNotice) error {
			return io.ErrUnexpectedEOF // the relay fails: its error is logged
		}
	})
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	late := ""
	answers := []string{}
	record := func(code int, body map[string]any) {
		raw, _ := json.Marshal(body)
		answers = append(answers, string(raw))
	}
	record(putKey(t, e, tid, "claude", biz, nil))
	record(putKey(t, e, tid, "claude", biz, nil))
	record(putKey(t, e, tid, "grok", biz, nil))
	record(putKey(t, e, tid, "claude", biz, map[string]any{"key": fakeVendorKey, "base_url": "https://example.com"}))
	late = seat(t, e, tid, rbac.Admin)
	record(putKey(t, e, tid, "claude", late, nil))
	record(call(t, e, tid, http.MethodGet, "/v1/vendor-keys", biz, nil))
	record(call(t, e, tid, http.MethodDelete, "/v1/vendor-keys/claude", biz, nil))
	if !strings.Contains(logs.String(), "vendor_key") {
		t.Fatalf("the hub logged nothing about vendor keys; the grep below proves nothing:\n%s", logs.String())
	}
	for _, where := range []struct{ name, text string }{{"hub log", logs.String()}, {"answers", strings.Join(answers, "\n")}} {
		if n := strings.Count(where.text, fakeVendorKey); n != 0 {
			t.Fatalf("%s carries the fake key %d times:\n%s", where.name, n, where.text)
		}
	}
}
