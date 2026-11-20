package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/topicpdf"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 183 row P1: GET /v1/topics/{task_id}/export.pdf hands a box the
// topic as its bound operator (rdb 0040) reads it in the browser. The topic
// door (canReadTopic) and the per-message door (canReadMessage) both apply;
// a topic the operator may not read answers as a missing one. The renderer
// (row P2's topicpdf.Renderer) is stubbed: its "PDF" is the HTML topicpdf
// built, whose cards carry data-msg-id.
// RED control (run by hand, recorded in the commit): skip the per-row
// canReadMessage in topicExportRows and TestTopicExportOperatorReadsChannel
// sees the DM.

const stubPDFHead = "%PDF-stub\n"

// stubRender is the stub renderer; render swaps its behaviour per test.
type stubRender struct {
	render func(ctx context.Context, html []byte) ([]byte, error)
}

// cardID is a card's msg id in topicpdf's HTML.
var cardID = regexp.MustCompile(`data-msg-id="([^"]+)"`)

func (r *stubRender) Render(ctx context.Context, html []byte) ([]byte, error) {
	return r.render(ctx, html)
}

type topicExportRig struct {
	e                  *env
	tid                string
	op, peer, outsider string // op operates box-b and box-d; peer box-d; outsider nothing
	open, secret       string // topics in #devel (op is in) and #secret (op is not)
	want               []string
	foreignDM          string
	tokens             map[string]string // box id -> upload token
	r                  *stubRender
}

func topicExportEnv(t *testing.T, withRenderer bool) topicExportRig {
	t.Helper()
	g := topicExportRig{tokens: map[string]string{}, r: &stubRender{}}
	g.r.render = func(_ context.Context, html []byte) ([]byte, error) { return append([]byte(stubPDFHead), html...), nil }
	g.e = newEnv(t, func(o *hub.Options) {
		if withRenderer {
			o.TopicPDF = g.r
		}
	})
	e := g.e
	g.tid, _ = e.tenant()
	tid := g.tid
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	for _, b := range []*box{e.box(tid, "box-b", "CLE-08"), e.box(tid, "box-c", "CLE-09"), e.box(tid, "box-d", "CLE-10")} {
		e.pin(tid, b)
		g.tokens[b.id] = e.uploadToken(tid, b)
	}
	g.op, g.peer, g.outsider = g.admit(t, "op-", now), g.admit(t, "peer-", now), g.admit(t, "out-", now)
	ops := e.st.(store.BoxOperators)
	for _, bind := range [][2]string{{"box-b", g.op}, {"box-d", g.op}, {"box-d", g.peer}} {
		if err := ops.GrantBoxOperator(ctx, tid, bind[0], bind[1], "operator", now); err != nil {
			t.Fatal(err)
		}
	}
	for ch, hums := range map[string][]string{"devel": {g.op, g.peer, g.outsider}, "secret": {g.peer}} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: g.peer, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, hums, g.peer, now); err != nil {
			t.Fatal(err)
		}
	}
	g.open, g.secret = uuidV4(), uuidV4()
	second := g.put(t, g.open, "devel", "c-004", "ALL-0", now.Add(time.Second), g.peer) // typed at c-004's terminal
	g.foreignDM = g.put(t, g.open, "", g.peer, g.outsider, now.Add(2*time.Second))      // a DM op is no end of
	ownDM := g.put(t, g.open, "", g.peer, g.op, now.Add(3*time.Second))                 // a DM op is an end of
	first := g.put(t, g.open, "devel", g.peer, "ALL-0", now)                            // inserted last, oldest by ts
	g.want = []string{first, second, ownDM}
	g.put(t, g.secret, "secret", g.peer, "ALL-0", now)
	return g
}

