package hub_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/121 T104: the embed visitor API (embed_visitor.go).

var embedLife = store.EmbedTokenLife{Sliding: 30 * 24 * time.Hour, Cap: 180 * 24 * time.Hour}

// embedEnv is a hub with the embed flag as on says, behind the view door
// (hub.ViewDoorToken, the production default, unless door names another;
// the X-Test-Member seam names the member) and with a workspace docs store,
// so the visitor's token is tried against the member routes.
func embedEnv(t *testing.T, on bool, door ...string) *env {
	t.Helper()
	return rbacEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorToken
		if len(door) > 0 {
			o.ViewDoor = door[0]
		}
		o.WorkspaceDocs = wsDocs(t, t.TempDir())
		o.EmbedEnabled, o.EmbedTokenLife, o.EmbedMessageMaxBytes = on, embedLife, 4096
	})
}

// pgOnly is the env's Postgres store; the test skips under the memory store
// (no channel scope to prove: the routes answer 404 there).
func pgOnly(t *testing.T, e *env) *store.Postgres {
	t.Helper()
	pg, ok := e.st.(*store.Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset: the visitor routes need the channel scope")
	}
	return pg
}

// seedEmbed adds an embed of tenant (enabled as on says) and returns its id.
func seedEmbed(t *testing.T, pg *store.Postgres, tenant string, on bool) string {
	t.Helper()
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	id := "e-" + hex.EncodeToString(b)
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO embed_customers (tenant_id, embed_id, allowed_origins, enabled)
		VALUES ($1, $2, '{https://example.com}', $3)`, tenant, id, on); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	return id
}

// embedCall is one visitor request on the hub's apex-less host: the code and
// the raw body. bearer "" sends no Authorization.
func embedCall(t *testing.T, e *env, host, method, path, bearer, body string) (int, []byte) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, e.url(host)+path, rd)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

// mint makes a visitor of embed and returns its token and channel.
func mint(t *testing.T, e *env, tid, embed string) (string, string) {
	t.Helper()
	code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/visitor", "", "")
	var out map[string]string
	if code != http.StatusCreated || json.Unmarshal(raw, &out) != nil || out["token"] == "" || out["channel"] == "" {
		t.Fatalf("mint: %d %s", code, raw)
	}
	return out["token"], out["channel"]
}

type embedLines struct {
	Messages []struct {
		MsgID string `json:"msg_id"`
		Body  string `json:"body"`
		Mine  bool   `json:"mine"`
	} `json:"messages"`
}

func readLines(t *testing.T, e *env, tid, embed, tok string) embedLines {
	t.Helper()
	code, raw := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", tok, "")
	var out embedLines
	if code != http.StatusOK || json.Unmarshal(raw, &out) != nil {
		t.Fatalf("read: %d %s", code, raw)
	}
	return out
}

// TestEmbedRoutesOffAreNotFound: with env.hub.embed.enabled off, every
// visitor route answers exactly as a path the hub does not serve, even for
// an enabled embed and a live token. CONTROL: the same mint with the flag
// on is 201 (under Postgres; the memory store has no channel scope and
// answers 404 too, which the off half also covers).
func TestEmbedRoutesOffAreNotFound(t *testing.T) {
	off := embedEnv(t, false)
	tid, _ := off.tenant()
	unknownCode, unknown := embedCall(t, off, tid, http.MethodGet, "/v1/no-such-route", "", "")
	embed := "e-none"
	tok := strings.Repeat("A", 43)
	if pg, ok := off.st.(*store.Postgres); ok {
		embed = seedEmbed(t, pg, tid, true)
	}
	for _, c := range []struct{ method, path, body string }{
		{http.MethodPost, "/visitor", ""}, {http.MethodDelete, "/visitor", ""},
		{http.MethodGet, "/messages", ""}, {http.MethodPost, "/messages", `{"body":"hi"}`},
	} {
		code, raw := embedCall(t, off, tid, c.method, "/v1/embed/"+embed+c.path, tok, c.body)
		if code != unknownCode || !bytes.Equal(raw, unknown) {
			t.Errorf("flag off: %s %s = %d %q, want the unknown path's %d %q", c.method, c.path, code, raw, unknownCode, unknown)
		}
	}
	on := embedEnv(t, true)
	pg := pgOnly(t, on)
	tid2, _ := on.tenant()
	if code, raw := embedCall(t, on, tid2, http.MethodPost, "/v1/embed/"+seedEmbed(t, pg, tid2, true)+"/visitor", "", ""); code != http.StatusCreated {
		t.Fatalf("CONTROL: flag on, mint = %d %s", code, raw)
	}
}

// TestEmbedVisitorReadPostErase: a visitor mints, reads an empty channel,
// posts, reads its line back marked mine, and erases; after the erasure its
// token is dead. Refused: a post over the byte limit (413), an empty post, a
// post with a file or a channel (no such field), no token, a token of
// another visitor's embed, a token sent as a cookie; a disabled or unknown
// embed mints nothing. CONTROL: visitor B, of the same embed, reads its own
// empty channel the whole time, so A's line was A's alone.
func TestEmbedVisitorReadPostErase(t *testing.T) {
	e := embedEnv(t, true)
	pg := pgOnly(t, e)
	tid, _ := e.tenant()
	embed, other := seedEmbed(t, pg, tid, true), seedEmbed(t, pg, tid, true)
	a, _ := mint(t, e, tid, embed)
	b, _ := mint(t, e, tid, embed)
	base := "/v1/embed/" + embed

	if got := readLines(t, e, tid, embed, a); len(got.Messages) != 0 {
		t.Fatalf("a new channel holds %+v", got)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base+"/messages", a, `{"body":"hello, is this for sale?"}`); code != http.StatusCreated {
		t.Fatalf("post: %d %s", code, raw)
	}
	if got := readLines(t, e, tid, embed, a); len(got.Messages) != 1 || !got.Messages[0].Mine || got.Messages[0].Body != "hello, is this for sale?" {
		t.Fatalf("A reads %+v, want its one line", got)
	}
	if got := readLines(t, e, tid, embed, b); len(got.Messages) != 0 {
		t.Errorf("CONTROL: B reads %+v, want nothing", got)
	}

	for name, c := range map[string]struct {
		path, tok, body string
		want            int
	}{
		"over 4 KB":      {base + "/messages", a, `{"body":"` + strings.Repeat("x", 4097) + `"}`, http.StatusRequestEntityTooLarge},
		"empty":          {base + "/messages", a, `{"body":"  "}`, http.StatusBadRequest},
		"a file":         {base + "/messages", a, `{"body":"hi","files":[{"file_id":"x"}]}`, http.StatusBadRequest},
		"a channel":      {base + "/messages", a, `{"body":"hi","channel":"lobby"}`, http.StatusBadRequest},
		"no token":       {base + "/messages", "", `{"body":"hi"}`, http.StatusUnauthorized},
		"bad token":      {base + "/messages", strings.Repeat("A", 43), `{"body":"hi"}`, http.StatusUnauthorized},
		"another embed":  {"/v1/embed/" + other + "/messages", a, `{"body":"hi"}`, http.StatusUnauthorized},
		"bad embed id":   {"/v1/embed/A_B/messages", a, `{"body":"hi"}`, http.StatusNotFound},
		"disabled embed": {"/v1/embed/" + seedEmbed(t, pg, tid, false) + "/visitor", "", "", http.StatusNotFound},
		"unknown embed":  {"/v1/embed/e-unknown-embed/visitor", "", "", http.StatusNotFound},
	} {
		if code, raw := embedCall(t, e, tid, http.MethodPost, c.path, c.tok, c.body); code != c.want {
			t.Errorf("%s: %d %s, want %d", name, code, raw, c.want)
		}
	}
	if got := readLines(t, e, tid, embed, a); len(got.Messages) != 1 {
		t.Errorf("refused posts wrote: A reads %+v", got)
	}
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+base+"/messages", nil)
	req.AddCookie(&http.Cookie{Name: "embed", Value: a, HttpOnly: true, Secure: true})
	if resp, err := e.client.Do(req); err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("the token as a cookie: %v %v, want 401", resp.StatusCode, err)
	}

	if code, raw := embedCall(t, e, tid, http.MethodDelete, base+"/visitor", a, ""); code != http.StatusNoContent {
		t.Fatalf("erase: %d %s", code, raw)
	}
	if code, _ := embedCall(t, e, tid, http.MethodGet, base+"/messages", a, ""); code != http.StatusUnauthorized {
		t.Errorf("A's token after the erasure: %d, want 401", code)
	}
	if got := readLines(t, e, tid, embed, b); len(got.Messages) != 0 {
		t.Errorf("CONTROL: B after A's erasure reads %+v", got)
	}
}

// TestEmbedVisitorSeesNothingOutsideItsChannel (the T104 done line): the
// visitor's token, on the production view door, opens no channel list, no
// people list, no member list, no docs and no search, one check each; nor
// does its HUM id used as a member session (the lde door's test seam: its
// role channel_guest holds no permission, not even topics.read). CONTROL: an
// admin of the same workspace reads each of them on that same door, so
// every refusal is the visitor's. (The lde door, off, reads anonymously by
// design; config refuses it outside lde.)
func TestEmbedVisitorSeesNothingOutsideItsChannel(t *testing.T) {
	e := embedEnv(t, true)
	pg := pgOnly(t, e)
	lde := embedEnv(t, true, hub.ViewDoorOff) // the same database
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, ch := mint(t, e, tid, embed)
	hum := visitorHuman(t, pg, tid, ch)
	adm := seat(t, e, tid, rbac.Admin)
	if code, raw := wsDoc(t, lde, tid, http.MethodPut, "sales.md", adm, "", "# price list"); code >= 300 {
		t.Fatalf("seed doc: %d %s", code, raw)
	}
	for name, path := range map[string]string{
		"channel list": "/v1/view/channels",
		"people list":  "/v1/view/roster",
		"member list":  "/v1/members",
		"docs":         "/v1/workspace/docs/sales.md",
		"search":       "/v1/view/search?q=price",
	} {
		if code, raw := embedCall(t, e, tid, http.MethodGet, path, tok, ""); code != http.StatusUnauthorized && code != http.StatusForbidden {
			t.Errorf("%s with the visitor token: %d %.200s, want 401/403", name, code, raw)
		}
		if code, raw := call(t, lde, tid, http.MethodGet, path, hum, nil); code != http.StatusUnauthorized && code != http.StatusForbidden {
			t.Errorf("%s as the visitor's HUM: %d %.200v, want 401/403", name, code, raw)
		}
		if code, raw := call(t, lde, tid, http.MethodGet, path, adm, nil); code != http.StatusOK {
			t.Errorf("CONTROL: %s as an admin: %d %.200v", name, code, raw)
		}
	}
	code, members := call(t, lde, tid, http.MethodGet, "/v1/members", adm, nil)
	if raw, _ := json.Marshal(members); code != http.StatusOK || strings.Contains(string(raw), hum) {
		t.Errorf("the staff member list names the visitor %s: %s", hum, raw)
	}
}

// visitorHuman is the HUM of the visitor that owns channel ch.
func visitorHuman(t *testing.T, pg *store.Postgres, tid, ch string) string {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var hum string
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT human_id FROM embed_visitors WHERE tenant_id = $1 AND channel_id = $2`, tid, ch).Scan(&hum); err != nil {
		t.Fatal(err)
	}
	return hum
}
