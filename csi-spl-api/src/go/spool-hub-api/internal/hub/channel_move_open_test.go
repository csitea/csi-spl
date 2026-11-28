// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"net/http"
	"testing"
)

// open is op open on the operator route; dst "" = every workspace.
func (f *moveFix) open(t *testing.T, dst string) (int, map[string]any) {
	t.Helper()
	return opCall(t, f.e, f.src, http.MethodPost, moveURL, "good", map[string]any{"op": "open", "env": "dev", "dst": dst})
}

// openMoves wants a 200 and answers its .moves of the fixture's move.
func (f *moveFix) openMoves(t *testing.T, dst string) []map[string]any {
	t.Helper()
	code, out := f.open(t, dst)
	if code != http.StatusOK {
		t.Fatalf("open: %d %v", code, out)
	}
	var mine []map[string]any
	all, _ := out["moves"].([]any)
	for _, m := range all {
		if row, _ := m.(map[string]any); row["move_id"] == f.moveID && f.moveID != "" {
			mine = append(mine, row)
		}
	}
	return mine
}

// C34, the hub's half (spec 169 T16, 8.5.5 items 2 and 3): op open lists an
// open journal with its GO, P1's detail.inputs and <DST>'s orchestrator seats,
// in its <DST> and hub-wide; a P1 whose inputs were lost (R7 c-250 N4) answers
// inputs null, never {}; a done journal is not listed; a bad dst is 400.
// RED CONTROL: on origin/master before T16, op open is 400 bad_op.
func TestChannelMoveOpenC34(t *testing.T) {
	f := moveFixture(t, true)
	if code, out := f.open(t, f.dst); code != http.StatusOK || listLen(out["moves"]) != 0 {
		t.Fatalf("before P1: %d %v, want 200 and no move", code, out)
	}
	detail := map[string]any{"keep_emails": []string{"Kept@Example.com"}, "caller": "c-001@box-a"}
	f.moveID, _ = f.must(t, "step", "P1", map[string]any{"detail": detail})["move_id"].(string)

	got := f.openMoves(t, f.dst)
	if len(got) != 1 {
		t.Fatalf("after P1: %v, want the one move", got)
	}
	m := got[0]
	if m["src"] != f.src || m["channel"] != f.ch || m["dst"] != f.dst || m["go_msg_id"] != f.goID {
		t.Errorf("the move's journal: %v", m)
	}
	if st, _ := m["steps"].(map[string]any); len(st) != 1 || st["P1"] != "done" {
		t.Errorf("steps: %v, want P1 done alone", m["steps"])
	}
	in, _ := m["inputs"].(map[string]any)
	if in == nil || in["caller"] != "c-001@box-a" || listLen(in["keep_emails"]) != 1 || in["keep_emails"].([]any)[0] != "kept@example.com" {
		t.Errorf("inputs: %v, want P1's detail as stored", m["inputs"])
	}
	if o, _ := m["orchestrators"].([]any); len(o) != 1 || o[0] != "c-001@box-a" {
		t.Errorf("orchestrators: %v, want [c-001@box-a]", m["orchestrators"])
	}
	if n := len(f.openMoves(t, "")); n != 1 {
		if _, out := f.open(t, ""); listLen(out["moves"]) < 200 { // past the bound, an older move hides it
			t.Errorf("hub-wide: the move listed %d times among %d", n, listLen(out["moves"]))
		}
	}

	moveExec(t, f.e, `UPDATE channel_move_steps SET detail = '{}'::jsonb WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P1'`, f.dst, f.moveID)
	if got = f.openMoves(t, f.dst); len(got) != 1 || got[0]["inputs"] != nil {
		t.Errorf("P1 with no inputs: %v, want inputs null", got)
	}
	if _, ok := got[0]["inputs"]; !ok {
		t.Errorf("P1 with no inputs: %v, want the field, null", got[0])
	}

	moveExec(t, f.e, `UPDATE channel_move_journal SET done_at = clock_timestamp() WHERE tenant_id = $1 AND move_id = $2::uuid`, f.dst, f.moveID)
	if got = f.openMoves(t, f.dst); len(got) != 0 {
		t.Errorf("a done journal is listed: %v", got)
	}
	if code, out := f.open(t, "Not A Slug!"); code != http.StatusBadRequest {
		t.Errorf("bad dst: %d %v, want 400", code, out)
	}
}

// The other door stays shut: op open needs the operator's token.
func TestChannelMoveOpenNeedsOperator(t *testing.T) {
	e := chanMoveEnv(t)
	src, _ := e.tenant()
	if code, _ := opCall(t, e, src, http.MethodPost, moveURL, "other-sa", map[string]any{"op": "open"}); code == http.StatusOK {
		t.Fatalf("an identity off the allow-list read the open journals")
	}
}
