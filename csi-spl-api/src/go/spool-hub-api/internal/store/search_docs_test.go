package store

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// Spec 100 section 14 (SPL-3337) on Postgres: the doc section's statement
// and the index entries of rdb 0226. A doc's words are found, its title finds
// its root, an edited section is found by its new words and no longer by
// its old ones, and the statement never reads another workspace's
// documents nor the system tenant's repository docs, which RLS lets every
// scope SELECT (rdb 0191). CONTROL (TestSearchDocsTenantPin): the same
// statement without its tenant pin hands the system doc back.
//
//	go test ./internal/store -run 'SearchDocs|DocSearchIndex' -v   (SPOOL_TEST_PG_DSN)

// docSeed is one document of tenant with one section holding body; it
// returns the doc, its root and the section.
func docSeed(t *testing.T, pg *Postgres, tenant, title, heading, body string) (string, string, string) {
	t.Helper()
	ctx := context.Background()
	doc, root, err := pg.DocCreateIn(ctx, tenant, "", title, "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	res, err := pg.DocItemAdd(ctx, tenant, DocItemAddReq{DocID: doc, Anchor: root, Where: DocChild, Title: heading, Body: body, Actor: "HUM-1"})
	if err != nil {
		t.Fatal(err)
	}
	return doc, root, res.ItemID
}

// docHits is SearchDocs of q in tenant as "doc:item" ids, in order.
func docHits(t *testing.T, pg *Postgres, tenant, q string, limit int) []string {
	t.Helper()
	rows := docRows(t, pg, tenant, q, limit, time.Time{}, "")
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.DocID + ":" + r.ItemID
	}
	return out
}

func docRows(t *testing.T, pg *Postgres, tenant, q string, limit int, afterAt time.Time, afterID string) []SearchDocRow {
	t.Helper()
	pq, err := search.Parse(q, time.Now())
	if err != nil {
		t.Fatalf("%q: %v", q, err)
	}
	rows, err := pg.SearchDocs(context.Background(), tenant, SearchQuery{Q: pq, Now: time.Now(), Viewer: "HUM-1",
		Limit: limit, Budget: 5 * time.Second, AfterAt: afterAt, AfterID: afterID})
	if err != nil {
		t.Fatalf("%q: %v", q, err)
	}
	return rows
}

func TestSearchDocs(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	ta, tb := newTenant(t, pg), newTenant(t, pg)
	w := "zq" + strings.ReplaceAll(uuid4()[:8], "-", "") // a word in no other row of the run
	doc, root, item := docSeed(t, pg, ta, "Runbook ttl"+w, "Deploy steps", "rotate the "+w+" keys, then café")
	docB, _, itemB := docSeed(t, pg, tb, "Other workspace", "Steps", "the "+w+" keys of B")
	docS, _, itemS := docSeed(t, pg, SystemTenant, "Repo guide", "Overview", "the "+w+" repo text")
	hit, hitB, hitS := doc+":"+item, docB+":"+itemB, docS+":"+itemS

	if got := docHits(t, pg, ta, w, 10); !slices.Equal(got, []string{hit}) {
		t.Fatalf("%q in A = %v, want only A's section %s (B's %s and the system doc %s never)", w, got, hit, hitB, hitS)
	}
	if got := docHits(t, pg, tb, w, 10); !slices.Equal(got, []string{hitB}) {
		t.Fatalf("%q in B = %v, want only %s", w, got, hitB)
	}
	// the title finds the document's root section; title: too; name: the root
	// only. A plain word is a prefix (search-v1 grammar 1.1), so the title
	// word does not start with w.
	for _, q := range []string{"ttl" + w, "title:ttl" + w, "name:runbook"} {
		rows := docRows(t, pg, ta, q, 10, time.Time{}, "")
		if len(rows) != 1 || rows[0].ItemID != root || !rows[0].Top || rows[0].DocTitle != "Runbook ttl"+w {
			t.Fatalf("%q = %+v, want the root %s of %s, marked top", q, rows, root, doc)
		}
	}
	if got := docHits(t, pg, ta, "title:deploy", 10); !slices.Equal(got, []string{hit}) {
		t.Fatalf("title:deploy = %v, want the section %s", got, hit)
	}
	// folded and prefix as a message search: spool_search (rdb 0048)
	for _, q := range []string{"cafe", "rota*", `"rotate the"`, w + " keys", w + " -nothere"} {
		if got := docHits(t, pg, ta, q, 10); !slices.Equal(got, []string{hit}) {
			t.Fatalf("%q = %v, want %s", q, got, hit)
		}
	}
	if got := docHits(t, pg, ta, w+" -keys", 10); len(got) != 0 {
		t.Fatalf("%s -keys = %v, want none", w, got)
	}
	if got := docHits(t, pg, ta, "after:1d "+w, 10); !slices.Equal(got, []string{hit}) {
		t.Fatalf("after:1d = %v", got)
	}
	if got := docHits(t, pg, ta, "before:1d "+w, 10); len(got) != 0 {
		t.Fatalf("before:1d = %v, want none", got)
	}

	// An edit reaches the index entry in its own statement (rdb 0226: STORED).
	nw := w + "new"
	if _, err := pg.DocItemUpdateField(ctx, ta, doc, item, "body", "the "+nw+" text", 1); err != nil {
		t.Fatal(err)
	}
	if got := docHits(t, pg, ta, nw, 10); !slices.Equal(got, []string{hit}) {
		t.Fatalf("edited word %q = %v, want %s", nw, got, hit)
	}
	if got := docHits(t, pg, ta, "rotate", 10); len(got) != 0 {
		t.Fatalf("the old word still finds the edited section: %v", got)
	}
	// A deleted document is gone.
	if _, err := pg.DocDelete(ctx, tb, docB, 0); err != nil {
		t.Fatal(err)
	}
	if got := docHits(t, pg, tb, w, 10); len(got) != 0 {
		t.Fatalf("a deleted doc is still found: %v", got)
	}
}

