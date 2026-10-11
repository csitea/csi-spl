package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// The local-mode verbs of main.go driven through run(), as the binary runs
// them: config from the environment, output on stdout, exit codes (r7-10).

// localBox points the environment at a fresh local-mode box box-a with the
// agents ids, and returns its spool root.
func localBox(t *testing.T, ids ...string) string {
	t.Helper()
	dir := t.TempDir()
	root := filepath.Join(dir, "spool")
	for _, kv := range [][2]string{
		{"SPOOL_ROOT", root}, {"SPOOL_KEYS_DIR", filepath.Join(dir, "keys")}, {"SPOOL_PINS_DIR", ""},
		{"SPOOL_BOX_ID", "box-a"}, {"SPOOL_HUB_URL", ""}, {"SPOOL_TENANT", ""}, {"SPOOL_TENANT_ROOT_KEY", ""},
		{"SPOOL_MSG_VERSION", "1"}, {"SPOOL_LOG_LEVEL", "error"}, {"SPOOL_NOTIFY_CMD", "off"},
		{"SPOOL_DIR_LAYOUT", ""}, {"SPOOL_FLEET_ROOT", ""}, {"SPOOL_MCP_AS", ""},
	} {
		t.Setenv(kv[0], kv[1])
	}
	for _, id := range ids {
		for _, d := range []string{"inbox", "outbox", "archive"} {
			if err := os.MkdirAll(filepath.Join(root, id, d), 0o775); err != nil {
				t.Fatal(err)
			}
		}
	}
	return root
}

func runCap(t *testing.T, in string, args ...string) (int, string, string) {
	t.Helper()
	return capture(t, in, func() int { return run(args) })
}

func TestRunVersionHelpAndUnknown(t *testing.T) {
	localBox(t)
	if rc, out, _ := runCap(t, "", "version"); rc != 0 || out != version+"\n" {
		t.Errorf("version: rc %d %q", rc, out)
	}
	if rc, _, errOut := runCap(t, "", "--help"); rc != 0 || !strings.Contains(errOut, "usage: spool") {
		t.Errorf("--help: rc %d", rc)
	}
	if rc, _, errOut := runCap(t, "", "no-such-verb"); rc != 1 || !strings.Contains(errOut, `unknown command "no-such-verb"`) {
		t.Errorf("unknown verb: rc %d %q", rc, errOut)
	}
	t.Setenv("SPOOL_MSG_VERSION", "9")
	if rc, _, errOut := runCap(t, "", "layout"); rc != 1 || !strings.Contains(errOut, "SPOOL_MSG_VERSION 9") {
		t.Errorf("bad config: rc %d %q", rc, errOut)
	}
}

// TestRunKeygenAndPin: keygen prints the public key once and keeps the
// private key; pin installs another box's key locally.
func TestRunKeygenAndPin(t *testing.T) {
	localBox(t)
	rc, pub, errOut := runCap(t, "", "keygen")
	pub = strings.TrimSpace(pub)
	if rc != 0 || len(pub) != 44 {
		t.Fatalf("keygen: rc %d %q %q", rc, pub, errOut)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"keygen"}, "exists"},
		{[]string{"keygen", "--box", "Not A Box"}, "must be a valid box id"},
		{[]string{"keygen", "--nope"}, "flag provided but not defined"},
		{[]string{"pin", "--box", "box-b"}, "pubkey"},
		{[]string{"pin", "--nope"}, "flag provided but not defined"},
	} {
		if rc, _, errOut := runCap(t, "", c.args...); rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d %q, want a refusal naming %q", c.args, rc, errOut, c.want)
		}
	}
	if rc, out, _ := runCap(t, "", "keygen", "--force"); rc != 0 || strings.TrimSpace(out) == pub {
		t.Errorf("keygen --force: rc %d, same key %v", rc, strings.TrimSpace(out) == pub)
	}
	if rc, _, errOut := runCap(t, "", "pin", "--box", "box-b", "--pubkey", pub); rc != 0 {
		t.Fatalf("pin: rc %d %q", rc, errOut)
	}
	if got, err := sign.LoadPin(filepath.Join(os.Getenv("SPOOL_ROOT"), "pins"), "box-b"); err != nil || base64.StdEncoding.EncodeToString(got) != pub {
		t.Fatalf("pinned key %v %v, want %s", got, err, pub)
	}
}

