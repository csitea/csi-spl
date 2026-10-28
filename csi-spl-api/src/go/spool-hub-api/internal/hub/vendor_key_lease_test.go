package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"filippo.io/age"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 159 T5 with spec 127 H2 (rdb 0235): the lease route's checks, the
// box's exhausted report, the manager's retry and the fall-back switch,
// driven through the desk's own client (hubclient.VendorKeyHub), so the
// tokens the desk passes to a seat are the ones asserted here. The key is
// the fake sk-test-0000.

// keyBox is a box of tid whose pin declared mode ("" = none), as a join
// token redeem records it.
func keyBox(t *testing.T, e *env, tid, id, mode string) *box {
	t.Helper()
	b := e.box(tid, id)
	raw, _ := base64.StdEncoding.DecodeString(b.pub)
	jt := e.st.(store.JoinTokens)
	h := make([]byte, 32)
	rand.Read(h) //nolint:errcheck
	now := time.Now()
	tok := store.JoinToken{Hash: hex.EncodeToString(h), TenantID: tid, CreatedBy: "HUM-1", CreatedAt: now, ExpiresAt: now.Add(time.Hour)}
	if err := jt.CreateJoinToken(context.Background(), tok); err != nil {
		t.Fatal(err)
	}
	if _, err := jt.RedeemJoinToken(context.Background(), tid, tok.Hash, id, ed25519.PublicKey(raw), mode, now); err != nil {
		t.Fatal(err)
	}
	return b
}

// enrolDesk gives box's pin a fresh desk recipient, as a join of a box with
// a key desk records it (rdb 0235), and returns the desk's identity.
func enrolDesk(t *testing.T, e *env, tid, box string) *age.X25519Identity {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	if err := e.st.(store.PinX25519).SetPinBoxX25519(context.Background(), tid, box, id.Recipient().String(), time.Now()); err != nil {
		t.Fatal(err)
	}
	return id
}

// refusal is the desk's token for err ("" = no error).
func refusal(err error) string {
	var re *keydesk.Refused
	if errors.As(err, &re) {
		return re.Token
	}
	if err != nil {
		return "error: " + err.Error()
	}
	return ""
}

// TestVendorKeyLeaseRedControl is the T5 red control, hub half: a box
// reports the vendor's refusal (as keyexec does on a fake 402) -> the next
// lease of that kind is 409 key_exhausted, on every box of the workspace;
// a retry clears it. Before the report the same lease passes every check
// and stops at the seal (increment 3).
func TestVendorKeyLeaseRedControl(t *testing.T) {
	logs := &syncBuf{}
	e, mail := vkEnv(t, func(o *hub.Options) { o.Log = zerolog.New(logs).Level(zerolog.DebugLevel) })
	ctx := context.Background()
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	// An admin biz invited: confirmed, so it still writes once a key is set
	// (an operator-made manager is not: 127 Q-4 A, T1).
	admin, _ := seatBy(t, e, tid, rbac.Admin, biz)
	a := keyBox(t, e, tid, "box-a", store.BoxModeDedicated)
	b := keyBox(t, e, tid, "box-b", store.BoxModeDedicated)
	ha, hb := hubclient.VendorKeyHub{C: a.c}, hubclient.VendorKeyHub{C: b.c}
	lp := e.st.(store.VendorKeyLeases)

	if _, err := ha.Lease(ctx, "claude"); refusal(err) != "box_not_approved" {
		t.Fatalf("unapproved box: %v, want box_not_approved", err)
	}
	for _, id := range []string{"box-a", "box-b"} {
		if err := lp.ApproveVendorKeyBox(ctx, tid, id, biz, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := ha.Lease(ctx, "claude"); refusal(err) != "no_key" {
		t.Fatalf("no key: %v, want no_key", err)
	}
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("PUT = %d %v", code, body)
	}
	// 127 5.2 step 3: box-b's pin has no desk recipient, so nothing is
	// sealed to it; box-a's desk opens the answer to the key.
	if _, err := hb.Lease(ctx, "claude"); refusal(err) != "box_key_not_enrolled" {
		t.Fatalf("box-b lease: %v, want box_key_not_enrolled", err)
	}
	idA := enrolDesk(t, e, tid, "box-a")
	enrolDesk(t, e, tid, "box-b")
	sealed, err := ha.Lease(ctx, "claude")
	if err != nil {
		t.Fatalf("lease before the refusal: %v", err)
	}
	if strings.Contains(string(sealed), fakeVendorKey) {
		t.Fatal("the lease answer carries the key in the clear")
	}
	p, err := keydesk.Open(idA, sealed)
	if err != nil || p.Key != fakeVendorKey || p.Kind != "claude" || p.Box != "box-a" || p.KeyID == "" || p.TTLSeconds != 900 {
		t.Fatalf("opened lease %v, %v", p, err)
	}
	other, _ := age.GenerateX25519Identity()
	if _, err := keydesk.Open(other, sealed); err == nil {
		t.Fatal("CONTROL: another desk's identity opened box-a's lease")
	}
	mail.take()
	if err := ha.Exhausted(ctx, "claude", ""); err != nil {
		t.Fatalf("exhausted report: %v", err)
	}
	// 159 9 point 5: every admin and biz owner, once per refusal, last4 only.
	if got := mail.take(); len(got) != 2 || !strings.HasSuffix(got[0], " exhausted claude 0000") || !strings.HasSuffix(got[1], " exhausted claude 0000") {
		t.Fatalf("mail after the refusal = %v, want the biz owner and the admin, once each", got)
	}
	for name, h := range map[string]hubclient.VendorKeyHub{"box-a": ha, "box-b": hb} {
		if _, err := h.Lease(ctx, "claude"); refusal(err) != "key_exhausted" {
			t.Fatalf("%s lease after the refusal: %v, want key_exhausted", name, err)
		}
	}
	if err := hb.Exhausted(ctx, "claude", ""); err != nil {
		t.Fatalf("second report: %v", err)
	}
	if got := mail.take(); len(got) != 0 {
		t.Fatalf("mail after a second report of the same refusal = %v, want none", got)
	}
	code, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", admin, nil)
	if row := keyRow(t, body, "claude"); code != http.StatusOK || row["exhausted"] != true || row["exhausted_at"] == nil {
		t.Fatalf("GET = %d %v, want claude exhausted", code, body)
	}
	if body["metered_fallback"] != false {
		t.Fatalf("metered_fallback = %v, want false by default", body["metered_fallback"])
	}
	if code, body := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/claude/retry", admin, nil); code != http.StatusNoContent {
		t.Fatalf("retry = %d %v", code, body)
	}
	if _, err := ha.Lease(ctx, "claude"); err != nil {
		t.Fatalf("lease after retry: %v", err)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/qwen/retry", admin, nil); code != http.StatusNotFound {
		t.Fatalf("retry of an unset kind = %d, want 404", code)
	}
	// 127 L4 on the lease path: two answered leases, the key in no log line.
	if strings.Contains(logs.String(), fakeVendorKey) || !strings.Contains(logs.String(), "vendor_key.leased") {
		t.Fatalf("hub log: the key is in it, or no lease was logged:\n%s", logs.String())
	}
}

