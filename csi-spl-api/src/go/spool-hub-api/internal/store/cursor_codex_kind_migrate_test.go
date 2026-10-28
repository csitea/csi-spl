package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0238 (spec 161 row B1): u-NNN (cursor) and o-NNN (codex) agents are
// rows in every table that names an agent. Postgres only.
//
// The database is migrated through 0238. "Before" is the same file with the
// letters narrowed back to [acgmq] and 'cursor', 'codex' left out of the
// kinds list, which are the 0155 texts; it is applied in a rolled-back
// transaction, then the real file on top of it. Each narrowed CHECK is added
// NOT VALID, as in the 0155 test: Postgres still enforces it on every INSERT
// and UPDATE, and it skips the rows other tests committed. The control: u-004
// seated in a second tenant inside the transaction, before the before text.
// It is never committed: the store groups share one database, and a committed
// u- row would fail the 0155 test's validating re-add of [acgmq].
//
// Per id u-004 and o-004, one write per CHECK (n=8), plus the trigger (n=1):
//   - refused before (n=8): roster, issues.assignee, fleet_lanes, the three
//     fleet_asks agents, agent_id_aliases.new_id and fleet_agent_kinds_off,
//     each 23514 on its own constraint; a message to the id gets no
//     responsible.
//   - stored after (n=8 + 1): the same writes; the message names
//     <id>@box-a responsible.
//
// Then x-004 (the test suite's negative letter) and d-004 (the letter the
// spec proposed and the owner did not pick, msg 4ae81b56) stay refused after
// by the seven agent-id CHECKs (n=7 each) and get no responsible (n=1 each).
const cursorCodexKindFile = "0238_cursor_codex_kinds.sql"

// cursorCodexKindCheck is the CHECK clause closing each ADD CONSTRAINT in 0238.
var cursorCodexKindCheck = regexp.MustCompile(`(?m)^(\s+CHECK \(.*\));$`)

// agentWrite is one write that names an agent id, refused by check when the
// grammar does not know the id's letter.
type agentWrite struct{ check, q string }

// cursorCodexWrites are the eight writes for id; n numbers its unique keys.
func cursorCodexWrites(id, kind string, n int) []agentWrite {
	issue := fmt.Sprintf("%d", 9238+n)
	return []agentWrite{
		{"roster_agent_id_check", `INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ($1, 'box-a', '` + id + `')`},
		{"issues_assignee_check", `INSERT INTO issues (tenant_id, number, title, task_id, created_by, updated_by, assignee)
			VALUES ($1, ` + issue + `, 'cursor codex', gen_random_uuid(), 'HUM-1', 'HUM-1', '` + id + `@box-a')`},
		{"fleet_lanes_agent_id_check", `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, state, writer_box)
			VALUES ($1, 'f238', '` + id + `', 'box-a', 'live', 'box-a')`},
		{"fleet_asks_from_agent_check", `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, writer_box)
			VALUES ($1, 'f238', gen_random_uuid()::text, 'task', '` + id + `@box-a', 'open', 'box-a')`},
		{"fleet_asks_acked_by_check", `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, acked_by, writer_box)
			VALUES ($1, 'f238', gen_random_uuid()::text, 'task', 'c-005@box-a', 'acked', '` + id + `@box-a', 'box-a')`},
		{"fleet_asks_closed_by_check", `INSERT INTO fleet_asks (tenant_id, fleet, ask_id, kind, from_agent, state, closed_by, writer_box)
			VALUES ($1, 'f238', gen_random_uuid()::text, 'task', 'c-005@box-a', 'done', '` + id + `@box-a', 'box-a')`},
		{"agent_id_aliases_new_id_check", `INSERT INTO agent_id_aliases (tenant_id, old_id, new_id, kind, box_id)
			VALUES ($1, 'GRK-` + issue + `', '` + id + `', 'grok', 'box-a')`},
		{"tenants_fleet_agent_kinds_off_check", `UPDATE tenants SET fleet_agent_kinds_off = ARRAY['` + kind + `'] WHERE tenant_id = $1`},
	}
}