// TestRunPutGetRoundTrip: put-file / put-dir print the blob id, get-file /
// get-dir restore the bytes; a wrong arg count prints the usage.
func TestRunPutGetRoundTrip(t *testing.T) {
	localBox(t)
	src := t.TempDir()
	file := filepath.Join(src, "a.txt")
	if err := os.WriteFile(file, []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rc, out, errOut := runCap(t, "", "put-file", file)
	var put struct {
		FileID string `json:"file_id"`
	}
	if rc != 0 || json.Unmarshal([]byte(out), &put) != nil || len(put.FileID) != 64 {
		t.Fatalf("put-file: rc %d %q %q", rc, out, errOut)
	}
	dest := filepath.Join(t.TempDir(), "b.txt")
	if rc, _, errOut := runCap(t, "", "get-file", put.FileID, dest); rc != 0 || mustRead(t, dest) != "alpha\n" {
		t.Fatalf("get-file: rc %d %q", rc, errOut)
	}
	rc, out, errOut = runCap(t, "", "put-dir", src)
	if rc != 0 || json.Unmarshal([]byte(out), &put) != nil || len(put.FileID) != 64 {
		t.Fatalf("put-dir: rc %d %q %q", rc, out, errOut)
	}
	destDir := filepath.Join(t.TempDir(), "d")
	if rc, _, errOut := runCap(t, "", "get-dir", put.FileID, destDir); rc != 0 || mustRead(t, filepath.Join(destDir, "a.txt")) != "alpha\n" {
		t.Fatalf("get-dir: rc %d %q", rc, errOut)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"put-file"}, "usage: put-file <path>"},
		{[]string{"put-dir", "a", "b"}, "usage: put-dir <path>"},
		{[]string{"get-file", "x"}, "usage: get-file <file_id> <dest>"},
		{[]string{"get-dir"}, "usage: get-dir <file_id> <dest>"},
		{[]string{"put-file", filepath.Join(src, "missing")}, "missing"},
		{[]string{"get-file", strings.Repeat("0", 64), dest + ".2"}, "spool:"},
	} {
		if rc, _, errOut := runCap(t, "", c.args...); rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d %q, want a refusal naming %q", c.args, rc, errOut, c.want)
		}
	}
}