// TestVendorKeyExhaustedTopicLine (spec 159 9 point 3): a report that names
// the running task posts ONE hub line in that task's topic, on the first
// report only; a repeat writes nothing. A task id of another workspace, a
// direct-message topic, a task id that is not a UUID and a report with no
// task post nothing, and the
// refusal is recorded all the same. CONTROL: the other workspace's own box,
// reporting its own task, does get the line, so the zero of the
// cross-workspace case is the workspace check, not a dead path.
func TestVendorKeyExhaustedTopicLine(t *testing.T) {
	e, _ := vkEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	other, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	mine, theirs, dm := uuidV4(), uuidV4(), uuidV4()
	for _, c := range []struct{ tenant, task, channel string }{{tid, mine, "work"}, {other, theirs, "work"}, {tid, dm, ""}} {
		if c.channel != "" {
			if err := e.st.CreateChannel(ctx, store.Channel{TenantID: c.tenant, ChannelID: c.channel, Name: c.channel,
				CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
				t.Fatal(err)
			}
		}
		putRowWith(t, privacyRig{e: e, tid: c.tenant}, c.task, c.channel, "HUM-1", "c-001", now, func(*store.Message) {})
	}
	lines := func(tenant, task string) [][]byte { return hubNotes(t, privacyRig{e: e, tid: tenant}, task) }
	reporter := func(tenant, box string) (hubclient.VendorKeyHub, string) {
		t.Helper()
		biz := seat(t, e, tenant, rbac.BizOwner)
		if code, body := putKey(t, e, tenant, "claude", biz, nil); code != http.StatusNoContent {
			t.Fatalf("PUT = %d %v", code, body)
		}
		b := keyBox(t, e, tenant, box, store.BoxModeDedicated)
		if err := e.st.(store.VendorKeyLeases).ApproveVendorKeyBox(ctx, tenant, box, biz, time.Now()); err != nil {
			t.Fatal(err)
		}
		return hubclient.VendorKeyHub{C: b.c}, biz
	}
	ha, biz := reporter(tid, "box-a")
	admin, _ := seatBy(t, e, tid, rbac.Admin, biz) // confirmed: it may retry
	report := func(task string) {
		t.Helper()
		if err := ha.Exhausted(ctx, "claude", task); err != nil {
			t.Fatalf("report (task %q): %v", task, err)
		}
		_, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", admin, nil)
		if row := keyRow(t, body, "claude"); row["exhausted"] != true {
			t.Fatalf("after a report (task %q) the key is not exhausted: %v", task, body)
		}
	}
	retry := func() {
		t.Helper()
		if code, body := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/claude/retry", admin, nil); code != http.StatusNoContent {
			t.Fatalf("retry = %d %v", code, body)
		}
	}
	for _, c := range []struct{ name, task string }{{"another workspace's task", theirs}, {"a direct-message topic", dm},
		{"not a uuid", "dispatch-s159"}, {"no task", ""}} {
		report(c.task)
		if uuidOK(c.task) {
			if n := len(lines(tid, c.task)) + len(lines(other, c.task)); n != 0 {
				t.Fatalf("%s: %d lines posted, want none", c.name, n)
			}
		}
		retry()
	}
	if n := len(lines(tid, mine)); n != 0 {
		t.Fatalf("lines in the task's topic before any report names it = %d, want 0", n)
	}
	report(mine)
	report(mine) // the same refusal again: first is false
	got := lines(tid, mine)
	if len(got) != 1 {
		t.Fatalf("lines in the task's topic after two reports of one refusal = %d, want 1:\n%s", len(got), bytes.Join(got, []byte("\n")))
	}
	line := string(got[0])
	if !strings.Contains(line, `"body":"claude key of this workspace refused by the vendor (out of credit or quota); a workspace admin or business owner can replace it on Agent keys."`) ||
		strings.Contains(line, fakeVendorKey) || strings.Contains(line, "box-a") {
		t.Fatalf("the line is not the kind-only text of 9 point 3: %s", line)
	}
	hx, _ := reporter(other, "box-x")
	if err := hx.Exhausted(ctx, "claude", theirs); err != nil {
		t.Fatal(err)
	}
	if n := len(lines(other, theirs)); n != 1 {
		t.Fatalf("CONTROL: the other workspace's own report of its own task posted %d lines, want 1", n)
	}
}

