package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0155 (specs/110 T001, spec section 7 test b): an m-NNN agent is a row
// in every table that names an agent. Postgres only.
//
// The database is migrated through 0155. "Before" is the same file with the
// letters narrowed back to [acgq] and 'mistral' left out of the kinds list,
// which are the 0101 / 0102 / 0110 / 0149 texts; it is applied in a
// rolled-back transaction, then the real file on top of it.
//
// Pair, one write per CHECK (n=8), plus the trigger (n=1):
//   - refused before (n=8): roster, issues.assignee, fleet_lanes, the three
//     fleet_asks agents, agent_id_aliases.new_id and fleet_agent_kinds_off,
//     each 23514 on its own constraint; a message to m-004 gets no responsible.
//   - stored after (n=8 + 1): the same writes; the message names
//     m-004@box-a responsible.
//
// Then the five-way split: mistral 55 / grok 0 is stored, a sum of 99 and
// grok's 50 left next to mistral's 55 are refused (n=1 + 2), and m-001 on the
// roster seats the workspace for a human post to ALL-0 (n=1).
const mistralKindFile = "0155_mistral_kind.sql"

func TestMistralKind0155(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), mistralKindFile))
	if err != nil {
		t.Fatal(err)
	}
	after := string(raw)
	before := strings.NewReplacer("[acgmq]", "[acgq]", ", 'mistral'", "").Replace(after)
	if before == after || strings.Contains(before, "'qwen', 'mistral'") {
		t.Fatalf("%s: the before text did not narrow the grammar", mistralKindFile)
	}

	tenant := newTenant(t, pg)
	now := time.Now().UTC()
	if err := pg.PutPin(ctx, tenant, "box-a", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetRoster(ctx, tenant, "box-a", []string{"c-005"}, now); err != nil {
		t.Fatal(err)
	}
	seedMsg := msgFor(tenant, uuid4(), "box-a", now, now, "env-"+uuid4())
	if _, err := pg.InsertMessage(ctx, seedMsg); err != nil {
		t.Fatal(err)
	}

	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	exec := func(what, q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	// try runs one write under a savepoint and returns the CHECK it broke, "" if stored.
	try := func(q string, args ...any) string {
		t.Helper()
		sp, err := tx.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		_, err = sp.Exec(ctx, q, args...)
		if err == nil {
			if err := sp.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			return ""
		}
		sp.Rollback(ctx) //nolint:errcheck
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "23514" {
			t.Fatalf("%s: not a CHECK violation: %v", q, err)
		}
		return pe.ConstraintName
	}
	// copyMsg inserts a copy of the seed message with `set` overridden, every
	// stored column but the generated ones (search_tsv), and returns `ret`.
	var cols, rcols string
	if err := tx.QueryRow(ctx, `SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum),
			string_agg('r.' || quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
		WHERE attrelid = 'messages'::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''`).Scan(&cols, &rcols); err != nil {
		t.Fatal(err)
	}
	copyMsg := func(set, ret string) string {
		t.Helper()
		var got string
		if err := tx.QueryRow(ctx, `INSERT INTO messages (`+cols+`)
			SELECT `+rcols+` FROM messages m, jsonb_populate_record(NULL::messages,
				to_jsonb(m) || jsonb_build_object('msg_id', gen_random_uuid(), 'responsible', NULL) || $3::jsonb) r
			WHERE m.tenant_id = $1 AND m.msg_id = $2
			RETURNING `+ret, tenant, seedMsg.MsgID, set).Scan(&got); err != nil {
			t.Fatalf("message %s: %v", set, err)
		}
		return got
	}
	toM004 := func() string { return copyMsg(`{"to_id": "m-004"}`, `COALESCE(responsible, '')`) }
	writes := []struct{ check, q string }{
		{"roster_agent_id_check", `INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ($1, 'box-a', 'm-004')`},
		{"issues_assignee_check", `INSERT INTO issues (tenant_id, number, title, task_id, created_by, updated_by, assignee)
			VALUES ($1, 9155, 'mistral', gen_random_uuid(), 'HUM-1', 'HUM-1', 'm-004@box-a')`},
		{"fleet_lanes_agent_id_check", `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, state, writer_box)
			VALUES ($1, 'f155', 'm-004', 'box-a', 'live', 'box-a')`},
		{"fleet_asks_from_agent_check", `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, writer_box)
			VALUES ($1, 'f155', gen_random_uuid()::text, 'task', 'm-004@box-a', 'open', 'box-a')`},
		{"fleet_asks_acked_by_check", `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, acked_by, writer_box)
			VALUES ($1, 'f155', gen_random_uuid()::text, 'task', 'c-005@box-a', 'acked', 'm-004@box-a', 'box-a')`},
		{"fleet_asks_closed_by_check", `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, closed_by, writer_box)
			VALUES ($1, 'f155', gen_random_uuid()::text, 'task', 'c-005@box-a', 'done', 'm-004@box-a', 'box-a')`},
		{"agent_id_aliases_new_id_check", `INSERT INTO agent_id_aliases (tenant_id, old_id, new_id, kind, box_id)
			VALUES ($1, 'GRK-155', 'm-004', 'grok', 'box-a')`},
		{"tenants_fleet_agent_kinds_off_check", `UPDATE tenants SET fleet_agent_kinds_off = ARRAY['mistral'] WHERE tenant_id = $1`},
	}

	exec("before", before)
	for _, w := range writes {
		if got := try(w.q, tenant); got != w.check {
			t.Errorf("before %s: an m- write broke %q, want it refused by %s", mistralKindFile, got, w.check)
		}
	}
	if got := toM004(); got != "" {
		t.Errorf("before %s: a message to m-004 got responsible %q, want none", mistralKindFile, got)
	}

	exec("after", after)
	for _, w := range writes {
		if got := try(w.q, tenant); got != "" {
			t.Errorf("after %s: the m- write for %s was refused by %s", mistralKindFile, w.check, got)
		}
	}
	if got := toM004(); got != "m-004@box-a" {
		t.Errorf("after %s: a message to m-004 got responsible %q, want m-004@box-a", mistralKindFile, got)
	}

	// The five-way split: grok's points move to mistral; the sum stays 100.
	split := `UPDATE tenants SET agent_split_claude = 40, agent_split_grok = $2, agent_split_agy = 5,
		agent_split_qwen = 0, agent_split_mistral = $3 WHERE tenant_id = $1`
	if got := try(split, tenant, 0, 55); got != "" {
		t.Errorf("split mistral 55 / grok 0 refused by %s", got)
	}
	for _, c := range []struct{ grok, mistral int }{{0, 54}, {50, 55}} {
		if got := try(split, tenant, c.grok, c.mistral); got != "tenants_agent_split_sum_check" {
			t.Errorf("split grok %d / mistral %d: broke %q, want tenants_agent_split_sum_check", c.grok, c.mistral, got)
		}
	}

	// An m- OD seat seats the workspace: a human post to ALL-0 needs a peer.
	exec("m-001 seat", `INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ($1, 'box-a', 'm-001')`, tenant)
	peer := copyMsg(`{"from_box": "box-wui", "from_id": "HUM-1", "to_id": "ALL-0", "needs_peer": false}`, `needs_peer::text`)
	if peer != "true" {
		t.Error("a human post to ALL-0 in a workspace seated by m-001 does not need a peer")
	}
}
