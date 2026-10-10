package hub_test

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/121 T106: the staff side of the visitor channels (embed_staff.go).

// testClock is a settable hub clock.
type testClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *testClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *testClock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// staffEnv is embedEnv on the lde door (the X-Test-Member seam names the
// staff member) with the hub clock from clk.
func staffEnv(t *testing.T, on bool, clk *testClock) *env {
	t.Helper()
	return rbacEnv(t, func(o *hub.Options) {
		o.EmbedEnabled, o.EmbedTokenLife, o.EmbedMessageMaxBytes = on, embedLife, 4096
		o.Now = clk.now
	})
}

// salesLines is the bodies of tenant's #sales lines, oldest first.
func salesLines(t *testing.T, pg *store.Postgres, tid string) []string {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(ctx, `SELECT body FROM messages WHERE tenant_id = $1 AND channel = $2 ORDER BY received_at, msg_id`,
		tid, store.EmbedSalesChannel)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			t.Fatal(err)
		}
		out = append(out, b)
	}
	return out
}

// staffRaw is call with the raw answer, for byte-equal comparisons.
func staffRaw(t *testing.T, e *env, tid, method, path, as, body string) (int, []byte) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, e.url(tid)+path, rd)
	if as != "" {
		req.Header.Set("X-Test-Member", as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

// TestEmbedStaffRoutesOffAreNotFound: with env.hub.embed.enabled off, every
// staff route answers exactly as a path the hub does not serve, to the
// workspace owner too. CONTROL: with the flag on the owner's list is 200.
func TestEmbedStaffRoutesOffAreNotFound(t *testing.T) {
	clk := &testClock{t: time.Now().UTC()}
	off := staffEnv(t, false, clk)
	tid, _ := off.tenant()
	owner := seat(t, off, tid, rbac.BizOwner)
	unknownCode, unknown := staffRaw(t, off, tid, http.MethodGet, "/v1/no-such-route", owner, "")
	for _, c := range []struct{ method, path, body string }{
		{http.MethodGet, "/v1/tenant/embed-visitors", ""},
		{http.MethodPut, "/v1/tenant/embed-visitors/v-0123456789abcdef/lead", `{"lead":true}`},
		{http.MethodPost, "/v1/tenant/embed-visitors/v-0123456789abcdef/block", ""},
	} {
		code, raw := staffRaw(t, off, tid, c.method, c.path, owner, c.body)
		if code != unknownCode || !bytes.Equal(raw, unknown) {
			t.Errorf("flag off: %s %s = %d %q, want the unknown path's %d %q", c.method, c.path, code, raw, unknownCode, unknown)
		}
	}
	on := staffEnv(t, true, clk)
	pgOnly(t, on)
	tid2, _ := on.tenant()
	if code, raw := call(t, on, tid2, http.MethodGet, "/v1/tenant/embed-visitors", seat(t, on, tid2, rbac.BizOwner), nil); code != http.StatusOK {
		t.Fatalf("CONTROL: flag on, the owner's list = %d %v", code, raw)
	}
}

// TestEmbedTriageLine (spec 4.4): a new visitor channel posts ONE #sales
// line, a link to the channel and never the visitor's text; posts the same
// day add none; the first post after 24 h quiet adds one more, and the next
// post none. The staff (owner, admin) are seated in #sales and in the
// visitor channel; a developer is not. CONTROL: the visitor's text is
// stored in its own channel (so its absence from #sales is the triage's
// doing, not a lost post).
func TestEmbedTriageLine(t *testing.T) {
	clk := &testClock{t: time.Now().UTC()}
	e := staffEnv(t, true, clk)
	pg := pgOnly(t, e)
	tid, _ := e.tenant()
	owner, admin, dev := seat(t, e, tid, rbac.BizOwner), seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	embed := seedEmbed(t, pg, tid, true)
	tok, ch := mint(t, e, tid, embed)
	post := func(body string) {
		t.Helper()
		if code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/messages", tok, solvedPost(t, e, tid, embed, tok, body)); code != http.StatusCreated {
			t.Fatalf("post: %d %s", code, raw)
		}
	}
	lines := salesLines(t, pg, tid)
	if len(lines) != 1 || !strings.Contains(lines[0], "(/channel/"+ch+")") {
		t.Fatalf("after the mint #sales holds %q, want one link to %s", lines, ch)
	}
	post("SECRET-TEXT my budget is 5000")
	post("SECRET-TEXT second line")
	if got := salesLines(t, pg, tid); len(got) != 1 {
		t.Errorf("posts on the mint's day added triage lines: %q", got)
	}
	clk.add(25 * time.Hour)
	post("SECRET-TEXT back tomorrow")
	clk.add(time.Minute)
	post("SECRET-TEXT and once more")
	lines = salesLines(t, pg, tid)
	if len(lines) != 2 || !strings.Contains(lines[1], "(/channel/"+ch+")") {
		t.Errorf("after a quiet day #sales holds %q, want a second link to %s", lines, ch)
	}
	for _, l := range lines {
		if strings.Contains(l, "SECRET-TEXT") {
			t.Errorf("a #sales line carries the visitor's text: %q", l)
		}
	}
	if got := readLines(t, e, tid, embed, tok); len(got.Messages) != 4 || !strings.Contains(got.Messages[0].Body, "SECRET-TEXT") {
		t.Errorf("CONTROL: the visitor's channel holds %+v, want its 4 lines", got)
	}
	for _, c := range []string{store.EmbedSalesChannel, ch} {
		for who, hum := range map[string]string{"owner": owner, "admin": admin} {
			if code, raw := call(t, e, tid, http.MethodGet, "/v1/channels/"+c+"/members", hum, nil); code != http.StatusOK ||
				!strings.Contains(strings.Join(memberIDs(raw), ","), hum) {
				t.Errorf("%s is not seated in %s: %d %v", who, c, code, raw)
			}
		}
		if code, raw := call(t, e, tid, http.MethodGet, "/v1/channels/"+c+"/members", dev, nil); code == http.StatusOK &&
			strings.Contains(strings.Join(memberIDs(raw), ","), dev) {
			t.Errorf("the developer is seated in %s: %v", c, raw)
		}
	}
}

// memberIDs is every human id in a channel members answer.
func memberIDs(raw map[string]any) []string {
	var out []string
	for _, k := range []string{"humans", "members"} {
		list, _ := raw[k].([]any)
		for _, m := range list {
			switch v := m.(type) {
			case string:
				out = append(out, v)
			case map[string]any:
				if id, _ := v["human_id"].(string); id != "" {
					out = append(out, id)
				}
			}
		}
	}
	return out
}

// TestEmbedStaffLeadBlock: an admin marks a visitor channel a lead and the
// owner blocks the visitor; the list shows both; the blocked visitor's
// token is refused at once (401) and its channel stays in the list. A
// developer gets 403 on every staff route; an unknown channel is 404; a
// lead body without "lead" is 400. CONTROL: the token reads its channel
// before the block.
func TestEmbedStaffLeadBlock(t *testing.T) {
	clk := &testClock{t: time.Now().UTC()}
	e := staffEnv(t, true, clk)
	pg := pgOnly(t, e)
	tid, _ := e.tenant()
	owner, admin, dev := seat(t, e, tid, rbac.BizOwner), seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	embed := seedEmbed(t, pg, tid, true)
	tok, ch := mint(t, e, tid, embed)
	base := "/v1/tenant/embed-visitors/"
	readLines(t, e, tid, embed, tok) // CONTROL: live before the block
	for _, c := range []struct {
		method, path, as string
		body             any
		want             int
	}{
		{http.MethodGet, "/v1/tenant/embed-visitors", dev, nil, http.StatusForbidden},
		{http.MethodPut, base + ch + "/lead", dev, map[string]any{"lead": true}, http.StatusForbidden},
		{http.MethodPost, base + ch + "/block", dev, nil, http.StatusForbidden},
		{http.MethodPut, base + ch + "/lead", admin, map[string]any{}, http.StatusBadRequest},
		{http.MethodPut, base + "v-0123456789abcdef/lead", admin, map[string]any{"lead": true}, http.StatusNotFound},
		{http.MethodPost, base + "lobby/block", owner, nil, http.StatusNotFound},
		{http.MethodPut, base + ch + "/lead", admin, map[string]any{"lead": true}, http.StatusNoContent},
		{http.MethodPost, base + ch + "/block", owner, nil, http.StatusNoContent},
	} {
		if code, raw := call(t, e, tid, c.method, c.path, c.as, c.body); code != c.want {
			t.Errorf("%s %s as %s: %d %v, want %d", c.method, c.path, c.as, code, raw, c.want)
		}
	}
	if code, _ := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", tok, ""); code != http.StatusUnauthorized {
		t.Errorf("the blocked visitor's token: %d, want 401", code)
	}
	code, raw := call(t, e, tid, http.MethodGet, "/v1/tenant/embed-visitors", admin, nil)
	list, _ := raw["visitors"].([]any)
	if code != http.StatusOK || len(list) != 1 {
		t.Fatalf("list: %d %v", code, raw)
	}
	row, _ := list[0].(map[string]any)
	if row["channel"] != ch || row["lead"] != true || row["blocked"] != true || row["live"] != false {
		t.Errorf("list row %v, want %s a lead, blocked, not live", row, ch)
	}
	for _, k := range []string{"token", "email", "ip_hash", "visitor_id"} {
		if _, ok := row[k]; ok {
			t.Errorf("the staff list carries %s", k)
		}
	}
}
