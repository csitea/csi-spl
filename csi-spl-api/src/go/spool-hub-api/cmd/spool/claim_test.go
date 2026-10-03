package main

import (
	"encoding/json"
	"io"
	"os"
	"testing"
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
