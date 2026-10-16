package action

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

const linkTask = "e055195c-0bde-4ed5-940b-5ead053e95f2"
const linkMsg = "3cb9ab21-24e9-47f5-8867-d9ddf31f4eda"

// SPL-2112: every link form the WUI emits names its topic (and workspace
// label); junk is refused with what a link looks like.
func TestParseLinkForms(t *testing.T) {
	for _, c := range []struct{ in, label, task, msgID, form string }{
		{"https://csitea.example.net/t/" + linkTask, "csitea", linkTask, "", "t"},
		{"https://csitea.example.net/t/" + strings.ToUpper(linkTask) + "#" + linkMsg, "csitea", linkTask, linkMsg, "t"},
		{"https://csitea.example.net/fi/t/" + linkTask, "csitea", linkTask, "", "t"},
		{"https://csitea.example.net/pt-br/t/" + linkTask + "/", "csitea", linkTask, "", "t"},
		{"https://csitea.example.net/m/" + linkMsg, "csitea", linkMsg, linkMsg, "m"},
		{"https://csitea.example.net/channel/spool-hub?topic=" + linkTask, "csitea", linkTask, "", "query"},
		{"https://csitea.example.net/fi/channel/spool-hub?topic=" + linkTask + "&thread=x", "csitea", linkTask, "", "query"},
		{"https://csitea.example.net/?topic=" + linkTask, "csitea", linkTask, "", "query"},
		{"https://csitea.example.net/dm/c-001@desk-a?topic=" + linkTask, "csitea", linkTask, "", "query"},
		{"https://example.net/t/" + linkTask, "", linkTask, "", "t"}, // the apex: no workspace label
		{"http://localhost:3000/t/" + linkTask, "", linkTask, "", "t"},
		{"  " + linkTask + "\n", "", linkTask, "", "id"},
	} {
		l, err := ParseLink(c.in)
		if err != nil {
			t.Errorf("%q: %v", c.in, err)
			continue
		}
		if l.Label != c.label || l.TaskID != c.task || l.MsgID != c.msgID || l.Form != c.form {
			t.Errorf("%q: got %+v, want label %q task %q msg %q form %q", c.in, l, c.label, c.task, c.msgID, c.form)
		}
	}
	for _, junk := range []string{
		"", "hello", "ftp://csitea.example.net/t/" + linkTask, "https:///t/" + linkTask,
		"https://csitea.example.net/t/not-a-uuid", "https://csitea.example.net/channel/spool-hub",
		"https://csitea.example.net/x/y/t/" + linkTask, "https://csitea.example.net/?topic=12",
		"/t/" + linkTask,
	} {
		if _, err := ParseLink(junk); err == nil {
			t.Errorf("%q: parsed, want a refusal", junk)
		}
	}
}