// Paging: last edited first, keyset by (updated_at, item id), no row twice
// and none skipped.
func TestSearchDocsPaging(t *testing.T) {
	pg := pgOnly(t)
	ta := newTenant(t, pg)
	w := "zq" + strings.ReplaceAll(uuid4()[:8], "-", "")
	want := map[string]bool{}
	for i := 0; i < 5; i++ {
		d, _, it := docSeed(t, pg, ta, "Doc", "Part", "the "+w+" part")
		want[d+":"+it] = true
	}
	var seen []string
	var at time.Time
	id := ""
	for page := 0; page < 10; page++ {
		rows := docRows(t, pg, ta, w, 3, at, id) // limit 3 = a page of 2 plus the look-ahead row
		if len(rows) > 2 {
			rows = rows[:2]
		}
		for _, r := range rows {
			seen = append(seen, r.DocID+":"+r.ItemID)
			at, id = r.UpdatedAt, r.ItemID
		}
		if len(rows) < 2 {
			break
		}
	}
	if len(seen) != 5 {
		t.Fatalf("paged %d rows %v, want 5", len(seen), seen)
	}
	for _, s := range seen {
		if !want[s] {
			t.Fatalf("paged a row not seeded: %s", s)
		}
		delete(want, s)
	}
}

// Before rdb 0226 reaches a database the statement computes the entries
// itself: the answer is the same either way.
func TestSearchDocsWithoutStoredEntries(t *testing.T) {
	pg := pgOnly(t)
	pg.docTSV.check = func(context.Context) (bool, error) { return false, nil }
	ta := newTenant(t, pg)
	w := "zq" + strings.ReplaceAll(uuid4()[:8], "-", "")
	doc, root, item := docSeed(t, pg, ta, "Runbook ttl"+w, "Deploy steps", "rotate the "+w+" keys")
	if got := docHits(t, pg, ta, w, 10); !slices.Equal(got, []string{doc + ":" + item}) {
		t.Fatalf("computed entries: %q = %v", w, got)
	}
	if got := docHits(t, pg, ta, "ttl"+w, 10); !slices.Equal(got, []string{doc + ":" + root}) {
		t.Fatalf("computed entries: title = %v", got)
	}
	sql, _ := searchDocsSQL(ta, SearchQuery{Q: mustParse(t, w), Limit: 2}, false)
	if strings.Contains(sql, "search_tsv") {
		t.Fatalf("the pre-0226 statement reads search_tsv: %s", sql)
	}
	hits, err := pg.DocSearch(context.Background(), ta, "", w, 10)
	if err != nil || len(hits) != 1 || hits[0].ItemID != item {
		t.Fatalf("doctree search without stored entries: %v %v", hits, err)
	}
}

