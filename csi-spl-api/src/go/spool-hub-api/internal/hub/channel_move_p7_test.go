// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// P7 (spec 169 T8b): the objects of 5.3 are proved in the buckets themselves,
// and the kept list (5.6) carries the date each copy expires.

// toP6 runs a whole move up to and with P6.
func (f *moveFix) toP6(t *testing.T) {
	t.Helper()
	f.toP3(t)
	f.must(t, "step", "P4", nil)
	f.must(t, "mark", "P5", nil)
	f.must(t, "step", "P6", nil)
}

// proofsByName is P7's .proofs as name -> count.
func proofsByName(out map[string]any) map[string]float64 {
	m := map[string]float64{}
	ps, _ := out["proofs"].([]any)
	for _, p := range ps {
		r := p.(map[string]any)
		m[r["name"].(string)], _ = r["count"].(float64)
	}
	return m
}

// p4DoneAt reads P4's done_at from the journal table, as the test's own check.
func p4DoneAt(t *testing.T, f *moveFix) time.Time {
	t.Helper()
	ctx := context.Background()
	var at time.Time
	err := pgx.BeginFunc(ctx, f.e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT done_at FROM channel_move_steps WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4'`,
			f.dst, f.moveID).Scan(&at)
	})
	if err != nil {
		t.Fatal(err)
	}
	return at.UTC()
}

// The green case: both buckets' proofs are 0, and every kept row that ends with
// a retention is P4's done_at + the days P7's detail gave; the others keep their
// words. kept_until is the last of the dates (Q3).
func TestChannelMoveP7ObjectsAndExpiry(t *testing.T) {
	f := moveFixture(t, true)
	f.toP6(t)
	days := map[string]int{"daily DB dumps": 30, "off-project copy of the dumps": 90, "Cloud SQL automated backups": 7,
		"Qto daily export": 30, "box-state copy": 30, "hub logs": 30}
	out := f.must(t, "step", "P7", moveDetail(map[string]any{"retention_days": days}))
	got := proofsByName(out)
	for _, n := range []string{"objects M4 files bucket: left in <SRC>", "objects M4 files bucket: missing in <DST>",
		"objects M8 Qto pictures: left in <SRC>", "objects M8 Qto pictures: missing in <DST>"} {
		if c, ok := got[n]; !ok || c != 0 {
			t.Errorf("proof %q: %v %v, want present and 0", n, c, ok)
		}
	}
	at := p4DoneAt(t, f)
	kept, _ := out["kept"].([]any)
	dated := 0
	for _, k := range kept {
		r := k.(map[string]any)
		store, _ := r["store"].(string)
		d, ok := days[store]
		if !ok {
			if strings.Contains(r["gone_by"].(string), "retention") || r["expires"] != r["gone_by"] {
				t.Errorf("an undated row keeps its words: %v", r)
			}
			continue
		}
		want := at.AddDate(0, 0, d).Format(time.DateOnly)
		if r["expires"] != want || !strings.HasSuffix(r["gone_by"].(string), ": "+want) {
			t.Errorf("%s: %v, want expires %s (P4 %s + %d days)", store, r, want, at, d)
		}
		dated++
	}
	if dated != len(days) {
		t.Errorf("dated %d kept rows, want %d: %v", dated, len(days), kept)
	}
	if want := at.AddDate(0, 0, 90).Format(time.DateOnly); out["kept_until"] != want {
		t.Errorf("kept_until %v, want %s", out["kept_until"], want)
	}
	t.Logf("green: kept_until %v; proofs %v", out["kept_until"], got)
}

// RED CONTROL: an object planted back in <SRC> after P6 fails P7, which stays
// not done; P6's counts said it was deleted. With no retention_days a kept row
// says "not read", never a date.
func TestChannelMoveP7ObjectLeftInSource(t *testing.T) {
	f := moveFixture(t, true)
	f.toP6(t)
	key, err := blob.Key(f.src, f.blobID)
	if err != nil {
		t.Fatal(err)
	}
	if err := (blob.Dir{Root: f.e.blobs}).Put(context.Background(), key, []byte("the channel's file "+f.ch)); err != nil {
		t.Fatal(err)
	}
	out := f.must(t, "step", "P7", nil)
	if c := proofsByName(out)["objects M4 files bucket: left in <SRC>"]; c != 1 {
		t.Fatalf("the planted object: count %v, want 1: %v", c, out["proofs"])
	}
	if s := steps(f.must(t, "journal", "", nil))["P7"]; s != "started" {
		t.Errorf("a failed P7 is not done: %v", s)
	}
	until, _ := out["kept_until"].(string)
	if !strings.HasPrefix(until, "not read: no date for ") {
		t.Errorf("kept_until with no retention_days: %q", until)
	}
	for _, k := range out["kept"].([]any) {
		r := k.(map[string]any)
		if strings.Contains(r["gone_by"].(string), "retention") && r["expires"] != "not read: no retention_days in P7's detail" {
			t.Errorf("no date is guessed: %v", r)
		}
	}
	t.Logf("red control: objects M4 files bucket: left in <SRC> %v", proofsByName(out)["objects M4 files bucket: left in <SRC>"])
}

// p7Stay posts into another <SRC> channel through movePost, so the row has a
// real post's shape: its text in body and again in msg.
func (f *moveFix) p7Stay(t *testing.T, body string) string {
	t.Helper()
	id := uuid4()
	movePost(t, f.e, f.src, id, uuid4(), "stay-"+f.ch, f.admin, body, time.Now().UTC().Truncate(time.Second))
	return id
}

