package hub_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/invitemail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/121 T206: the e-mail relink (embed_relink.go).

// relinkRig is a hub with the embed on (as on says), a clock the test
// moves, a recording relink mailer and the hub's log.
type relinkRig struct {
	e    *env
	mu   sync.Mutex
	now  time.Time
	sent []relinkMail
	logs *lockedBuf
}

type relinkMail struct{ to, link, locale string }

func newRelinkRig(t *testing.T, on bool) *relinkRig {
	t.Helper()
	// The clock starts on the hour, so the test's 15-minute step never
	// crosses the hourly window of the mail cap.
	g := &relinkRig{now: time.Now().UTC().Truncate(time.Hour), logs: &lockedBuf{}}
	g.e = rbacEnv(t, func(o *hub.Options) {
		o.EmbedEnabled, o.EmbedTokenLife, o.EmbedMessageMaxBytes = on, embedLife, 4096
		o.Log = zerolog.New(g.logs)
		o.Now = g.clock
		o.EmbedRelinkMail = func(ctx context.Context, to, link string, ttl time.Duration) error {
			if ttl != 15*time.Minute {
				t.Errorf("mailed ttl %v, want 15m", ttl)
			}
			g.mu.Lock()
			defer g.mu.Unlock()
			g.sent = append(g.sent, relinkMail{to, link, invitemail.RelinkLocale(ctx)})
			return nil
		}
	})
	return g
}

func (g *relinkRig) clock() time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.now
}

func (g *relinkRig) advance(d time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.now = g.now.Add(d)
}

func (g *relinkRig) mails() []relinkMail {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]relinkMail(nil), g.sent...)
}

