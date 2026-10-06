package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// TestSearchMessagesSkipsUnsignedToast pins rdb 0135 (t1 6d5bd334: prd 503
// search_budget for "Example refactoring prompt (round 4)"). Under FORCE RLS
// the message section scans the tenant and evaluates search_tsv @@ per row;
// on long bodies that is a TOAST read per row (prd: 45 748 buffers for 18 801
// rows, 4.1 s cold). The lexeme signature in the heap row lets a row that
// cannot match skip it. The same scan with every signature NULL is the plan
// before 0135: signed it must read under a third of those buffers (scratch
// pg 16: 1 022 vs 8 168 for 2 001 rows). The rows found never change.
func TestSearchMessagesSkipsUnsignedToast(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx, now := context.Background(), time.Now().UTC()
	tid := newTenant(t, pg)
	const rows = 1000
	// ~4 KB bodies of 120 distinct incompressible words: search_tsv is
	// TOASTed, like a long markdown post's. Every second one also carries
	// four of the query's five words (not "refactoring"), as common words do
	// on prd: a per-word check lets those rows through, the all-words one not.
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id,
				kind, body, files, msg, env_sig, env, received_at, expires_at, channel)
			SELECT $1, gen_random_uuid(), gen_random_uuid(), $2::timestamptz - i * interval '1 minute', 'box-a', 'GRK-03',
				'box-b', 'CLE-07', 'note',
				CASE WHEN i % 2 = 0 THEN 'Example prompt round 4 ' ELSE '' END
					|| (SELECT string_agg(md5($1 || i || '-' || g), ' ') FROM generate_series(1, 120) g),
				'[]', '{"v":1}', 'sig', '\x00', $2::timestamptz - i * interval '1 minute', $2::timestamptz + interval '30 days', 'lobby'
			FROM generate_series(1, $3::int) i`, tid, now, rows)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	target := msgFor(tid, uuid4(), "box-b", now.Add(-time.Hour), now.Add(-time.Hour), "e")
	target.Kind, target.Channel = "note", "lobby"
	target.Body = "## Example refactoring prompt (round 4)\n\nKeep the module tests green, one lane per file."
	if _, err := pg.InsertMessage(ctx, target); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages`); err != nil {
		t.Fatal(err)
	}

	q, err := search.Parse("Example refactoring prompt (round 4)", now)
	if err != nil {
		t.Fatal(err)
	}
	sq := SearchQuery{Q: q, Now: now, Limit: 7, Budget: 2 * time.Second}
	found := func(stage string) {
		t.Helper()
		got, err := pg.SearchMessages(ctx, tid, sq)
		if err != nil {
			t.Fatalf("%s: %v", stage, err)
		}
		if len(got) != 1 || got[0].MsgID != target.MsgID {
			t.Fatalf("%s: want only %s, got %d rows %+v", stage, target.MsgID, len(got), got)
		}
	}
	found("signed")

	if !pg.hasSearchSig(ctx) {
		t.Fatal("rdb 0135 search_sig not found by the probe")
	}
	sql, args := searchMessagesSQL(tid, sq, true)
	signed := explainBuffers(t, pg, tid, sql, args)

	// A row the sweep has not signed yet is still found.
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE messages SET search_sig = NULL WHERE tenant_id = $1`, tid)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	found("unsigned")
	unsigned := explainBuffers(t, pg, tid, sql, args)
	t.Logf("message search over %d rows: %d buffers signed, %d unsigned", rows+1, signed, unsigned)
	if signed*3 > unsigned {
		t.Fatalf("message search read %d buffers signed vs %d unsigned: the TOASTed search_tsv is read for rows the signature rules out", signed, unsigned)
	}
	if err := pg.backfillSearchSig(ctx); err != nil {
		t.Fatal(err)
	}
	var left, shortSigned int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE search_sig IS NULL AND length(body) >= 1024),
				count(*) FILTER (WHERE search_sig IS NOT NULL AND length(body) < 1024)
			FROM messages WHERE tenant_id = $1`, tid).Scan(&left, &shortSigned)
	}); err != nil {
		t.Fatal(err)
	}
	if left != 0 || shortSigned != 0 {
		t.Fatalf("backfill left %d long rows unsigned and signed %d short ones", left, shortSigned)
	}
	found("backfilled")
}

// TestSearchSigOnlyWhenProbed: before rdb 0135 reaches a database the hub
// must not name search_sig (a 500 on every search); after it, every
// signable text term is guarded, a prefix term is not, and the terms the
// query ANDs share one all-words check.
func TestSearchSigOnlyWhenProbed(t *testing.T) {
	q, err := search.Parse("Example refactoring deplo*", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	sq := SearchQuery{Q: q, Now: time.Now(), Limit: 7}
	if sql, _ := searchMessagesSQL("t1", sq, false); strings.Contains(sql, "search_sig") {
		t.Fatalf("probe off, search_sig named:\n%s", sql)
	}
	sql, _ := searchMessagesSQL("t1", sq, true)
	// 2 guarded terms (not the prefix one) + 1 all-words check of those two.
	if n := strings.Count(sql, "m.search_sig IS NULL"); n != 3 {
		t.Fatalf("probe on: want 2 guarded terms and 1 all-words check, got %d:\n%s", n, sql)
	}
}

// explainBuffers is the shared buffers (hit + read) of sql's executed plan in
// the tenant scope.
func explainBuffers(t *testing.T, pg *Postgres, tenant, sql string, args []any) int {
	t.Helper()
	ctx := context.Background()
	var raw []byte
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) `+sql, args...).Scan(&raw)
	}); err != nil {
		t.Fatal(err)
	}
	var doc []struct {
		Plan struct {
			Hit  int `json:"Shared Hit Blocks"`
			Read int `json:"Shared Read Blocks"`
		} `json:"Plan"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil || len(doc) == 0 {
		t.Fatalf("explain: %v %s", err, raw)
	}
	return doc[0].Plan.Hit + doc[0].Plan.Read
}