// cursorCodexBefore returns 0238 narrowed back to the 0155 grammar and kinds.
func cursorCodexBefore(t *testing.T, after string) string {
	t.Helper()
	before := strings.NewReplacer("[acgmoqu]", "[acgmq]", ", 'cursor', 'codex'", "").Replace(after)
	if before == after || strings.Contains(before, "'mistral', 'cursor'") || strings.Contains(before, "[acgmoqu]") {
		t.Fatalf("%s: the before text did not narrow the grammar", cursorCodexKindFile)
	}
	// n=8: the eight CHECKs that name the letters or kinds.
	if n := len(cursorCodexKindCheck.FindAllString(before, -1)); n != 8 {
		t.Fatalf("%s: %d ADD CONSTRAINT ... CHECK clauses, want 8", cursorCodexKindFile, n)
	}
	return cursorCodexKindCheck.ReplaceAllString(before, "$1 NOT VALID;")
}

func TestCursorCodexKind0238(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), cursorCodexKindFile))
	if err != nil {
		t.Fatal(err)
	}
	after := string(raw)
	before := cursorCodexBefore(t, after)

	// The control's tenant and box (a c- seat makes the box); its u- row is
	// seated inside the tx below.
	other := newTenant(t, pg)
	now := time.Now().UTC()
	if err := pg.PutPin(ctx, other, "box-a", pubkey(), false, now, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetRoster(ctx, other, "box-a", []string{"c-006"}, now); err != nil {
		t.Fatal(err)
	}

	tenant := newTenant(t, pg)
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
	try := func(q string) string {
		t.Helper()
		sp, err := tx.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		_, err = sp.Exec(ctx, q, tenant)
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
	// responsibleFor inserts a copy of the seed message to id, every stored
	// column but the generated ones (search_tsv), and returns its responsible.
	var cols, rcols string
	if err := tx.QueryRow(ctx, `SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum),
			string_agg('r.' || quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
		WHERE attrelid = 'messages'::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''`).Scan(&cols, &rcols); err != nil {
		t.Fatal(err)
	}
	responsibleFor := func(id string) string {
		t.Helper()
		var got string
		if err := tx.QueryRow(ctx, `INSERT INTO messages (`+cols+`)
			SELECT `+rcols+` FROM messages m, jsonb_populate_record(NULL::messages,
				to_jsonb(m) || jsonb_build_object('msg_id', gen_random_uuid(), 'responsible', NULL, 'to_id', $3::text)) r
			WHERE m.tenant_id = $1 AND m.msg_id = $2
			RETURNING COALESCE(responsible, '')`, tenant, seedMsg.MsgID, id).Scan(&got); err != nil {
			t.Fatalf("message to %s: %v", id, err)
		}
		return got
	}
	kinds := []struct{ id, kind string }{{"u-004", "cursor"}, {"o-004", "codex"}}

	// Operator scope, as 0238 itself sets it: the row is in another tenant.
	exec("operator", `SELECT set_config('app.rls_scope', 'operator', true)`)
	exec("control", `INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ($1, 'box-a', 'u-004')`, other)
	exec("before", before)
	for n, k := range kinds {
		for _, w := range cursorCodexWrites(k.id, k.kind, n) {
			if got := try(w.q); got != w.check {
				t.Errorf("before %s: a %s write broke %q, want it refused by %s", cursorCodexKindFile, k.id, got, w.check)
			}
		}
		if got := responsibleFor(k.id); got != "" {
			t.Errorf("before %s: a message to %s got responsible %q, want none", cursorCodexKindFile, k.id, got)
		}
	}

	exec("after", after)
	for n, k := range kinds {
		for _, w := range cursorCodexWrites(k.id, k.kind, n) {
			if got := try(w.q); got != "" {
				t.Errorf("after %s: the %s write for %s was refused by %s", cursorCodexKindFile, k.id, w.check, got)
			}
		}
		if got := responsibleFor(k.id); got != k.id+"@box-a" {
			t.Errorf("after %s: a message to %s got responsible %q, want %s@box-a", cursorCodexKindFile, k.id, got, k.id)
		}
	}

	// x-004 and d-004 stay refused: only u and o joined the grammar. The
	// kinds list is not an agent id, so its write is left out here.
	for n, id := range []string{"x-004", "d-004"} {
		writes := cursorCodexWrites(id, "", 10+n)
		for _, w := range writes[:len(writes)-1] {
			if got := try(w.q); got != w.check {
				t.Errorf("after %s: a %s write broke %q, want it refused by %s", cursorCodexKindFile, id, got, w.check)
			}
		}
		if got := responsibleFor(id); got != "" {
			t.Errorf("after %s: a message to %s got responsible %q, want none", cursorCodexKindFile, id, got)
		}
	}
}