// staffAnswer plants a staff line in the visitor channel ch.
func staffAnswer(t *testing.T, pg *store.Postgres, tid, ch string, at time.Time) {
	t.Helper()
	m := store.Message{TenantID: tid, MsgID: newUUID(t), TaskID: newUUID(t), TS: at, FromBox: "box-wui", FromID: "HUM-staff",
		ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: "staff answer", Channel: ch, IsParent: 1, Files: []byte(`[]`),
		Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte("env-" + ch), ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := pg.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

func newUUID(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	b[6], b[8] = b[6]&0x0f|0x40, b[8]&0x3f|0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// relinkVisitor mints a visitor of a fresh enabled embed (origin
// https://example.com), plants a staff answer and sets its address.
func relinkVisitor(t *testing.T, g *relinkRig, pg *store.Postgres, tid, email string) (embed, tok, ch string) {
	t.Helper()
	embed = seedEmbed(t, pg, tid, true)
	tok, ch = mint(t, g.e, tid, embed)
	staffAnswer(t, pg, tid, ch, g.clock())
	if code, raw := embedCall(t, g.e, tid, http.MethodPut, "/v1/embed/"+embed+"/visitor/email", tok, `{"email":"`+email+`"}`); code != http.StatusNoContent {
		t.Fatalf("set email: %d %s", code, raw)
	}
	return embed, tok, ch
}

// codeOf is the relink code of a mailed link.
func codeOf(t *testing.T, link string) string {
	t.Helper()
	_, code, ok := strings.Cut(link, "#spool-relink=")
	if !ok || code == "" {
		t.Fatalf("link %q carries no code", link)
	}
	return code
}

func relinkRedeem(t *testing.T, g *relinkRig, tid, embed, code string) (int, map[string]string) {
	t.Helper()
	st, raw := embedCall(t, g.e, tid, http.MethodPost, "/v1/embed/"+embed+"/relink/redeem", "", `{"code":"`+code+`"}`)
	out := map[string]string{}
	_ = json.Unmarshal(raw, &out)
	return st, out
}

// TestEmbedRelinkOffIsUnknownPath: with env.hub.embed.enabled off every
// relink route a visitor calls answers exactly as a path the hub does not
// serve. CONTROL: on, the same redeem is the link's own refusal, 410.
func TestEmbedRelinkOffIsUnknownPath(t *testing.T) {
	off := newRelinkRig(t, false).e
	tid, _ := off.tenant()
	unknownCode, unknown := embedCall(t, off, tid, http.MethodGet, "/v1/no-such-route", "", "")
	embed := "e-none"
	if pg, ok := off.st.(*store.Postgres); ok {
		embed = seedEmbed(t, pg, tid, true)
	}
	for _, c := range []struct{ method, path, body string }{
		{http.MethodPut, "/visitor/email", `{"email":"v@example.com"}`},
		{http.MethodPost, "/relink", `{"email":"v@example.com"}`},
		{http.MethodPost, "/relink/redeem", `{"code":"x"}`},
	} {
		code, raw := embedCall(t, off, tid, c.method, "/v1/embed/"+embed+c.path, strings.Repeat("A", 43), c.body)
		if code != unknownCode || !bytes.Equal(raw, unknown) {
			t.Errorf("flag off: %s %s = %d %q, want the unknown path's %d %q", c.method, c.path, code, raw, unknownCode, unknown)
		}
	}
	on := newRelinkRig(t, true)
	pg := pgOnly(t, on.e)
	tid2, _ := on.e.tenant()
	if code, _ := relinkRedeem(t, on, tid2, seedEmbed(t, pg, tid2, true), "x"); code != http.StatusGone {
		t.Fatalf("CONTROL: flag on, redeem of a bad code = %d, want 410", code)
	}
}

// TestEmbedRelinkEmailAfterFirstAnswer: the address is refused (409, nothing
// stored) until the channel holds an answer; then a valid one is stored
// lower-cased, a malformed one is 400 and no token is 401.
func TestEmbedRelinkEmailAfterFirstAnswer(t *testing.T) {
	g := newRelinkRig(t, true)
	pg := pgOnly(t, g.e)
	tid, _ := g.e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, ch := mint(t, g.e, tid, embed)
	path := "/v1/embed/" + embed + "/visitor/email"
	if code, raw := embedCall(t, g.e, tid, http.MethodPost, "/v1/embed/"+embed+"/messages", tok, solvedPost(t, g.e, tid, embed, tok, "a question")); code != http.StatusCreated {
		t.Fatalf("post: %d %s", code, raw)
	}
	if code, raw := embedCall(t, g.e, tid, http.MethodPut, path, tok, `{"email":"v@example.com"}`); code != http.StatusConflict ||
		!strings.Contains(string(raw), hub.ErrEmbedNoAnswer) {
		t.Errorf("before the first answer: %d %s, want 409 %s", code, raw, hub.ErrEmbedNoAnswer)
	}
	if got, _ := pg.EmbedVisitorEmails(context.Background(), tid, embed); len(got) != 0 {
		t.Errorf("the refused address was stored: %+v", got)
	}
	staffAnswer(t, pg, tid, ch, g.clock())
	for body, want := range map[string]int{
		`{"email":"not an address"}`:                               http.StatusBadRequest,
		`{"email":"V <v@example.com>"}`:                            http.StatusBadRequest,
		`{"email":"v@example.com","x":1}`:                          http.StatusBadRequest,
		`{"email":"` + strings.Repeat("a", 320) + `@example.com"}`: http.StatusBadRequest,
	} {
		if code, raw := embedCall(t, g.e, tid, http.MethodPut, path, tok, body); code != want {
			t.Errorf("%.60s: %d %s, want %d", body, code, raw, want)
		}
	}
	if code, _ := embedCall(t, g.e, tid, http.MethodPut, path, "", `{"email":"v@example.com"}`); code != http.StatusUnauthorized {
		t.Errorf("no token: %d, want 401", code)
	}
	if code, raw := embedCall(t, g.e, tid, http.MethodPut, path, tok, `{"email":" V@Example.com "}`); code != http.StatusNoContent {
		t.Fatalf("CONTROL: after the answer: %d %s, want 204", code, raw)
	}
	if got, err := pg.EmbedVisitorEmails(context.Background(), tid, embed); err != nil || len(got) != 1 || got[0].Email != "v@example.com" {
		t.Errorf("stored %+v (%v), want v@example.com", got, err)
	}
}

// TestEmbedRelinkLinkIsSingleUse (the T206 done line, first half): the ask
// mails one link to the address on the embed's origin; its redeem binds a
// new token to the same visitor and channel and kills the old one; the same
// link again is 410 (reused), a fresh link redeemed after 15 minutes is 410
// (expired), a forged one is 410. An unknown address gets the same 202 and
// no mail; a return_url off the embed's origins is 400; past 3 mails an
// hour the ask still answers 202 and mails nothing. No log line carries the
// address or a link.
func TestEmbedRelinkLinkIsSingleUse(t *testing.T) {
	g := newRelinkRig(t, true)
	pg := pgOnly(t, g.e)
	tid, _ := g.e.tenant()
	embed, oldTok, ch := relinkVisitor(t, g, pg, tid, "v@example.com")
	ask := func(body string) (int, string) {
		code, raw := embedCall(t, g.e, tid, http.MethodPost, "/v1/embed/"+embed+"/relink", "", body)
		return code, string(raw)
	}
	codeK, known := ask(`{"email":"V@example.com"}`)
	codeU, unknown := ask(`{"email":"nobody@example.com"}`)
	if codeK != http.StatusAccepted || codeU != codeK || unknown != known {
		t.Errorf("known %d %s, unknown %d %s: want one 202 answer", codeK, known, codeU, unknown)
	}
	sent := g.mails()
	if len(sent) != 1 || sent[0].to != "v@example.com" || !strings.HasPrefix(sent[0].link, "https://example.com/#spool-relink=") {
		t.Fatalf("mailed %+v, want one link on https://example.com to v@example.com", sent)
	}
	link := codeOf(t, sent[0].link)

	code, out := relinkRedeem(t, g, tid, embed, link)
	if code != http.StatusCreated || out["token"] == "" || out["token"] == oldTok || out["channel"] != ch {
		t.Fatalf("redeem: %d %v, want 201 with a new token for channel %s", code, out, ch)
	}
	if got := readLines(t, g.e, tid, embed, out["token"]); len(got.Messages) != 1 || got.Messages[0].Body != "staff answer" {
		t.Errorf("the new token reads %+v, want the same channel", got)
	}
	if c, _ := embedCall(t, g.e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", oldTok, ""); c != http.StatusUnauthorized {
		t.Errorf("the old token after the relink: %d, want 401", c)
	}
	if code, _ := relinkRedeem(t, g, tid, embed, link); code != http.StatusGone {
		t.Errorf("the same link again (reused): %d, want 410", code)
	}

	if c, _ := ask(`{"email":"v@example.com","return_url":"https://example.com/pricing?x=1#old"}`); c != http.StatusAccepted {
		t.Fatalf("second ask: %d", c)
	}
	sent = g.mails()
	if len(sent) != 2 || !strings.HasPrefix(sent[1].link, "https://example.com/pricing?x=1#spool-relink=") {
		t.Fatalf("second mail %+v, want the return_url page", sent)
	}
	fresh := codeOf(t, sent[1].link)
	forged := []byte(fresh)
	forged[len(forged)-2] ^= 1
	if code, _ := relinkRedeem(t, g, tid, embed, string(forged)); code != http.StatusGone {
		t.Errorf("a forged link: %d, want 410", code)
	}
	if code, _ := relinkRedeem(t, g, tid, seedEmbed(t, pg, tid, true), fresh); code != http.StatusGone {
		t.Errorf("the link on another embed: %d, want 410", code)
	}
	g.advance(15*time.Minute + time.Second)
	if code, _ := relinkRedeem(t, g, tid, embed, fresh); code != http.StatusGone {
		t.Errorf("the link after 15 minutes (expired): %d, want 410", code)
	}

	if c, raw := ask(`{"email":"v@example.com","return_url":"https://evil.example.net/"}`); c != http.StatusBadRequest {
		t.Errorf("a return_url off the embed's origins: %d %s, want 400", c, raw)
	}
	for range 3 {
		ask(`{"email":"v@example.com"}`)
	}
	if n := len(g.mails()); n != 3 {
		t.Errorf("%d mails after 5 asks in an hour, want 3 (the cap)", n)
	}
	logs := ""
	for _, l := range g.logs.lines(t) {
		raw, _ := json.Marshal(l)
		logs += string(raw)
	}
	if strings.Contains(logs, "v@example.com") || strings.Contains(logs, link) || !strings.Contains(logs, "embed.relink_mailed") {
		t.Errorf("logs carry the address or a link, or no mail line:\n%s", logs)
	}
}

// TestEmbedRelinkMailLocale (specs/121 T206b): the ask's optional locale is
// the mail's, normalized ("sv-SE" -> sv); an unknown one ("xx") is the hub's
// default (none in this rig: "", which the mail renders in en), never an
// error. A locale opens no oracle: the unknown address with a locale gets
// the known one's 202, byte for byte, and no mail.
func TestEmbedRelinkMailLocale(t *testing.T) {
	g := newRelinkRig(t, true)
	pg := pgOnly(t, g.e)
	tid, _ := g.e.tenant()
	embed, _, _ := relinkVisitor(t, g, pg, tid, "v@example.com")
	ask := func(body string) (int, string) {
		code, raw := embedCall(t, g.e, tid, http.MethodPost, "/v1/embed/"+embed+"/relink", "", body)
		return code, string(raw)
	}
	codeK, known := ask(`{"email":"v@example.com","locale":"fi"}`)
	codeU, unknown := ask(`{"email":"nobody@example.com","locale":"fi"}`)
	if codeK != http.StatusAccepted || codeU != codeK || unknown != known {
		t.Errorf("known %d %s, unknown %d %s: want one 202 answer", codeK, known, codeU, unknown)
	}
	for _, body := range []string{`{"email":"v@example.com","locale":"sv-SE"}`, `{"email":"v@example.com","locale":"xx"}`} {
		if c, raw := ask(body); c != http.StatusAccepted || raw != known {
			t.Errorf("%s: %d %s, want the same 202", body, c, raw)
		}
	}
	var got []string
	for _, m := range g.mails() {
		got = append(got, m.to+"/"+m.locale)
	}
	if strings.Join(got, " ") != "v@example.com/fi v@example.com/sv v@example.com/" {
		t.Errorf("mailed %v, want fi, sv, then the default", got)
	}
}

// TestEmbedRelinkEmailOwnerOnly (the T206 done line, second half): the
// address is visible to the workspace owner only. An admin and a developer
// of the same workspace get 403 on the owner route; the visitor's token
// opens it not; no visitor answer and no member list carries it. CONTROL:
// the owner reads it there, so every absence is the guard's.
func TestEmbedRelinkEmailOwnerOnly(t *testing.T) {
	g := newRelinkRig(t, true)
	pg := pgOnly(t, g.e)
	tid, _ := g.e.tenant()
	embed, tok, _ := relinkVisitor(t, g, pg, tid, "secret.visitor@example.com")
	path := "/v1/tenant/embeds/" + embed + "/visitor-emails"
	for _, role := range []string{rbac.Admin, rbac.Developer} {
		m := seat(t, g.e, tid, role)
		if code, body := call(t, g.e, tid, http.MethodGet, path, m, nil); code != http.StatusForbidden || body["permission"] != "tenant.owner" {
			t.Errorf("%s: %d %v, want 403 tenant.owner", role, code, body)
		}
		_, members := call(t, g.e, tid, http.MethodGet, "/v1/members", m, nil)
		if raw, _ := json.Marshal(members); strings.Contains(string(raw), "secret.visitor") {
			t.Errorf("the member list (%s) carries the address: %s", role, raw)
		}
	}
	if code, raw := embedCall(t, g.e, tid, http.MethodGet, path, tok, ""); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Errorf("the visitor's token: %d %s, want 401/403", code, raw)
	}
	if _, raw := embedCall(t, g.e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", tok, ""); strings.Contains(string(raw), "secret.visitor") {
		t.Errorf("the visitor's read carries the address: %s", raw)
	}
	owner := seat(t, g.e, tid, rbac.BizOwner)
	code, body := call(t, g.e, tid, http.MethodGet, path, owner, nil)
	if raw, _ := json.Marshal(body); code != http.StatusOK || !strings.Contains(string(raw), `"email":"secret.visitor@example.com"`) {
		t.Fatalf("CONTROL: the owner reads %d %s, want 200 with the address", code, raw)
	}
}