// admit makes a member of the rig's tenant and returns its HUM id.
func (g topicExportRig) admit(t *testing.T, sub string, now time.Time) string {
	t.Helper()
	ctx, h := context.Background(), g.e.st.(store.Humans)
	mail := sub + g.tid + "@example.com"
	if err := h.PutInvite(ctx, store.Invite{TenantID: g.tid, Email: mail, Role: "developer", InvitedBy: "operator",
		ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	id, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: sub + g.tid, Email: mail},
		g.tid, store.AdmitPolicy{BootstrapOwner: true}, now)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// put stores one row of task, typed by typedBy[0] when given, with one
// non-picture attachment, and returns its msg id.
func (g topicExportRig) put(t *testing.T, task, channel, from, to string, at time.Time, typedBy ...string) string {
	t.Helper()
	id := uuidV4()
	m := store.Message{TenantID: g.tid, MsgID: id, TaskID: task, Channel: channel, IsParent: 1,
		TS: at, FromBox: hub.WUIBox, FromID: from, ToBox: "box-b", ToID: to, Kind: "note", Body: "row " + id,
		Files: []byte(`[]`), Msg: []byte(`{"v":1,"files":[{"name":"notes.txt"}]}`), Env: []byte(`{"id":"` + id + `"}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if len(typedBy) > 0 {
		m.TypedBy = typedBy[0]
	}
	if _, err := g.e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return id
}

// exportAnswer is one answer of the route: the status, the error token ("" on
// 200), the msg ids of the cards the stub PDF holds, its HTML, and the
// headers.
type exportAnswer struct {
	status int
	token  string
	ids    []string
	html   string
	header http.Header
}

func (g topicExportRig) export(t *testing.T, token, task, typedBy string) exportAnswer {
	t.Helper()
	u := g.e.url(g.tid) + "/v1/topics/" + task + "/export.pdf"
	if typedBy != "" {
		u += "?typed_by=" + url.QueryEscape(typedBy)
	}
	req, _ := http.NewRequest(http.MethodGet, u, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := g.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	a := exportAnswer{status: resp.StatusCode, header: resp.Header}
	if resp.StatusCode != http.StatusOK {
		var eb wire.ErrorBody
		json.Unmarshal(raw, &eb) //nolint:errcheck
		a.token = eb.Error
		return a
	}
	body, ok := strings.CutPrefix(string(raw), stubPDFHead)
	if !ok {
		t.Fatalf("200 body is not the stub PDF: %.80q", raw)
	}
	a.html = body
	for _, m := range cardID.FindAllStringSubmatch(body, -1) {
		a.ids = append(a.ids, m[1])
	}
	return a
}

func TestTopicExportOperatorReadsChannel(t *testing.T) {
	g := topicExportEnv(t, true)
	a := g.export(t, g.tokens["box-b"], g.open, "")
	if a.status != http.StatusOK {
		t.Fatalf("export: %d %s", a.status, a.token)
	}
	if strings.Join(a.ids, ",") != strings.Join(g.want, ",") {
		t.Fatalf("rows %v, want %v oldest first, without the DM %s", a.ids, g.want, g.foreignDM)
	}
	h := a.header
	if h.Get("Content-Type") != "application/pdf" || h.Get("X-Spool-Rows") != "3" || h.Get("X-Spool-Pictures") != "0" {
		t.Fatalf("headers %v", h)
	}
	cd := h.Get("Content-Disposition")
	slug := topicpdf.Slug("row " + g.want[0]) // the title is the oldest row's body
	if !strings.HasPrefix(cd, `attachment; filename="`+slug+`-`+strings.ReplaceAll(g.open, "-", "")[:8]+`-`) || !strings.HasSuffix(cd, `Z.pdf"`) {
		t.Fatalf("Content-Disposition %q, want %s-<task8>-<UTC>.pdf", cd, slug)
	}
	if !regexp.MustCompile(`notes\.txt <a href="https://[^"/]+/t/` + g.open + `"`).MatchString(a.html) {
		t.Fatalf("no topic link https://<tenant WUI>/t/%s after the attachment (7.1.5 WithTopicLink):\n%s", g.open, a.html)
	}
	if via := `<strong>` + g.peer + `</strong> <span class="msg-print__via">via terminal c-004</span>`; !strings.Contains(a.html, via) {
		t.Fatalf("the typed row's card lacks %q (7.1.3 TypedBy):\n%s", via, a.html)
	}
}

func TestTopicExportRefusals(t *testing.T) {
	g := topicExportEnv(t, true)
	b, c, d := g.tokens["box-b"], g.tokens["box-c"], g.tokens["box-d"]
	cases := []struct {
		label, token, task, typedBy string
		status                      int
		want                        string
	}{
		{"operator outside the channel", b, g.secret, "", 404, "not_found"},
		{"missing topic", b, uuidV4(), "", 404, "not_found"},
		{"not a uuid", b, "nope", "", 404, "not_found"},
		{"box with no operator", c, g.open, "", 404, "not_found"},
		{"several operators, none named", d, g.open, "", 400, hub.CodeOperatorAmbiguous},
		{"typed_by a member not bound to the box", b, g.open, g.outsider, 403, hub.CodeTypedByNotBound},
		{"typed_by bound to another box only", b, g.open, g.peer, 403, hub.CodeTypedByNotBound},
		{"typed_by not a HUM id", b, g.open, "CLE-08", 403, hub.CodeTypedByNotBound},
		{"no bearer", "", g.open, "", 401, "door"},
		{"unknown bearer", "nope", g.open, "", 401, "door"},
	}
	for _, k := range cases {
		if a := g.export(t, k.token, k.task, k.typedBy); a.status != k.status || a.token != k.want {
			t.Errorf("%s: %d %q, want %d %q", k.label, a.status, a.token, k.status, k.want)
		}
	}
	// CONTROL: the ambiguous box reads once it names a bound operator, and
	// as the peer (in #secret) it reads #secret.
	if a := g.export(t, d, g.open, g.op); a.status != 200 || len(a.ids) != len(g.want) {
		t.Fatalf("box-d typed_by op: %d %q rows %v, want %d rows", a.status, a.token, a.ids, len(g.want))
	}
	if a := g.export(t, d, g.secret, g.peer); a.status != 200 || len(a.ids) != 1 {
		t.Fatalf("box-d as the peer on #secret: %d %q rows %v, want 1 row", a.status, a.token, a.ids)
	}
}

// The browser's upload token is no principal on the export (WUIBox): it gets
// the door before any topic is looked up.
func TestTopicExportRefusesBrowserToken(t *testing.T) {
	r := &stubRender{render: func(context.Context, []byte) ([]byte, error) { return []byte(stubPDFHead), nil }}
	g := topicExportRig{r: r}
	g.e = newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.TopicPDF = r
	})
	g.tid, _ = g.e.tenant()
	browser := dialWUI(t, g.e, g.tid, "HUM-2").w.UploadToken
	if a := g.export(t, browser, uuidV4(), ""); a.status != 401 || a.token != "door" {
		t.Fatalf("the browser's token: %d %q, want 401 door", a.status, a.token)
	}
	// CONTROL: a box token on the same hub passes the door to the topic lookup.
	b := g.e.box(g.tid, "box-b", "CLE-08")
	g.e.pin(g.tid, b)
	if a := g.export(t, g.e.uploadToken(g.tid, b), uuidV4(), ""); a.status != 404 || a.token != "not_found" {
		t.Fatalf("a box token: %d %q, want 404 not_found", a.status, a.token)
	}
}

