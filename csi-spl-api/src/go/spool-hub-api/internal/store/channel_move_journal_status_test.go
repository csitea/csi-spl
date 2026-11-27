// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"
)

// mvRefused reads one step's detail.refused.reason and what else its detail holds.
func mvRefused(t *testing.T, st ChannelMoveStep) (string, map[string]any) {
	t.Helper()
	var d map[string]any
	if err := json.Unmarshal(st.Detail, &d); err != nil {
		t.Fatal(err)
	}
	r, _ := d["refused"].(map[string]any)
	reason, _ := r["reason"].(string)
	return reason, d
}

// C35, the store's half (spec 169 T17, 8.5.6): a refusal is kept in its step's
// row in <DST>, beside the start's detail; a step refused before its start gets
// a row, not done; the next finish drops it, and a done step takes none. The
// journal reads by move id in <DST> only, with started_at and the journal's
// done_at. A journal is waiting while P1 is its only step. RED CONTROL: drop
// "WHERE channel_move_steps.done_at IS NULL" (RefuseChannelMoveStep) -> the
// done P2 carries a refusal and this test fails.
func TestChannelMoveRefusalStored(t *testing.T) {
	f := seedMove(t)
	ctx := context.Background()
	req := f.req()
	plan, err := f.pg.PlanChannelMove(ctx, req.ChannelMovePlanRequest)
	if err != nil {
		t.Fatal(err)
	}
	id, err := f.pg.OpenChannelMove(ctx, ChannelMoveOpen{Dst: f.dst, Src: f.src, Channel: f.ch, GoMsgID: req.GoMsgID,
		StartedBy: req.StartedBy, Binds: plan.Binds})
	if err != nil {
		t.Fatal(err)
	}
	waiting := func(before time.Time) bool {
		t.Helper()
		ws, err := f.pg.WaitingChannelMoves(ctx, before)
		if err != nil {
			t.Fatal(err)
		}
		return slices.Contains(ws, ChannelMoveWaiting{Dst: f.dst, MoveID: id})
	}
	if !waiting(time.Now().Add(time.Minute)) || waiting(time.Now().Add(-time.Hour)) {
		t.Fatal("P1 alone: waiting after its done_at, not before it")
	}
	read := func() *ChannelMoveJournalRow {
		t.Helper()
		j, err := f.pg.ChannelMoveByID(ctx, f.dst, id)
		if err != nil || j == nil {
			t.Fatalf("ChannelMoveByID: %v %v", j, err)
		}
		return j
	}
	if j := read(); j.Src != f.src || j.Channel != f.ch || j.GoMsgID != req.GoMsgID || j.Done || !j.StepDone("P1") || j.Steps["P1"].StartedAt.IsZero() {
		t.Fatalf("the journal by id: %+v", j)
	}
	if err := f.pg.StartChannelMoveStep(ctx, f.dst, id, f.ch, "P2", map[string]any{"kept": "yes"}); err != nil {
		t.Fatal(err)
	}
	if err := f.pg.RefuseChannelMoveStep(ctx, f.dst, id, f.ch, "P2", map[string]any{"reason": "no orchestrator seat"}); err != nil {
		t.Fatal(err)
	}
	if reason, d := mvRefused(t, read().Steps["P2"]); reason != "no orchestrator seat" || d["kept"] != "yes" || read().StepDone("P2") {
		t.Fatalf("the refused P2: %q %v", reason, d)
	}
	if waiting(time.Now().Add(time.Minute)) {
		t.Error("a journal with a P2 row is not waiting")
	}
	if err := f.pg.RefuseChannelMoveStep(ctx, f.dst, id, f.ch, "P3", map[string]any{"reason": "P3 needs P2b done"}); err != nil {
		t.Fatal(err)
	}
	if reason, _ := mvRefused(t, read().Steps["P3"]); reason != "P3 needs P2b done" || read().StepDone("P3") {
		t.Fatalf("a refusal with no row: %q", reason)
	}
	if err := f.pg.FinishChannelMoveStep(ctx, f.dst, id, f.ch, "P2", ChannelMoveStepDone{}); err != nil {
		t.Fatal(err)
	}
	if err := f.pg.RefuseChannelMoveStep(ctx, f.dst, id, f.ch, "P2", map[string]any{"reason": "late"}); err != nil {
		t.Fatal(err)
	}
	if reason, _ := mvRefused(t, read().Steps["P2"]); reason != "" || !read().StepDone("P2") {
		t.Errorf("a done P2 took a refusal: %q", reason)
	}
	if j, err := f.pg.ChannelMoveByID(ctx, f.src, id); err != nil || j != nil {
		t.Errorf("CONTROL, read in <SRC>: %v %v, want none", j, err)
	}
	if err := f.pg.CloseChannelMove(ctx, f.dst, id); err != nil {
		t.Fatal(err)
	}
	if j := read(); !j.Done || j.DoneAt.IsZero() {
		t.Errorf("closed: %+v", j)
	}
}