func mustParse(t *testing.T, q string) *search.Query {
	t.Helper()
	pq, err := search.Parse(q, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return pq
}

// CONTROL for the tenant pin: RLS alone lets every scope read the system
// tenant's docs (rdb 0191), so the statement's own i.tenant_id = $1 is what
// keeps them out. With the pin taken off (the planted statement below) the
// system doc comes back; with it, it does not.
func TestSearchDocsTenantPin(t *testing.T) {
	pg := pgOnly(t)
	ta := newTenant(t, pg)
	w := "zq" + strings.ReplaceAll(uuid4()[:8], "-", "")
	docS, _, itemS := docSeed(t, pg, SystemTenant, "Repo guide", "Overview", "the "+w+" repo text")
	sql, args := searchDocsSQL(ta, SearchQuery{Q: mustParse(t, w), Limit: 10}, true)
	planted := strings.Replace(sql, "WHERE i.tenant_id = $1 AND d.tenant_id = $1 AND", "WHERE $1::text IS NOT NULL AND", 1)
	if planted == sql {
		t.Fatal("the plant did not apply: the statement's tenant pin moved")
	}
	ids := func(stmt string) []string {
		var out []string
		err := pg.queryTenant(context.Background(), ta, stmt, args, func(r pgx.Rows) error {
			var row SearchDocRow
			if err := r.Scan(&row.DocID, &row.ItemID, &row.Top, &row.DocTitle, &row.Title, &row.Body, &row.UpdatedAt); err != nil {
				return err
			}
			out = append(out, row.DocID+":"+row.ItemID)
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	if got := ids(planted); !slices.Contains(got, docS+":"+itemS) {
		t.Fatalf("CONTROL: without the tenant pin the system doc should leak through RLS, got %v (the control is vacuous)", got)
	}
	if got := ids(sql); len(got) != 0 {
		t.Fatalf("with the pin, tenant %s reads %v", ta, got)
	}
}

// rdb 0226 is the backfill: rows written before the column existed get their
// entries when the file runs. Proven in a rolled-back transaction as the
// migrating login: drop the columns, write a document, run the file again.
func TestDocSearchIndexBackfill(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	ta := newTenant(t, pg)
	file, err := os.ReadFile(filepath.Join(sqlDir(t), "0226_workspace_doc_search.sql"))
	if err != nil {
		t.Fatal(err)
	}
	w := "zq" + strings.ReplaceAll(uuid4()[:8], "-", "")
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	steps := []string{
		`SELECT set_config('app.rls_scope', 'operator', true)`,
		`ALTER TABLE workspace_doc_item DROP COLUMN search_tsv`,
		`ALTER TABLE workspace_doc DROP COLUMN search_tsv`,
		`INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('00000000-0000-4000-8000-0000000000d1', '` + ta + `', 'Old ` + w + `')`,
		`INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, body) VALUES ('` + ta + `', '00000000-0000-4000-8000-0000000000d1', NULL, 1, 'old ` + w + ` body')`,
		`SET CONSTRAINTS ALL IMMEDIATE`, // the doc's deferred checks fire now: an ALTER refuses pending trigger events
		string(file),
	}
	for _, s := range steps {
		if _, err := tx.Exec(ctx, s); err != nil {
			t.Fatalf("%.80s: %v", s, err)
		}
	}
	var item, doc bool
	if err := tx.QueryRow(ctx, `SELECT i.search_tsv @@ plainto_tsquery('spool_search', $1), d.search_tsv @@ plainto_tsquery('spool_search', $1)
		FROM workspace_doc_item i JOIN workspace_doc d ON d.id = i.doc_id WHERE d.id = '00000000-0000-4000-8000-0000000000d1'`, w).Scan(&item, &doc); err != nil {
		t.Fatal(err)
	}
	if !item || !doc {
		t.Fatalf("the backfill missed an entry: item %v, doc %v", item, doc)
	}
	if _, err := tx.Exec(ctx, `SET CONSTRAINTS ALL IMMEDIATE`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, string(file)); err != nil { // idempotent: a second run changes nothing
		t.Fatalf("second run: %v", err)
	}
}
