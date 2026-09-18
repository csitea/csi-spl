package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

const task = "11111111-1111-4111-8111-111111111111"

// side is one spool root driven either by the real CLI binary or by MCP tools.
type side struct {
	cfg  *config.Config
	root string // the per-side temp dir, normalised to <ROOT> before comparing
}

// harness holds a CLI side and an MCP side over twin empty roots, so the same
// inputs must yield the same files and return values.
type harness struct {
	t        *testing.T
	bin      string
	cli, mcp side
	cs       *sdk.ClientSession
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "spool")
	build := exec.Command("go", "build", "-o", bin, "../../cmd/spool")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build spool: %v\n%s", err, out)
	}

	// Local mode: no keys, no pins on either side.
	cliCfg := testkit.NewConfig(t)
	mcpCfg := testkit.NewConfig(t)

	ctx := context.Background()
	ct, st := sdk.NewInMemoryTransports()
	if _, err := NewServer(mcpCfg, "test").Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := sdk.NewClient(&sdk.Implementation{Name: "sc-004", Version: "test"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	return &harness{
		t: t, bin: bin, cs: cs,
		cli: side{cliCfg, filepath.Dir(cliCfg.SpoolRoot)},
		mcp: side{mcpCfg, filepath.Dir(mcpCfg.SpoolRoot)},
	}
}

// run invokes the CLI verb and returns stdout without its final newline, the
// stderr line, and the exit code.
func (h *harness) run(args ...string) (string, string, int) {
	h.t.Helper()
	cmd := exec.Command(h.bin, args...)
	cmd.Env = append(os.Environ(),
		"SPOOL_ROOT="+h.cli.cfg.SpoolRoot, "SPOOL_KEYS_DIR="+h.cli.cfg.KeysDir,
		"SPOOL_PINS_DIR="+h.cli.cfg.PinsDir, "SPOOL_LOG_LEVEL=error")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		h.t.Fatalf("run %v: %v", args, err)
	}
	return strings.TrimSuffix(out.String(), "\n"), strings.TrimSpace(errb.String()), rc
}

// call invokes an MCP tool and returns its text content blocks and IsError.
func (h *harness) call(name string, args map[string]any) ([]string, bool) {
	h.t.Helper()
	res, err := h.cs.CallTool(context.Background(), &sdk.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		h.t.Fatalf("call %s: protocol error %v", name, err)
	}
	var texts []string
	for _, c := range res.Content {
		if tc, ok := c.(*sdk.TextContent); ok {
			texts = append(texts, tc.Text)
		}
	}
	return texts, res.IsError
}

// same asserts a CLI stdout and an MCP text are equal once each side's root is
// replaced by <ROOT> and the per-send nonce fields are masked.
func (h *harness) same(what, cli, mcp string) {
	h.t.Helper()
	c, m := h.norm(cli, h.cli), h.norm(mcp, h.mcp)
	if c != m {
		h.t.Errorf("%s differs:\n cli: %s\n mcp: %s", what, c, m)
	}
}

var nonceRe = regexp.MustCompile(`"(msg_id|ts|sig)":"[^"]*"`)
var tsRe = regexp.MustCompile(`\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ`)

func (h *harness) norm(s string, sd side) string {
	s = strings.ReplaceAll(s, sd.root, "<ROOT>")
	s = nonceRe.ReplaceAllString(s, `"$1":"*"`)
	return tsRe.ReplaceAllString(s, "<TS>")
}

// tree returns rel-path -> normalised content of every file under dir.
func (h *harness) tree(sd side, dir string) map[string]string {
	h.t.Helper()
	out := map[string]string{}
	base := filepath.Join(sd.cfg.SpoolRoot, dir)
	filepath.Walk(base, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(base, p)
		if strings.HasSuffix(rel, ".json") {
			rel = "<msg>.json" // name carries ts + msg_id; counted, not compared
			for out[rel] != "" {
				rel += "+"
			}
		}
		out[rel] = h.norm(string(b), sd)
		return nil
	})
	return out
}