// fakeDesks lays out <dir>/<tenant>/<box>/spool/.hub/hub-run.pid for each
// tenant with a fake /proc entry of a live hub-run carrying that desk's
// settings; dead tenants get a pid whose process is not hub-run.
func fakeDesks(t *testing.T, box string, live, dead []string) Desks {
	t.Helper()
	root := t.TempDir()
	d := Desks{Dir: filepath.Join(root, "desk"), Box: box, ProcRoot: filepath.Join(root, "proc")}
	pid := 100
	mk := func(tenant, cmdline string) {
		pid++
		spool := filepath.Join(d.Dir, tenant, box, "spool")
		must(t, os.MkdirAll(filepath.Join(spool, ".hub"), 0o755))
		must(t, os.WriteFile(filepath.Join(spool, ".hub", "hub-run.pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644))
		p := filepath.Join(d.ProcRoot, strconv.Itoa(pid))
		must(t, os.MkdirAll(p, 0o755))
		must(t, os.WriteFile(filepath.Join(p, "cmdline"), []byte(cmdline), 0o644))
		env := strings.Join([]string{"SPOOL_ROOT=" + spool, "SPOOL_KEYS_DIR=" + filepath.Join(d.Dir, tenant, box, "keys"),
			"SPOOL_BOX_ID=" + box, "SPOOL_HUB_URL=https://api.example.net", "SPOOL_TENANT=" + tenant, "HOME=/nowhere"}, "\x00")
		must(t, os.WriteFile(filepath.Join(p, "environ"), []byte(env+"\x00"), 0o644))
	}
	for _, tn := range live {
		mk(tn, "/x/spool\x00hub-run\x00")
	}
	for _, tn := range dead {
		mk(tn, "/usr/bin/sleep\x00100\x00")
	}
	return d
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// rowsOf is a hub tail of the topic as only workspace has it: a human post
// and an agent answer.
func rowsOf(workspace string, tried *[]string) func(context.Context, *config.Config, string) ([]TailRow, error) {
	return func(_ context.Context, cfg *config.Config, task string) ([]TailRow, error) {
		*tried = append(*tried, cfg.Tenant)
		if cfg.Tenant != workspace || task != linkTask {
			return nil, nil
		}
		return []TailRow{
			{Msg: &msg.Message{V: 1, MsgID: linkMsg, TaskID: task, From: "HUM-10", To: "c-001", Kind: "msg", Body: "hello", TS: "2026-10-16T05:41:58Z"}, FromBox: "box-wui", ToBox: cfg.BoxID},
			{Msg: &msg.Message{V: 1, MsgID: "11111111-2222-4333-8444-555555555555", TaskID: task, From: "c-550", To: "HUM-10", Kind: "msg", Body: "answer", TS: "2026-10-16T05:43:23Z"}, FromBox: cfg.BoxID, ToBox: "box-wui"},
		}, nil
	}
}

// The workspace comes from the link: its desk is asked first, and a box
// seated in several workspaces (gate 2, exit 5 before) reads it.
func TestReadLinkThroughTheLinksWorkspace(t *testing.T) {
	d := fakeDesks(t, "desk-a", []string{"aaa", "csitea", "t1"}, nil)
	var tried []string
	d.Tail = rowsOf("csitea", &tried)
	out, err := ReadLink(context.Background(), d, "c-700", "https://csitea.example.net/t/"+linkTask, false)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(tried, ",") != "csitea" {
		t.Errorf("desks asked %v, want the link's workspace first (and only)", tried)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != 3 || !strings.HasPrefix(lines[0], "topic "+linkTask+" in workspace csitea, read through desk desk-a: 2 message(s)") {
		t.Fatalf("got %q", out)
	}
	if !strings.Contains(lines[1], "HUM-10@box-wui -> c-001@desk-a  [msg]  hello") || !strings.Contains(lines[1], linkMsg) {
		t.Errorf("line 1 %q", lines[1])
	}
	js, err := ReadLink(context.Background(), d, "c-700", "https://csitea.example.net/t/"+linkTask, true)
	if err != nil || strings.Count(js, "\n") != 2 || !strings.HasPrefix(js, `{"`) {
		t.Errorf("json read: %v %q", err, js)
	}
	// the apex host names no workspace: every live desk in turn, by name
	tried = nil
	if _, err := ReadLink(context.Background(), d, "c-700", "https://example.net/t/"+linkTask, false); err != nil {
		t.Fatal(err)
	}
	if strings.Join(tried, ",") != "aaa,csitea" {
		t.Errorf("apex link asked %v, want aaa,csitea", tried)
	}
}

// Red control of the gate: a topic no desk on the box can see is refused
// with row A's reason, naming the desks asked and what would grant it;
// a dead sidecar's desk is never asked.
func TestReadLinkNotVisibleSaysWhy(t *testing.T) {
	d := fakeDesks(t, "desk-a", []string{"t1"}, []string{"csitea"})
	var tried []string
	d.Tail = rowsOf("csitea", &tried)
	_, err := ReadLink(context.Background(), d, "c-700", "https://csitea.example.net/t/"+linkTask, false)
	if err == nil {
		t.Fatal("read a topic no live desk can see")
	}
	for _, want := range []string{"no messages visible to c-700 in workspace t1", "a seat in csitea: ask the orchestrator"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q lacks %q", err, want)
		}
	}
	if strings.Join(tried, ",") != "t1" {
		t.Errorf("asked %v, want only the live t1 desk", tried)
	}
	empty := Desks{Dir: filepath.Join(t.TempDir(), "none"), Box: "desk-a"}
	if _, err := ReadLink(context.Background(), empty, "", linkTask, false); err == nil || !strings.Contains(err.Error(), "no live hub desk") {
		t.Errorf("no desks: %v", err)
	}
	local := Desks{Base: testkit.NewConfig(t)}
	if _, err := ReadLink(context.Background(), local, "", linkTask, false); err == nil || !strings.Contains(err.Error(), "not in hub mode") {
		t.Errorf("local mode: %v", err)
	}
	if _, err := ReadLink(context.Background(), local, "", "nope", false); err == nil || !strings.Contains(err.Error(), "not a discussion link") {
		t.Errorf("junk link: %v", err)
	}
}

// One desk that errors is reported as that error, not as "not visible".
func TestReadLinkOneDeskErrorIsReported(t *testing.T) {
	d := fakeDesks(t, "desk-a", []string{"csitea"}, nil)
	d.Tail = func(context.Context, *config.Config, string) ([]TailRow, error) {
		return nil, errors.New("hub unreachable")
	}
	if _, err := ReadLink(context.Background(), d, "", "https://csitea.example.net/t/"+linkTask, false); err == nil ||
		!strings.Contains(err.Error(), "desk desk-a in csitea: hub unreachable") {
		t.Errorf("got %v", err)
	}
}

// A reply seats its agent on the link's desk first (gate 3: the call is the
// request), then posts into the same topic as that agent, to the topic's
// newest human on box-wui.
func TestReplyLinkSeatsThenPosts(t *testing.T) {
	d := fakeDesks(t, "desk-a", []string{"csitea", "t1"}, nil)
	var tried []string
	d.Tail = rowsOf("csitea", &tried)
	var seated []string
	d.Seat = func(_ context.Context, tenant, agent string) error {
		seated = append(seated, tenant+"/"+agent)
		return os.MkdirAll(filepath.Join(d.Dir, tenant, "desk-a", "spool", agent, "inbox"), 0o755)
	}
	var sent []SendArgs
	d.Send = func(_ context.Context, cfg *config.Config, in SendArgs) (SendResult, error) {
		if cfg.Tenant != "csitea" || cfg.BoxID != "desk-a" {
			t.Errorf("sent through %s/%s, want csitea/desk-a", cfg.Tenant, cfg.BoxID)
		}
		sent = append(sent, in)
		return SendResult{Delivery: "sent", TaskID: in.TaskID}, nil
	}
	link := "https://csitea.example.net/channel/spool-hub?topic=" + linkTask
	for i := 0; i < 2; i++ {
		if _, err := ReplyLink(context.Background(), d, ReplyArgs{Seat: "c-700", URL: link, Body: "test reply"}); err != nil {
			t.Fatal(err)
		}
	}
	if strings.Join(seated, ",") != "csitea/c-700" {
		t.Errorf("seated %v, want csitea/c-700 once", seated)
	}
	want := SendArgs{From: "c-700", To: "HUM-10", ToBox: "box-wui", TaskID: linkTask, Kind: "msg", Body: "test reply"}
	if len(sent) != 2 || sent[0].From != want.From || sent[0].To != want.To || sent[0].ToBox != want.ToBox ||
		sent[0].TaskID != want.TaskID || sent[0].Kind != want.Kind || sent[0].Body != want.Body {
		t.Errorf("sent %+v, want %+v", sent, want)
	}
}

func TestReplyLinkRefusals(t *testing.T) {
	d := fakeDesks(t, "desk-a", []string{"csitea"}, nil)
	var tried []string
	d.Tail = rowsOf("csitea", &tried)
	link := "https://csitea.example.net/t/" + linkTask
	for _, c := range []struct {
		in   ReplyArgs
		want string
	}{
		{ReplyArgs{URL: link, Body: "x"}, "needs a seated server"},
		{ReplyArgs{Seat: "c-700", URL: link, Body: " "}, "body is required"},
		{ReplyArgs{Seat: "c-700", URL: "nope", Body: "x"}, "not a discussion link"},
		{ReplyArgs{Seat: "c-700", URL: "https://csitea.example.net/t/" + refuseTask, Body: "x"}, "no messages visible to c-700"},
		{ReplyArgs{Seat: "c-700", URL: link, Body: "x"}, "c-700 has no seat on desk desk-a in workspace csitea and this server seats nobody"},
	} {
		if _, err := ReplyLink(context.Background(), d, c.in); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%+v: got %v, want %q", c.in, err, c.want)
		}
	}
	d.Seat = func(context.Context, string, string) error { return errors.New("desk up failed") }
	if _, err := ReplyLink(context.Background(), d, ReplyArgs{Seat: "c-700", URL: link, Body: "x"}); err == nil ||
		!strings.Contains(err.Error(), "seat c-700 on desk desk-a in workspace csitea: desk up failed") {
		t.Errorf("seat failure: %v", err)
	}
}

// A topic with no human post is answered to its first other sender.
func TestReplyTargetWithoutAHuman(t *testing.T) {
	rows := []TailRow{
		{Msg: &msg.Message{From: "c-700", To: "c-001"}, FromBox: "desk-a", ToBox: "sat"},
		{Msg: &msg.Message{From: "c-001", To: "c-700"}, FromBox: "sat", ToBox: "desk-a"},
	}
	if to, box := replyTarget(rows, "c-700"); to != "c-001" || box != "sat" {
		t.Errorf("got %s@%s, want c-001@sat", to, box)
	}
	if to, box := replyTarget(rows[:1], "c-700"); to != "c-001" || box != "sat" {
		t.Errorf("own post only: got %s@%s, want c-001@sat", to, box)
	}
}

// HubTail is a role=cli tail of the box: an empty answer is no rows, a hub
// refusal is its error, and no hub mode is refused before any dial.
func TestHubTail(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	rows, err := HubTail(context.Background(), cfg, linkTask)
	if err != nil || len(rows) != 0 {
		t.Errorf("empty tail: %v %v", rows, err)
	}
	if f := h.last(t); f.TaskID != linkTask {
		t.Errorf("tail frame %+v", f)
	}
	if _, err := HubTail(context.Background(), cfg, refuseTask); err == nil {
		t.Error("a refused tail read no error")
	}
	if _, err := HubTail(context.Background(), testkit.NewConfig(t), linkTask); err == nil || !strings.Contains(err.Error(), "needs hub mode") {
		t.Errorf("local mode: %v", err)
	}
}

// sidecarConfig takes only the spool settings and refuses a partial set.
func TestSidecarConfig(t *testing.T) {
	c, err := sidecarConfig(nil, []byte("SPOOL_ROOT=/r\x00SPOOL_KEYS_DIR=/k\x00SPOOL_BOX_ID=desk-a\x00SPOOL_HUB_URL=https://h\x00SPOOL_PINS_DIR=/p\x00PATH=/bin\x00"))
	if err != nil || c.SpoolRoot != "/r" || c.PinsDir != "/p" || c.BoxID != "desk-a" || c.MsgVersion != 1 {
		t.Errorf("got %+v %v", c, err)
	}
	if _, err := sidecarConfig(nil, []byte("SPOOL_ROOT=/r\x00")); err == nil {
		t.Error("a partial environ was taken")
	}
}
