package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The client half of hub.go (r7-10): the verbs a box runs against its hub.
// The server half (cmdServe, openStore, the hub-tenant verbs) needs Postgres
// and is not tested here.

// TestHubPinPostsAndRevokes: hub-pin signs with a root key made by
// root-keygen, POSTs the pin, DELETEs it on --revoke and prints the answer.
func TestHubPinPostsAndRevokes(t *testing.T) {
	var mu sync.Mutex
	var calls []string
	h := newScriptHub(t, nil, func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		calls = append(calls, r.Method+" "+r.URL.Path+" "+string(b))
		mu.Unlock()
		if strings.Contains(string(b), "box-busy") {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "pin_conflict"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	cfg := hubCfg(t, h.URL)
	root := filepath.Join(t.TempDir(), "root.key")
	rc, rootPub, errOut := capture(t, "", func() int { return cmdRootKeygen([]string{"--out", root}) })
	if rc != 0 || len(strings.TrimSpace(rootPub)) != 44 {
		t.Fatalf("root-keygen: rc %d %q %q", rc, rootPub, errOut)
	}
	if fi, err := os.Stat(root); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("root key file: %v %v", fi, err)
	}
	if strings.Contains(rootPub, strings.TrimSpace(mustRead(t, root))) {
		t.Fatal("root-keygen printed the private key")
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	pubB64 := base64.StdEncoding.EncodeToString(pub)
	for _, c := range []struct {
		args []string
		rc   int
		out  string
	}{
		{[]string{"--box", "box-b", "--pubkey", pubB64, "--root-key", root}, 0, "{\"ok\":true}\n"},
		{[]string{"--box", "box-b", "--revoke", "--root-key", root}, 0, "{\"ok\":true}\n"},
	} {
		rc, out, errOut := capture(t, "", func() int { return cmdHubPin(cfg, c.args) })
		if rc != c.rc || out != c.out {
			t.Errorf("%v: rc %d %q err %q", c.args, rc, out, errOut)
		}
	}
	mu.Lock()
	got := append([]string(nil), calls...)
	mu.Unlock()
	if len(got) != 2 || !strings.HasPrefix(got[0], "POST /v1/pins ") || !strings.HasPrefix(got[1], "DELETE /v1/pins") ||
		!strings.Contains(got[0], pubB64) || strings.Contains(got[0], strings.TrimSpace(mustRead(t, root))) {
		t.Fatalf("hub saw %q", got)
	}
	// refusals: no box, a hub conflict, a bad flag, and an existing root key
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--pubkey", pubB64, "--root-key", root}, "exactly one of --pubkey / --revoke"},
		{[]string{"--box", "box-busy", "--pubkey", pubB64, "--root-key", root}, "pin_conflict"},
		{[]string{"--nope"}, "flag provided but not defined"},
	} {
		if rc, _, errOut := capture(t, "", func() int { return cmdHubPin(cfg, c.args) }); rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d %q, want a refusal naming %q", c.args, rc, errOut, c.want)
		}
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--out", root}, "exists (use --force"},
		{nil, "--out is required"},
		{[]string{"--x"}, "flag provided but not defined"},
	} {
		if rc, _, errOut := capture(t, "", func() int { return cmdRootKeygen(c.args) }); rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("root-keygen %v: rc %d %q, want 1 naming %q", c.args, rc, errOut, c.want)
		}
	}
	if rc, _, _ := capture(t, "", func() int { return cmdRootKeygen([]string{"--out", root, "--force"}) }); rc != 0 {
		t.Errorf("root-keygen --force: rc %d", rc)
	}
}

// TestHubSyncOneSession: one role=box session against a hub with no pins and
// an empty queue prints the zero report.
func TestHubSyncOneSession(t *testing.T) {
	h := newScriptHub(t, nil, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/pins" || r.Header.Get("Authorization") != "Bearer tok" {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		writeJSON(w, http.StatusOK, wire.PinList{Pins: []wire.PinEntry{}})
	})
	cfg := hubCfg(t, h.URL)
	cfg.FleetRoot = t.TempDir()
	rc, out, errOut := capture(t, "", func() int { return cmdHubSync(cfg) })
	if rc != 0 {
		t.Fatalf("hub-sync: rc %d %q err %q", rc, out, errOut)
	}
	var rep map[string]int
	if err := json.Unmarshal([]byte(out), &rep); err != nil || rep["flushed"] != 0 || rep["pending"] != 0 || rep["refused"] != 0 {
		t.Fatalf("hub-sync report %q (%v)", out, err)
	}
	if hs := h.Hellos(); len(hs) != 1 || hs[0].Role != wire.RoleBox || hs[0].BoxID != "box-a" {
		t.Fatalf("hellos = %+v", hs)
	}
}