// TestVendorKeyLeaseRefusals: a shared or undeclared pin, an unavailable
// kind, a member's token, and another workspace's box never pass.
func TestVendorKeyLeaseRefusals(t *testing.T) {
	e, _ := vkEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	other, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("PUT = %d %v", code, body)
	}
	lp := e.st.(store.VendorKeyLeases)
	for _, c := range []struct{ id, mode string }{{"box-s", store.BoxModeShared}, {"box-n", ""}} {
		b := keyBox(t, e, tid, c.id, c.mode)
		if err := lp.ApproveVendorKeyBox(ctx, tid, c.id, biz, time.Now()); err != nil {
			t.Fatal(err)
		}
		h := hubclient.VendorKeyHub{C: b.c}
		if _, err := h.Lease(ctx, "claude"); refusal(err) != "box_not_dedicated" {
			t.Errorf("%s lease: %v, want box_not_dedicated", c.id, err)
		}
		if err := h.Exhausted(ctx, "claude", ""); refusal(err) != "box_not_dedicated" {
			t.Errorf("%s exhausted: %v, want box_not_dedicated", c.id, err)
		}
	}
	d := keyBox(t, e, tid, "box-d", store.BoxModeDedicated)
	if err := lp.ApproveVendorKeyBox(ctx, tid, "box-d", biz, time.Now()); err != nil {
		t.Fatal(err)
	}
	hd := hubclient.VendorKeyHub{C: d.c}
	if _, err := hd.Lease(ctx, "grok"); refusal(err) != "kind_not_available" {
		t.Errorf("grok lease: %v, want kind_not_available", err)
	}
	if _, err := hd.Lease(ctx, "openai"); refusal(err) != "bad_kind" {
		t.Errorf("unknown kind: %v, want bad_kind (never a 404: the desk reads it as no route)", err)
	}
	if err := hd.Exhausted(ctx, "qwen", ""); refusal(err) != "no_key" {
		t.Errorf("exhausted of an unset kind: %v, want no_key", err)
	}
	// Another workspace's dedicated, approved box reads its OWN workspace's
	// row: none (127 L1); the key of tid stays usable.
	x := keyBox(t, e, other, "box-x", store.BoxModeDedicated)
	if err := lp.ApproveVendorKeyBox(ctx, other, "box-x", "HUM-9", time.Now()); err != nil {
		t.Fatal(err)
	}
	hx := hubclient.VendorKeyHub{C: x.c}
	if _, err := hx.Lease(ctx, "claude"); refusal(err) != "no_key" {
		t.Errorf("other workspace's box: %v, want no_key", err)
	}
	if err := hx.Exhausted(ctx, "claude", ""); refusal(err) != "no_key" {
		t.Errorf("other workspace's report: %v, want no_key", err)
	}
	enrolDesk(t, e, tid, "box-d")
	if _, err := hd.Lease(ctx, "claude"); err != nil {
		t.Errorf("tid's key after the other's report: %v", err)
	}
	// A member's browser token is never a box (the lease route is box-only).
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/claude/lease", biz, nil); code == http.StatusOK || code == http.StatusNotFound {
		t.Errorf("member POST lease = %d, want a refusal that is not a 404", code)
	}
}