func (h *harness) sameTree(dir string) {
	h.t.Helper()
	c, m := h.tree(h.cli, dir), h.tree(h.mcp, dir)
	ck, mk := keys(c), keys(m)
	if strings.Join(ck, ",") != strings.Join(mk, ",") {
		h.t.Fatalf("%s: file sets differ: cli %v, mcp %v", dir, ck, mk)
	}
	for _, k := range ck {
		if c[k] != m[k] {
			h.t.Errorf("%s/%s differs:\n cli: %s\n mcp: %s", dir, k, c[k], m[k])
		}
	}
}

// TestSC004MCPEqualsCLI is spec 002 SC-004: every MCP tool and its CLI verb give
// identical files and return values for the same inputs, an unsigned send from
// an agent with no key works on both, and a refusal (hash mismatch) is a tool
// error carrying the CLI's reason and exit 78.
func TestSC004MCPEqualsCLI(t *testing.T) {
	h := newHarness(t)

	src := filepath.Join(t.TempDir(), "patch.txt")
	if err := os.WriteFile(src, []byte("patch-bytes\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// put-file
	cliPut, _, rc := h.run("put-file", src)
	mcpPut, isErr := h.call("spool_put_file", map[string]any{"path": src})
	if rc != 0 || isErr || len(mcpPut) != 1 {
		t.Fatalf("put-file: rc=%d isErr=%v content=%v", rc, isErr, mcpPut)
	}
	if cliPut != mcpPut[0] {
		t.Errorf("put-file return differs:\n cli: %s\n mcp: %s", cliPut, mcpPut[0])
	}
	h.sameTree("files")
	var put struct {
		FileID string `json:"file_id"`
	}
	json.Unmarshal([]byte(cliPut), &put)

	// send
	cliSend, _, rc := h.run("send", "--from", "GRK-03", "--to", "CLE-07", "--task", task,
		"--kind", "task", "--body", "review this", "--file-id", put.FileID)
	mcpSend, isErr := h.call("spool_send", map[string]any{"from": "GRK-03", "to": "CLE-07",
		"task_id": task, "kind": "task", "body": "review this", "file_ids": []string{put.FileID}})
	if rc != 0 || isErr {
		t.Fatalf("send: rc=%d isErr=%v content=%v", rc, isErr, mcpSend)
	}
	h.same("send return", cliSend, mcpSend[0])
	h.sameTree("CLE-07/inbox")
	h.sameTree("GRK-03/outbox")

	// tail, human and NDJSON
	cliTail, _, _ := h.run("tail", "--task", task)
	mcpTail, _ := h.call("spool_tail", map[string]any{"task_id": task})
	h.same("tail", cliTail+"\n", mcpTail[0])
	cliTailJ, _, _ := h.run("tail", "--task", task, "--json")
	mcpTailJ, _ := h.call("spool_tail", map[string]any{"task_id": task, "json": true})
	h.same("tail --json", cliTailJ+"\n", mcpTailJ[0])

	// recv --ack, then an empty recv
	cliRecv, _, rc := h.run("recv", "--as", "CLE-07", "--ack")
	mcpRecv, isErr := h.call("spool_recv", map[string]any{"as": "CLE-07", "ack": true})
	if rc != 0 || isErr {
		t.Fatalf("recv: rc=%d isErr=%v content=%v", rc, isErr, mcpRecv)
	}
	h.same("recv --ack", cliRecv, mcpRecv[0])
	h.sameTree("CLE-07")
	cliRecv, _, _ = h.run("recv", "--as", "CLE-07")
	mcpRecv, _ = h.call("spool_recv", map[string]any{"as": "CLE-07"})
	if cliRecv != "[]" || mcpRecv[0] != "[]" {
		t.Errorf("second recv: cli %q mcp %q, want []", cliRecv, mcpRecv[0])
	}

	// get-file
	cliDest := filepath.Join(h.cli.root, "out.txt")
	mcpDest := filepath.Join(h.mcp.root, "out.txt")
	cliGet, _, rc := h.run("get-file", put.FileID, cliDest)
	mcpGet, isErr := h.call("spool_get_file", map[string]any{"file_id": put.FileID, "dest": mcpDest})
	if rc != 0 || isErr {
		t.Fatalf("get-file: rc=%d isErr=%v content=%v", rc, isErr, mcpGet)
	}
	h.same("get-file return", cliGet, mcpGet[0])
	cb, _ := os.ReadFile(cliDest)
	mb, _ := os.ReadFile(mcpDest)
	if !bytes.Equal(cb, mb) || string(cb) != "patch-bytes\n" {
		t.Errorf("get-file bytes: cli %q mcp %q", cb, mb)
	}

	// unsigned: an agent with no key and no pin sends on both sides
	cliU, _, rc := h.run("send", "--from", "AGY-09", "--to", "CLE-07", "--task", task, "--kind", "note", "--body", "hi")
	mcpU, isErr := h.call("spool_send", map[string]any{"from": "AGY-09", "to": "CLE-07", "task_id": task, "kind": "note", "body": "hi"})
	if rc != 0 || isErr {
		t.Fatalf("unsigned send: rc=%d isErr=%v content=%v", rc, isErr, mcpU)
	}
	h.same("unsigned send return", cliU, mcpU[0])
	if !strings.Contains(cliU, `"delivery":"local"`) {
		t.Errorf("send result must carry delivery=local: %s", cliU)
	}
	h.sameTree("CLE-07")

	// refusal: a corrupted blob fails get-file with exit 78 == tool error
	for _, sd := range []side{h.cli, h.mcp} {
		if err := os.WriteFile(filepath.Join(sd.cfg.FilesDir(), put.FileID), []byte("rotted\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	_, cliErr, rc := h.run("get-file", put.FileID, filepath.Join(h.cli.root, "bad.txt"))
	mcpErr, isErr := h.call("spool_get_file", map[string]any{"file_id": put.FileID, "dest": filepath.Join(h.mcp.root, "bad.txt")})
	if rc != 78 {
		t.Fatalf("hash mismatch CLI exit = %d, want 78 (%s)", rc, cliErr)
	}
	if !isErr || len(mcpErr) != 1 || h.norm(mcpErr[0], h.mcp) != h.norm(cliErr+" (exit 78)", h.cli) {
		t.Errorf("hash mismatch tool result: isErr=%v content=%q, want %q", isErr, mcpErr, cliErr+" (exit 78)")
	}
}

// TestRecvMalformedIsToolError: a malformed inbox file makes the CLI print the
// good messages and exit 1 (not a refusal); the tool returns the same array
// plus the same reason, flagged as an error.
func TestRecvMalformedIsToolError(t *testing.T) {
	h := newHarness(t)
	for _, sd := range []side{h.cli, h.mcp} {
		dir := filepath.Join(sd.cfg.SpoolRoot, "CLE-07", "inbox")
		if err := os.MkdirAll(dir, 0o775); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "bad.json"), []byte(`{"v":1,"not":"a message"}`), 0o664); err != nil {
			t.Fatal(err)
		}
	}
	cliOut, cliErr, rc := h.run("recv", "--as", "CLE-07")
	mcpOut, isErr := h.call("spool_recv", map[string]any{"as": "CLE-07"})
	if rc != 1 {
		t.Fatalf("malformed CLI exit = %d, want 1", rc)
	}
	if !isErr || len(mcpOut) != 2 || mcpOut[0] != cliOut || h.norm(mcpOut[1], h.mcp) != h.norm(cliErr+" (exit 1)", h.cli) {
		t.Errorf("malformed tool result: isErr=%v content=%q, want [%q %q]", isErr, mcpOut, cliOut, cliErr+" (exit 1)")
	}
}

// TestToolNamesAreCanonical: exactly the five kind-agnostic tools, no
// per-kind variants (Constitution VIII, contracts/mcp-tools.md).
func TestToolNamesAreCanonical(t *testing.T) {
	h := newHarness(t)
	res, err := h.cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, tl := range res.Tools {
		got = append(got, tl.Name)
	}
	sort.Strings(got)
	want := "spool_get_file,spool_put_file,spool_recv,spool_send,spool_tail"
	if strings.Join(got, ",") != want {
		t.Errorf("tools = %v, want %s", got, want)
	}
}

func keys(m map[string]string) []string {
	var k []string
	for s := range m {
		k = append(k, s)
	}
	sort.Strings(k)
	return k
}