// TestBoxClientRefusals: every hub verb refuses local mode, and a bad
// $SPOOL_AGENT_DROP_AFTER, before it dials.
func TestBoxClientRefusals(t *testing.T) {
	local := testkit.NewConfig(t)
	for name, fn := range map[string]func() int{
		"hub-sync":     func() int { return cmdHubSync(local) },
		"hub-tail":     func() int { return cmdHubTail(local, []string{"--task", "t"}) },
		"hub-rsp":      func() int { return cmdHubRSP(local, []string{"--task", "t"}) },
		"hub-get-file": func() int { return cmdHubGetFile(local, []string{"--file-id", "f"}) },
	} {
		if rc, _, errOut := capture(t, "", fn); rc != 1 || !strings.Contains(errOut, "$SPOOL_HUB_URL is not set") {
			t.Errorf("%s in local mode: rc %d %q", name, rc, errOut)
		}
	}
	cfg := hubCfg(t, "http://127.0.0.1:1")
	cfg.AgentDropAfter = "soon"
	if rc, _, errOut := capture(t, "", func() int { return cmdHubSync(cfg) }); rc != 1 || !strings.Contains(errOut, "$SPOOL_AGENT_DROP_AFTER") {
		t.Errorf("bad drop-after: rc %d %q", rc, errOut)
	}
	// the task / file id flags are required, and an unknown flag is refused
	hc := hubCfg(t, "http://127.0.0.1:1")
	for name, fn := range map[string]func() int{
		"hub-tail no task":        func() int { return cmdHubTail(hc, nil) },
		"hub-rsp no task":         func() int { return cmdHubRSP(hc, nil) },
		"hub-get-file no file id": func() int { return cmdHubGetFile(hc, nil) },
		"hub-tail bad flag":       func() int { return cmdHubTail(hc, []string{"--x"}) },
		"hub-rsp bad flag":        func() int { return cmdHubRSP(hc, []string{"--x"}) },
		"hub-get-file bad flag":   func() int { return cmdHubGetFile(hc, []string{"--x"}) },
	} {
		if rc, _, _ := capture(t, "", fn); rc != 1 {
			t.Errorf("%s: rc %d, want 1", name, rc)
		}
	}
}