// specs/077 T016: in the demo workspace a moderator-hidden message is not
// exported for a non-moderator operator, as the browser drops it
// (messageHidden); the moderator's box still exports it.
func TestTopicExportDropsModeratorHidden(t *testing.T) {
	r := &stubRender{render: func(_ context.Context, html []byte) ([]byte, error) { return append([]byte(stubPDFHead), html...), nil }}
	e, demo := quotaEnv(t, func(o *hub.Options) { o.TopicPDF = r })
	g := topicExportRig{e: e, tid: demo, r: r}
	m := &modRig{e: e, demo: demo, admin: seat(t, e, demo, rbac.Admin), dev: seat(t, e, demo, rbac.Developer)}
	m.devSock = dialMember(t, e, demo, "", m.dev)
	task, open, reply := uuidV4(), uuidV4(), uuidV4()
	m.post(t, open, task, "opening line", 1)
	m.post(t, reply, task, "a reply to hide", 0)
	if code, _ := call(t, e, demo, http.MethodPut, "/v1/messages/"+reply+"/hidden", m.admin, nil); code != http.StatusOK {
		t.Fatalf("hide the reply: %d", code)
	}
	ops, now := e.st.(store.BoxOperators), time.Now().UTC()
	tokens := map[string]string{}
	for _, bind := range [][3]string{{"box-b", "CLE-08", m.dev}, {"box-c", "CLE-09", m.admin}} {
		b := e.box(demo, bind[0], bind[1])
		e.pin(demo, b)
		if err := ops.GrantBoxOperator(context.Background(), demo, bind[0], bind[2], "operator", now); err != nil {
			t.Fatal(err)
		}
		tokens[bind[0]] = e.uploadToken(demo, b)
	}
	if a := g.export(t, tokens["box-b"], task, ""); a.status != 200 || !slices.Equal(a.ids, []string{open}) {
		t.Fatalf("the developer's box: %d %q rows %v, want [%s] (the hidden reply left out)", a.status, a.token, a.ids, open)
	}
	// CONTROL: the moderator reads the hidden reply, so its box exports both.
	// Both rows share a second, so the store's tie-break orders them.
	if a := g.export(t, tokens["box-c"], task, ""); a.status != 200 || len(a.ids) != 2 || !slices.Contains(a.ids, open) || !slices.Contains(a.ids, reply) {
		t.Fatalf("the moderator's box: %d %q rows %v, want %s and %s", a.status, a.token, a.ids, open, reply)
	}
}

func TestTopicExportRendererFailures(t *testing.T) {
	g := topicExportEnv(t, true)
	b := g.tokens["box-b"]
	cases := []struct {
		label  string
		render func(ctx context.Context, html []byte) ([]byte, error)
		status int
		want   string
	}{
		{"busy", func(context.Context, []byte) ([]byte, error) { return nil, topicpdf.ErrBusy }, 503, "render_unavailable"},
		{"down", func(context.Context, []byte) ([]byte, error) { return nil, errors.New("dial: refused") }, 503, "render_unavailable"},
		{"past the timeout", func(context.Context, []byte) ([]byte, error) { return nil, topicpdf.ErrTimeout }, 504, "render_timeout"},
		{"too large", func(context.Context, []byte) ([]byte, error) { return nil, topicpdf.ErrTooLarge }, 413, "too_large"},
	}
	for _, k := range cases {
		g.r.render = k.render
		if a := g.export(t, b, g.open, ""); a.status != k.status || a.token != k.want {
			t.Errorf("%s: %d %q, want %d %q", k.label, a.status, a.token, k.status, k.want)
		}
	}
	// CONTROL: a hub with no renderer wired answers 503 once the door passed.
	n := topicExportEnv(t, false)
	if a := n.export(t, n.tokens["box-b"], n.open, ""); a.status != 503 || a.token != "render_unavailable" {
		t.Fatalf("no renderer: %d %q, want 503 render_unavailable", a.status, a.token)
	}
}