// TestRunSendRecvTailLayout: a local send (with an attached blob, the
// repeatable --file-id flag) lands in the inbox; recv prints it as JSON or
// --compact and --ack archives it; tail prints the topic; layout lists the
// mailboxes.
func TestRunSendRecvTailLayout(t *testing.T) {
	localBox(t, "c-001", "c-002")
	file := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, out, _ := runCap(t, "", "put-file", file)
	var put struct {
		FileID string `json:"file_id"`
	}
	if err := json.Unmarshal([]byte(out), &put); err != nil {
		t.Fatal(err)
	}
	rc, out, errOut := runCap(t, "", "send", "--from", "c-001", "--to", "c-002", "--kind", "note", "--body", "hi there", "--file-id", put.FileID)
	var sent struct {
		Delivery string `json:"delivery"`
		TaskID   string `json:"task_id"`
	}
	if rc != 0 || json.Unmarshal([]byte(out), &sent) != nil || sent.Delivery != "local" {
		t.Fatalf("send: rc %d %q %q", rc, out, errOut)
	}
	if rc, out, _ := runCap(t, "", "recv", "--as", "c-002", "--compact"); rc != 0 || out != "c-001 note "+sent.TaskID+" files=1\nhi there\n" {
		t.Fatalf("recv --compact: rc %d %q", rc, out)
	}
	rc, out, _ = runCap(t, "", "recv", "--as", "c-002", "--ack")
	var got []msg.Message
	if rc != 0 || json.Unmarshal([]byte(out), &got) != nil || len(got) != 1 || got[0].Body != "hi there" {
		t.Fatalf("recv --ack: rc %d %q", rc, out)
	}
	if rc, out, _ := runCap(t, "", "recv", "--as", "c-002"); rc != 0 || strings.TrimSpace(out) != "[]" {
		t.Fatalf("recv after ack: rc %d %q, want []", rc, out)
	}
	if rc, out, _ := runCap(t, "", "tail", "--task", sent.TaskID); rc != 0 || !strings.Contains(out, "hi there") {
		t.Fatalf("tail: rc %d %q", rc, out)
	}
	if rc, out, _ := runCap(t, "", "tail", "--task", sent.TaskID, "--json"); rc != 0 || !strings.Contains(out, `"body":"hi there"`) {
		t.Fatalf("tail --json: rc %d %q", rc, out)
	}
	if rc, out, _ := runCap(t, "", "layout"); rc != 0 || out != "c-001\nc-002\n" {
		t.Fatalf("layout: rc %d %q", rc, out)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"recv", "--nope"}, "flag provided but not defined"},
		{[]string{"recv", "--as", "Bad Id"}, "spool:"},
		{[]string{"send", "--nope"}, "flag provided but not defined"},
		{[]string{"tail"}, "--task is required"},
		{[]string{"tail", "--nope"}, "flag provided but not defined"},
	} {
		if rc, _, errOut := runCap(t, "", c.args...); rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d %q, want a refusal naming %q", c.args, rc, errOut, c.want)
		}
	}
}

// TestRunLayoutUnreadableRoot: a spool root that is a file fails layout.
func TestRunLayoutUnreadableRoot(t *testing.T) {
	root := localBox(t)
	if err := os.WriteFile(root, []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rc, _, errOut := runCap(t, "", "layout"); rc == 0 || !strings.Contains(errOut, "spool:") {
		t.Fatalf("layout on a file: rc %d %q", rc, errOut)
	}
}

// TestRunMCPAndMigrateRefusals: mcp refuses a seat that is not an agent id
// and ends when stdin closes; migrate needs a DSN and a DDL dir.
func TestRunMCPAndMigrateRefusals(t *testing.T) {
	localBox(t)
	if rc, _, errOut := runCap(t, "", "mcp", "--as", "Not An Id"); rc != 1 || !strings.Contains(errOut, "is not an agent id") {
		t.Errorf("mcp --as bad: rc %d %q", rc, errOut)
	}
	if rc, _, _ := runCap(t, "", "mcp", "--nope"); rc != 1 {
		t.Errorf("mcp bad flag: rc %d", rc)
	}
	if rc, out, errOut := runCap(t, "", "mcp", "--as", "c-001"); rc != 0 || out != "" {
		t.Errorf("mcp on a closed stdin: rc %d %q %q, want 0 and no output", rc, out, errOut)
	}
	t.Setenv("SPOOL_HUB_DB_DSN", "")
	t.Setenv("SPOOL_HUB_MIGRATIONS_DIR", "")
	if rc, _, errOut := runCap(t, "", "migrate"); rc != 1 || !strings.Contains(errOut, "are required") {
		t.Errorf("migrate: rc %d %q", rc, errOut)
	}
	if rc, _, _ := runCap(t, "", "migrate", "--nope"); rc != 1 {
		t.Errorf("migrate bad flag: rc %d", rc)
	}
	if got := pick(true, "dir", "file") + pick(false, "dir", "file"); got != "dirfile" {
		t.Errorf("pick = %q", got)
	}
}
