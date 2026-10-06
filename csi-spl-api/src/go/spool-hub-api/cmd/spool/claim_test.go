package main

import (
	"encoding/json"
	"flag"
	"io"
	"os"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// The exit codes and shapes do_spl_peer_poll (spec 068 L3) reads from
// `spool claim`: --check exits 0 held, 1 lost, 2 for an answer it cannot
// read (never 1, which means lost); --poll / --renew print a JSON array.
func TestClaimPrintForThePollLoop(t *testing.T) {
	quiet := func(fn func() int) (int, string) {
		r, w, _ := os.Pipe()
		old := os.Stdout
		os.Stdout = w
		code := fn()
		w.Close()
		os.Stdout = old
		b, _ := io.ReadAll(r)
		return code, string(b)
	}
	for _, c := range []struct {
		op, ans string
		want    int
	}{
		{"check", `{"seat":"c-001@sat","msgs":[],"dead":[],"held":true}`, 0},
		{"check", `{"seat":"c-001@sat","msgs":[],"dead":[]}`, 1},
		{"check", `not json`, 2},
		{"adopt", `{"seat":"c-001@sat","msgs":[],"dead":[]}`, 0},
	} {
		if code, _ := quiet(func() int { return claimPrint(c.op, json.RawMessage(c.ans), false) }); code != c.want {
			t.Errorf("%s %s: exit %d, want %d", c.op, c.ans, code, c.want)
		}
	}
	ans := `{"seat":"c-001@sat","msgs":[{"msg_id":"m1","task_id":"t1","ts":"2026-10-03T15:00:00Z","from":"c-120@sat","to":"peers@sat",` +
		`"kind":"note","responsible_gen":3,"claim_n":1,"msg":{"v":1,"msg_id":"m1","task_id":"t1","from":"c-120","to":"peers","kind":"note","body":"hi","files":[]}}],` +
		`"dead":[{"msg_id":"m2","task_id":"t2","from":"c-121@sat","to":"peers@sat","kind":"task","responsible_gen":4,"handled_how":"dead"}]}`
	code, out := quiet(func() int { return claimPrint("poll", json.RawMessage(ans), false) })
	var rows []map[string]any
	if err := json.Unmarshal([]byte(out), &rows); code != 0 || err != nil || len(rows) != 2 {
		t.Fatalf("poll: exit %d %q %v", code, out, err)
	}
	if r := rows[0]; r["msg_id"] != "m1" || r["responsible_gen"] != float64(3) || r["from"] != "c-120" || r["body"] != "hi" || r["msg"] != nil || r["dead"] != nil {
		t.Fatalf("claimed row: %v", r)
	}
	if r := rows[1]; r["msg_id"] != "m2" || r["dead"] != true || r["from"] != "c-121@sat" {
		t.Fatalf("dead row: %v", r)
	}
	if _, out = quiet(func() int { return claimPrint("poll", json.RawMessage(ans), true) }); out[0] != '{' {
		t.Fatalf("--full: %q", out)
	}
}

// Spec 093 4.7 (FR-009): the fence's three exits. 1 is "lost" only on an
// answer that says so; a hub that cannot be reached is 2 ("unconfirmed": do
// not act, do not assume lost); the op flags take exactly one op.
func TestClaimFenceExitsAndOps(t *testing.T) {
	cfg := &config.Config{SpoolRoot: t.TempDir(), KeysDir: t.TempDir(), BoxID: "box-b", HubURL: "http://127.0.0.1:1"}
	msg := "0b0c2f6e-3d4f-4a51-9c7e-1f2a3b4c5d6e"
	if code := cmdClaim(cfg, []string{"--check", "--as", "c-001", "--msg", msg, "--gen", "3"}); code != 2 {
		t.Fatalf("--check with the hub down: exit %d, want 2", code)
	}
	for _, args := range [][]string{
		{"--as", "c-001"},
		{"--poll", "--accept", msg, "--as", "c-001"},
		{"--park", msg, "--touch", msg, "--as", "c-001"},
	} {
		if code := cmdClaim(cfg, args); code != 1 {
			t.Fatalf("%v: exit %d, want 1 (exactly one op)", args, code)
		}
	}
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	ops := claimOpFlags(fs)
	if err := fs.Parse([]string{"--accept", msg}); err != nil {
		t.Fatal(err)
	}
	in := action.ClaimArgs{}
	if !claimPickOp(ops, &in) || in.Op != "accept" || in.MsgID != msg {
		t.Fatalf("--accept <msg>: %+v", in)
	}
}