func p7Mentions(out map[string]any) (uuid, name float64, ids string) {
	m, _ := out["mentions"].(map[string]any)
	uuid, _ = m["uuid_with_redirect"].(float64)
	name, _ = m["name_or_channel_id"].(float64)
	rows, _ := m["rows"].([]any)
	for _, r := range rows {
		ids += " " + r.(map[string]any)["msg_id"].(string) + "=" + r.(map[string]any)["class"].(string)
	}
	return uuid, name, ids
}

// Q4 = A (5.4): a staying post that links or names the moved channel is left
// and listed. P7 holds, and prints the two classes and the rows by id, never
// their text.
func TestChannelMoveP7StayingPostIsListed(t *testing.T) {
	f := moveFixture(t, true)
	link := f.p7Stay(t, "see /t/"+f.task)
	name := f.p7Stay(t, "the #"+f.ch+" room")
	f.toP6(t)
	out := f.must(t, "step", "P7", nil)
	for n, c := range proofsByName(out) {
		if c != 0 {
			t.Errorf("proof %q = %v, want 0: %v", n, c, out["proofs"])
		}
	}
	if s := steps(f.must(t, "journal", "", nil))["P7"]; s != "done" {
		t.Errorf("P7 %v, want done", s)
	}
	u, n, ids := p7Mentions(out)
	if u != 1 || n != 1 || !strings.Contains(ids, link+"=uuid with redirect") || !strings.Contains(ids, name+"=name or channel id") {
		t.Errorf("mentions: uuid %v name %v rows%s, want 1, 1 and both ids", u, n, ids)
	}
	raw, _ := json.Marshal(out["mentions"])
	if strings.Contains(string(raw), "see /t/") {
		t.Errorf("a mention carries the post's text: %s", raw)
	}
	lines := ""
	for name := range proofsByName(out) {
		lines += name + "\n"
	}
	for _, want := range []string{"scan messages.body (known 2 of 2, kept: 5.4)", "scan messages.msg (known 2 of 2, kept: 5.4)"} {
		if !strings.Contains(lines, want) {
			t.Errorf("no proof line %q in:\n%s", want, lines)
		}
	}
}

// RED CONTROLS: each leaves P7 not done, with the listed post still listed.
func TestChannelMoveP7StillRefuses(t *testing.T) {
	cases := []struct {
		name, want string
		plant      func(t *testing.T, f *moveFix)
	}{
		{"a moved row left behind", "scan messages.body", func(t *testing.T, f *moveFix) {
			movePost(t, f.e, f.src, uuid4(), f.task, f.ch, f.admin, "left /t/"+f.task, time.Now().UTC())
		}},
		{"a set UUID with no redirect row", "scan messages.body", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `DELETE FROM channel_move_redirects WHERE src_tenant_id = $1 AND old_ref = $2`, f.src, f.task)
		}},
		{"an expired redirect row", "scan messages.body", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `UPDATE channel_move_redirects SET created_at = now() - interval '2 days', expires_at = now() - interval '1 day'
				WHERE src_tenant_id = $1 AND old_ref = $2`, f.src, f.task)
		}},
		{"another column", "scan workspace_events.message", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `INSERT INTO workspace_events (tenant_id, kind, message) VALUES ($1, 'tenant.note', $2)`, f.src, "see "+f.task)
		}},
		{"a revision's old text", "scan message_revisions.body", func(t *testing.T, f *moveFix) {
			id := f.p7Stay(t, "no link any more")
			moveExec(t, f.e, `INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at)
				VALUES ($1, $2, 1, $3, 'c-100', now())`, f.src, id, "see /t/"+f.task)
		}},
		{"the msg copy says more than the post", "scan messages.msg", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `UPDATE messages SET msg = msg || jsonb_build_object('title', $2::text) WHERE tenant_id = $1 AND body LIKE 'see /t/%'`, f.src, f.task)
		}},
		{"a set UUID in the msg copy's files", "scan messages.msg", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `UPDATE messages SET msg = jsonb_set(msg, '{files}', jsonb_build_array($2::text)) WHERE tenant_id = $1 AND body LIKE 'see /t/%'`, f.src, f.task)
		}},
		{"an edited post whose msg keeps the old link", "scan messages.msg", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `UPDATE messages SET body = 'no link any more' WHERE tenant_id = $1 AND body LIKE 'see /t/%'`, f.src)
		}},
		{"an edited post whose msg differs from its body", "scan messages.msg", func(t *testing.T, f *moveFix) {
			moveExec(t, f.e, `UPDATE messages SET body = body || ' edited' WHERE tenant_id = $1 AND body LIKE 'see /t/%'`, f.src)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := moveFixture(t, true)
			f.p7Stay(t, "see /t/"+f.task)
			f.toP6(t)
			c.plant(t, f)
			out := f.must(t, "step", "P7", nil)
			hit := false
			for n, v := range proofsByName(out) {
				hit = hit || (strings.HasPrefix(n, c.want) && v != 0)
			}
			if !hit {
				t.Errorf("no failing %q: %v", c.want, out["proofs"])
			}
			if s := steps(f.must(t, "journal", "", nil))["P7"]; s != "started" {
				t.Errorf("P7 %v, want started", s)
			}
			t.Logf("red: %v", out["proofs"])
		})
	}
}