// tailEnv is one signed envelope of a valid v:1 note in task.
func tailEnv(t *testing.T, task, body string) []byte {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(nil)
	m := &msg.Message{V: 1, MsgID: uid.New(), TaskID: task, TS: "2026-10-11T03:00:00Z",
		From: "c-001", To: "c-002", Kind: "note", Body: body}
	e, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// TestHubTailAndRSP: hub-tail prints one human line per message (or the
// inner v:1 as NDJSON with --json) and skips an envelope whose inner message
// is not valid; hub-rsp prints the count the hub answers.
func TestHubTailAndRSP(t *testing.T) {
	task := uid.New()
	good := tailEnv(t, task, "hello")
	bad, _ := json.Marshal(wire.Envelope{FromBox: "box-a", ToBox: "box-b", Msg: json.RawMessage(`{"v":1}`), Sig: "x"})
	h := newScriptHub(t, func(f wire.Frame) []wire.Frame {
		if f.Type != wire.TTail {
			return nil
		}
		if f.TaskID == "refused" {
			return []wire.Frame{{Type: wire.TError, Error: "not_found", Status: 404}}
		}
		if f.RSPCount {
			return []wire.Frame{{Type: wire.TTailEnd, TaskID: f.TaskID, RSPCount: true, Count: 3}}
		}
		return []wire.Frame{{Type: wire.TTailMsg, Env: good}, {Type: wire.TTailMsg, Env: bad}, {Type: wire.TTailEnd, TaskID: f.TaskID}}
	}, nil)
	cfg := hubCfg(t, h.URL)
	rc, out, errOut := capture(t, "", func() int { return cmdHubTail(cfg, []string{"--task", task}) })
	if want := "2026-10-11T03:00:00Z  c-001@box-a -> c-002@box-b  [note]  hello\n"; rc != 0 || out != want {
		t.Fatalf("hub-tail: rc %d %q err %q, want %q", rc, out, errOut, want)
	}
	rc, out, errOut = capture(t, "", func() int { return cmdHubTail(cfg, []string{"--task", task, "--json"}) })
	var m msg.Message
	if rc != 0 || strings.Count(out, "\n") != 1 || json.Unmarshal([]byte(out), &m) != nil || m.Body != "hello" || m.TaskID != task {
		t.Fatalf("hub-tail --json: rc %d %q err %q", rc, out, errOut)
	}
	if rc, _, errOut := capture(t, "", func() int { return cmdHubTail(cfg, []string{"--task", "refused"}) }); rc == 0 || !strings.Contains(errOut, "not_found") {
		t.Errorf("hub-tail refused: rc %d %q", rc, errOut)
	}
	// --with-channel (SPL-3542): the envelope's channel leads each line, "" for a DM
	rc, out, errOut = capture(t, "", func() int { return cmdHubTail(cfg, []string{"--task", task, "--with-channel"}) })
	var wc struct {
		Channel *string `json:"channel"`
		Body    string  `json:"body"`
	}
	if rc != 0 || !strings.HasPrefix(out, `{"channel":"",`) || json.Unmarshal([]byte(out), &wc) != nil || wc.Channel == nil || wc.Body != "hello" {
		t.Fatalf("hub-tail --with-channel: rc %d %q err %q", rc, out, errOut)
	}
	rc, out, errOut = capture(t, "", func() int { return cmdHubRSP(cfg, []string{"--task", task}) })
	if want := `{"rsp":3,"task_id":"` + task + `"}` + "\n"; rc != 0 || out != want {
		t.Fatalf("hub-rsp: rc %d %q err %q, want %q", rc, out, errOut, want)
	}
	if rc, _, errOut := capture(t, "", func() int { return cmdHubRSP(cfg, []string{"--task", "refused"}) }); rc == 0 || !strings.Contains(errOut, "not_found") {
		t.Errorf("hub-rsp refused: rc %d %q", rc, errOut)
	}
	for _, f := range h.Frames() {
		if f.Type != wire.TTail {
			t.Errorf("hub read a %q frame, want tail only", f.Type)
		}
	}
}

// TestWithEnvelopeChannel: the channel is put first, escaped; a non-object is
// left as it is.
func TestWithEnvelopeChannel(t *testing.T) {
	for _, c := range []struct{ in, ch, want string }{
		{`{"v":1,"body":"x"}`, "ops", `{"channel":"ops","v":1,"body":"x"}`},
		{`{"v":1}`, "", `{"channel":"","v":1}`},
		{`{}`, "a\"b", `{"channel":"a\"b"}`},
		{`[1]`, "ops", `[1]`},
		{``, "ops", ``},
	} {
		if got := string(withEnvelopeChannel([]byte(c.in), c.ch)); got != c.want {
			t.Errorf("withEnvelopeChannel(%q, %q) = %q, want %q", c.in, c.ch, got, c.want)
		}
	}
}

// TestHubGetFileFetchesByID: the file lands in the local blob store under
// its sha256; bytes that do not hash to the id are refused (exit 78) and not
// kept; a hub refusal names its token.
func TestHubGetFileFetchesByID(t *testing.T) {
	const body = "file bytes\n"
	sum := sha256.Sum256([]byte(body))
	id := hex.EncodeToString(sum[:])
	liar := strings.Repeat("ab", 32)
	h := newScriptHub(t, nil, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/files/" + id, "/v1/files/" + liar:
			io.WriteString(w, body) //nolint:errcheck
		default:
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		}
	})
	cfg := hubCfg(t, h.URL)
	rc, out, errOut := capture(t, "", func() int { return cmdHubGetFile(cfg, []string{"--file-id", id}) })
	if want := `{"fetched":true,"file_id":"` + id + `"}` + "\n"; rc != 0 || out != want {
		t.Fatalf("hub-get-file: rc %d %q err %q, want %q", rc, out, errOut, want)
	}
	if got := mustRead(t, filepath.Join(cfg.FilesDir(), id)); got != body {
		t.Fatalf("stored %q, want %q", got, body)
	}
	if rc, _, errOut := capture(t, "", func() int { return cmdHubGetFile(cfg, []string{"--file-id", liar}) }); rc != 78 || !strings.Contains(errOut, liar) {
		t.Errorf("hash mismatch: rc %d %q, want 78", rc, errOut)
	}
	if _, err := os.Stat(filepath.Join(cfg.FilesDir(), liar)); !os.IsNotExist(err) {
		t.Errorf("a mismatched fetch was kept under its claimed id: %v", err)
	}
	if rc, _, errOut := capture(t, "", func() int { return cmdHubGetFile(cfg, []string{"--file-id", strings.Repeat("cd", 32)}) }); rc == 0 || !strings.Contains(errOut, "not_found") {
		t.Errorf("missing file: rc %d %q", rc, errOut)
	}
}

// TestInviteMailFlagDefaults: the flag defaults read the env, envOr trims and
// falls back on a blank value.
func TestInviteMailFlagDefaults(t *testing.T) {
	t.Setenv("SPOOL_HUB_AUTH_APP_URL", "https://app.example.com")
	t.Setenv("SPOOL_HUB_DEFAULT_LOCALE", "  ")
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	o := inviteMailFlags(fs)
	if err := fs.Parse([]string{"--min-gap", "5m", "--max-sends", "2"}); err != nil {
		t.Fatal(err)
	}
	if *o.appURL != "https://app.example.com" || *o.defLocale != "en" || *o.locale != "" || *o.minGap != 5*time.Minute || *o.maxSends != 2 {
		t.Fatalf("opts = %q %q %q %v %d", *o.appURL, *o.defLocale, *o.locale, *o.minGap, *o.maxSends)
	}
	t.Setenv("SPOOL_HUB_DEFAULT_LOCALE", " fi ")
	if got := envOr("SPOOL_HUB_DEFAULT_LOCALE", "en"); got != "fi" {
		t.Fatalf("envOr = %q, want fi", got)
	}
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
