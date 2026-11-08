package action

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r53-09: a verb's hub path and its refusals. React's add, remove and list
// through the fake hub, askBody's category op, HubTail on a dead hub.

const (
	rhEmoji = "thumbsup"
	rhTask  = "abcdef11-2222-4333-8444-555555555555"
	rhMsg   = "abcdef22-3333-4444-8555-666666666666"
)

// rhDecode is the JSON object raw holds.
func rhDecode(t *testing.T, raw json.RawMessage) map[string]string {
	t.Helper()
	var m map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	return m
}

// rhDeadURL is a hub URL nothing listens on any more.
func rhDeadURL() string {
	srv := httptest.NewServer(http.NotFoundHandler())
	defer srv.Close()
	return srv.URL
}

func TestReactHub(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	cases := []struct {
		name           string
		in             ReactArgs
		task, msg, wOp string
		emoji          string
	}{
		{"add", ReactArgs{TaskID: askID, Emoji: rhEmoji, As: "CLE-1"}, askID, "", "add", rhEmoji},
		{"remove", ReactArgs{TaskID: askID, Emoji: rhEmoji, As: "CLE-1", Remove: true}, askID, "", "remove", rhEmoji},
		{"list writes no emoji", ReactArgs{TaskID: askID, As: "CLE-1", List: true}, askID, "", "list", ""},
		{"msg target", ReactArgs{MsgID: rhMsg, Emoji: rhEmoji, As: "CLE-1"}, "", rhMsg, "add", rhEmoji},
		{"ids are lowered", ReactArgs{TaskID: strings.ToUpper(rhTask), MsgID: strings.ToUpper(rhMsg), Emoji: rhEmoji, As: "CLE-1"}, rhTask, rhMsg, "add", rhEmoji},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			raw, err := React(context.Background(), cfg, c.in)
			if err != nil {
				t.Fatal(err)
			}
			f := h.last(t)
			if f.Type != wire.TReact || f.TaskID != c.task || f.ReactMsg != c.msg || f.ReactOp != c.wOp || f.Emoji != c.emoji || f.As != "CLE-1" {
				t.Fatalf("frame %+v", f)
			}
			got := rhDecode(t, raw)
			if got["op"] != c.wOp || got["emoji"] != c.emoji || got["task_id"] != c.task {
				t.Fatalf("hub answer came back as %v", got)
			}
		})
	}
}

// The injected client reaches the hub; cfg alone would dial a dead one.
func TestReactHubInjectedClient(t *testing.T) {
	h := newVerbHub(t)
	dead := hubCfg(t, h)
	dead.HubURL = rhDeadURL()
	raw, err := React(context.Background(), dead, ReactArgs{TaskID: askID, Emoji: rhEmoji, As: "CLE-1", Hub: hubclient.New(hubCfg(t, h))})
	if err != nil {
		t.Fatal(err)
	}
	if f := h.last(t); f.Type != wire.TReact || f.TaskID != askID || f.ReactOp != "add" {
		t.Fatalf("frame %+v", f)
	}
	if got := rhDecode(t, raw); got["op"] != "add" {
		t.Fatalf("hub answer came back as %v", got)
	}
}

func TestReactHubRefused(t *testing.T) {
	h := newVerbHub(t)
	raw, err := React(context.Background(), hubCfg(t, h), ReactArgs{TaskID: refuseTask, Emoji: rhEmoji, As: "CLE-1"})
	if err == nil || !strings.Contains(err.Error(), "hub refused: not_found") {
		t.Fatalf("answer %s, err %v: want the hub's refusal", raw, err)
	}
}

func TestAskBodyCategory(t *testing.T) {
	good := AskArgs{Op: "category", By: "CLE-1@box-a", AskID: askID, WorkKind: "tests", CategoryPath: "hub/tests"}
	refused := []struct {
		name string
		edit func(*AskArgs)
		want string
	}{
		{"no by", func(a *AskArgs) { a.By = "" }, "needs --by"},
		{"bad by", func(a *AskArgs) { a.By = "no spaces allowed" }, "needs --by"},
		{"bad id", func(a *AskArgs) { a.AskID = "NOT-A-UUID" }, "--id must be"},
		{"bad work kind", func(a *AskArgs) { a.WorkKind = "nope" }, "work_kind must be one of"},
		{"bad path", func(a *AskArgs) { a.CategoryPath = "Bad/Path" }, "category_path must be"},
	}
	for _, c := range refused {
		t.Run(c.name, func(t *testing.T) {
			in := good
			c.edit(&in)
			if raw, err := askBody(in); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("body %s, err %v: want %q", raw, err, c.want)
			}
		})
	}
	raw, err := askBody(good)
	if err != nil {
		t.Fatal(err)
	}
	got := rhDecode(t, raw)
	if got["ask_id"] != askID || got["by"] != good.By || got["work_kind"] != good.WorkKind || got["category_path"] != good.CategoryPath {
		t.Fatalf("body %v", got)
	}
}

func TestHubTailUnreachable(t *testing.T) {
	cfg := hubCfg(t, newVerbHub(t))
	cfg.HubURL = rhDeadURL()
	rows, err := HubTail(context.Background(), cfg, askID)
	if err == nil || !strings.Contains(err.Error(), "hub unreachable") || rows != nil {
		t.Fatalf("rows %v, err %v: want hub unreachable and no rows", rows, err)
	}
}