// TestVendorKeyMeteredFallbackSwitch: off by default, a manager turns it on
// and off (159 9, owner Q-2 B); a developer cannot.
func TestVendorKeyMeteredFallbackSwitch(t *testing.T) {
	e, _ := vkEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	read := func() any {
		t.Helper()
		_, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", admin, nil)
		return body["metered_fallback"]
	}
	if v := read(); v != false {
		t.Fatalf("default = %v, want false", v)
	}
	for _, on := range []bool{true, false} {
		if code, body := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/settings", admin, map[string]any{"metered_fallback": on}); code != http.StatusNoContent {
			t.Fatalf("PUT %v = %d %v", on, code, body)
		}
		if v := read(); v != on {
			t.Fatalf("after PUT %v: %v", on, v)
		}
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/settings", dev, map[string]any{"metered_fallback": true}); code != http.StatusForbidden {
		t.Fatalf("developer PUT = %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/settings", admin, map[string]any{}); code != http.StatusBadRequest {
		t.Fatalf("empty body = %d, want 400", code)
	}
}

// TestJoinRecordsDeskRecipient (127 5.2 step 3, rdb 0235): a join that
// sends box_x25519 signs it and the pin records it; a re-join without one
// clears it; a malformed one is 400; a signature over the bytes without the
// recipient does not verify (CONTROL: the field is signed).
func TestJoinRecordsDeskRecipient(t *testing.T) {
	e := joinEnv(t)
	tid, _ := joinTenant(t, e)
	admin := seat(t, e, tid, rbac.Admin)
	px := e.st.(store.PinX25519)
	id, _ := age.GenerateX25519Identity()
	rc := id.Recipient().String()
	priv := newKey(t)
	join := func(rcpt string, signRcpt string) (int, string) {
		t.Helper()
		tok, _ := mintToken(t, e, tid, admin, map[string]any{})
		code, eb := redeemKey(t, e, nil, tok, "box-k", store.BoxModeDedicated, rcpt, signRcpt, priv, time.Now())
		return code, eb.Error
	}
	if code, tok := join(rc, rc); code != http.StatusOK {
		t.Fatalf("join = %d %s", code, tok)
	}
	if got, err := px.PinBoxX25519(context.Background(), tid, "box-k"); err != nil || got != rc {
		t.Fatalf("pin recipient %q %v, want %q", got, err, rc)
	}
	if code, tok := join(rc, ""); code != http.StatusBadRequest || tok != "bad_sig" {
		t.Fatalf("recipient outside the signature = %d %s, want 400 bad_sig", code, tok)
	}
	if code, tok := join("age1notarecipient", "age1notarecipient"); code != http.StatusBadRequest || tok != "bad_json" {
		t.Fatalf("malformed recipient = %d %s, want 400 bad_json", code, tok)
	}
	if code, tok := join("", ""); code != http.StatusOK {
		t.Fatalf("re-join without a desk = %d %s", code, tok)
	}
	if got, err := px.PinBoxX25519(context.Background(), tid, "box-k"); err != nil || got != "" {
		t.Fatalf("after a re-join without a recipient: %q %v, want cleared", got, err)
	}
}

// redeemKey is redeemMode with a desk recipient: rcpt in the body, signRcpt
// in the signed bytes (they differ only in a control).
func redeemKey(t *testing.T, e *env, hdr http.Header, tok, box, mode, rcpt, signRcpt string, priv ed25519.PrivateKey, ts time.Time) (int, wire.ErrorBody) {
	t.Helper()
	pub := base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
	at := ts.UTC().Format(time.RFC3339)
	p, _ := wire.JoinKeyPayload(tokenHash(tok), box, pub, at, mode, signRcpt)
	raw, _ := json.Marshal(wire.JoinRequest{Token: tok, BoxID: box, PubKey: pub, TS: at, Sig: sign.Sign(priv, p), BoxMode: mode,
		BoxX25519: rcpt})
	req, _ := http.NewRequest(http.MethodPost, "http://"+apiLabel+domain+"/v1/pins/join", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header[k] = v
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var eb wire.ErrorBody
	json.Unmarshal(body, &eb) //nolint:errcheck
	return resp.StatusCode, eb
}

// uuidOK is whether task can be looked up as a topic (a uuid column on
// Postgres).
func uuidOK(task string) bool {
	return len(task) == 36 && strings.Count(task, "-") == 4
}
