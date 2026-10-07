package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

func sq(t *testing.T, q string, now time.Time) SearchQuery {
	t.Helper()
	p, err := search.Parse(q, now)
	if err != nil {
		t.Fatalf("parse %q: %v", q, err)
	}
	return SearchQuery{Q: p, Now: now}
}

func msgIDs(rs []SearchMsgRow) []string {
	var out []string
	for _, r := range rs {
		out = append(out, r.MsgID)
	}
	return out
}

// TestSearch is the search contract suite (search-v1, FR-029 – FR-032) on
// memory and, with SPOOL_TEST_PG_DSN, Postgres — including the CONTROLS:
// another tenant's rows never appear, DMs stay private, SQL-shaped text is
// text, expired rows are gone, and a search writes nothing.
func TestSearch(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			se := s.(Searcher)
			ta, tb := newTenant(t, s), newTenant(t, s)
			tk1, tk2, dm, dmOther := uuid4(), uuid4(), uuid4(), uuid4()

			mk := func(tenant, task, body string, ago time.Duration) Message {
				m := msgFor(tenant, task, "box-b", now.Add(-ago), now.Add(-ago), "env-"+uuid4())
				m.Body, m.Channel = body, ChannelTasks
				return m
			}
			m1 := mk(ta, tk1, "Please deploy the hub\n```sh\nmake do-provision\n```", 5*time.Minute)
			m1.Files = []byte(`[{"mode":"blob","kind":"file","file_id":"` + fmt.Sprintf("%064x", 1) + `","name":"Q3 Report.pdf","bytes":2097152,"sha256":"x"},{"mode":"path","kind":"dir","path":"/srv/logs","name":"logs"}]`)
			m2 := mk(ta, tk1, "deploy done; the hub is green", 4*time.Minute)
			m2.Kind, m2.FromID, m2.FromBox, m2.ToID, m2.ToBox = "result", "CLE-07", "box-b", "GRK-03", "box-a"
			m3 := mk(ta, tk2, "Migration plan for 0020", 3*time.Minute)
			m3.Channel, m3.ParentTaskID = ChannelAlerts, tk1
			d1 := mk(ta, dm, "secret deploy key rotation", 2*time.Minute) // DM of HUM-1
			d1.Channel, d1.FromID, d1.FromBox, d1.ToID = "", "HUM-1", "box-wui", "CLE-07"
			d2 := mk(ta, dmOther, "private deploy chatter", time.Minute) // DM HUM-1 is not party of
			d2.Channel, d2.FromID, d2.ToID = "", "HUM-2", "CLE-07"
			gone := mk(ta, uuid4(), "deploy long ago", time.Hour)
			gone.ExpiresAt = now.Add(-time.Second)
			other := mk(tb, uuid4(), "deploy the hub in tenant B", 30*time.Second) // CONTROL: other tenant
			other.Files = m1.Files
			for _, m := range []Message{m1, m2, m3, d1, d2, gone, other} {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.Enqueue(ctx, ta, m1.MsgID, "box-b", now, now.Add(time.Hour), 1000); err != nil {
				t.Fatal(err)
			}

			// messages: FTS, newest first, retention, tenant scope
			rs, err := se.SearchMessages(ctx, ta, sq(t, "deploy", now))
			if err != nil {
				t.Fatal(err)
			}
			if got, want := msgIDs(rs), []string{d2.MsgID, d1.MsgID, m2.MsgID, m1.MsgID}; fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("deploy (no viewer): %v, want %v", got, want)
			}
			r := rs[3]
			if r.Channel != "tasks" || r.Files != 2 || r.FromID != "GRK-03" || !r.TS.Equal(m1.TS) || r.Body != m1.Body {
				t.Fatalf("row fields: %+v", r)
			}
			// CONTROL: DM privacy for a member session
			q := sq(t, "deploy", now)
			q.Viewer = "HUM-1"
			if rs, _ := se.SearchMessages(ctx, ta, q); fmt.Sprint(msgIDs(rs)) != fmt.Sprint([]string{d1.MsgID, m2.MsgID, m1.MsgID}) {
				t.Fatalf("viewer HUM-1 must not see HUM-2's DM: %v", msgIDs(rs))
			}
			// CONTROL: tenant B's text never appears under A, and vice versa
			if rs, _ := se.SearchMessages(ctx, tb, sq(t, "deploy", now)); len(rs) != 1 || rs[0].MsgID != other.MsgID {
				t.Fatalf("tenant B: %v", msgIDs(rs))
			}
			// CONTROL: SQL-shaped queries are text
			for _, bad := range []string{`'; DROP TABLE messages; --`, `" OR 1=1 --`, `a') OR ('1'='1`, `$1 ; SELECT pg_sleep(5)`, `\x00 & | ! <->`} {
				p, err := search.Parse(bad, now)
				if err != nil {
					var pe *search.Error
					if errors.As(err, &pe) {
						continue // a 400 is as harmless as a miss
					}
					t.Fatal(err)
				}
				if rs, err := se.SearchMessages(ctx, ta, SearchQuery{Q: p, Now: now}); err != nil || len(rs) != 0 {
					t.Fatalf("%q: %v %v", bad, err, msgIDs(rs))
				}
			}
			// prefix (search-v1 §2.2, owner 2026-09-26): "deplo*" == "deploy" here
			if rs, err := se.SearchMessages(ctx, ta, sq(t, "deplo*", now)); err != nil || fmt.Sprint(msgIDs(rs)) != fmt.Sprint([]string{d2.MsgID, d1.MsgID, m2.MsgID, m1.MsgID}) {
				t.Fatalf("deplo*: %v %v", err, msgIDs(rs))
			}
			if rs, err := se.SearchMessages(ctx, ta, sq(t, "migrat*", now)); err != nil || fmt.Sprint(msgIDs(rs)) != fmt.Sprint([]string{m3.MsgID}) {
				t.Fatalf("migrat*: %v %v", err, msgIDs(rs))
			}
			// only the LAST word is a prefix: "hub gre*" finds m2 (hub ... green)
			if rs, err := se.SearchMessages(ctx, ta, sq(t, "hub gre*", now)); err != nil || fmt.Sprint(msgIDs(rs)) != fmt.Sprint([]string{m2.MsgID}) {
				t.Fatalf("hub gre*: %v %v", err, msgIDs(rs))
			}
			// as you type (1.1): the last bare word is a prefix
			if rs, err := se.SearchMessages(ctx, ta, sq(t, "deplo", now)); err != nil || len(rs) != 4 {
				t.Fatalf("deplo (being typed): %v %v", err, msgIDs(rs))
			}
			// CONTROL: a fragment with a space typed after it is not a word
			if rs, _ := se.SearchMessages(ctx, ta, sq(t, "deplo ", now)); len(rs) != 0 {
				t.Fatalf("'deplo ' must match nothing: %v", msgIDs(rs))
			}
			// CONTROL: the ':*' path stays injection-proof
			for _, bad := range []string{`o'rei*`, `a:*|b*`, `'; DROP TABLE messages; --*`, `!!!*`, `&*`} {
				p, err := search.Parse(bad, now)
				if err != nil {
					continue
				}
				if _, err := se.SearchMessages(ctx, ta, SearchQuery{Q: p, Now: now}); err != nil {
					t.Fatalf("%q: %v", bad, err)
				}
			}
			if rs, _ := se.SearchMessages(ctx, ta, sq(t, "deploy", now)); len(rs) != 4 {
				t.Fatal("messages table must be intact after SQL-shaped queries")
			}
			// operators on Postgres agree with the table-driven grammar suite
			cases := map[string][]string{
				`"deploy the hub"`:               {m1.MsgID},
				"deploy -from:GRK-03":            {d2.MsgID, d1.MsgID, m2.MsgID},
				"from:CLE-07@box-b":              {m2.MsgID},
				"to:box-a":                       {m2.MsgID},
				"box:box-wui":                    {d1.MsgID},
				"in:#tasks":                      {m2.MsgID, m1.MsgID},
				"in:dm deploy":                   {d2.MsgID, d1.MsgID},
				"-in:#tasks -in:dm":              {m3.MsgID},
				"is:result OR is:note":           {m2.MsgID},
				"is:result":                      {m2.MsgID},
				"has:file":                       {m1.MsgID},
				"has:code":                       {m1.MsgID},
				"topic:" + tk2:                   {m3.MsgID},
				"after:1h":                       {d2.MsgID, d1.MsgID, m3.MsgID, m2.MsgID, m1.MsgID},
				"before:1h":                      {},
				"on:" + now.Format("2006-01-02"): {d2.MsgID, d1.MsgID, m3.MsgID, m2.MsgID, m1.MsgID},
				"(migration OR secret) -hub":     {d1.MsgID, m3.MsgID},
				"hub green":                      {m2.MsgID},
				"HUB":                            {m2.MsgID, m1.MsgID},
			}
			if now.Add(-5*time.Minute).Format("2006-01-02") != now.Format("2006-01-02") {
				delete(cases, "on:"+now.Format("2006-01-02")) // straddles UTC midnight
			}
			for qs, want := range cases {
				rs, err := se.SearchMessages(ctx, ta, sq(t, qs, now))
				if err != nil {
					t.Fatalf("%q: %v", qs, err)
				}
				if fmt.Sprint(msgIDs(rs)) != fmt.Sprint(want) && !(len(rs) == 0 && len(want) == 0) {
					t.Errorf("%q: %v, want %v", qs, msgIDs(rs), want)
				}
			}
			// keyset paging
			q = sq(t, "deploy", now)
			q.Limit = 2
			p1, _ := se.SearchMessages(ctx, ta, q)
			q.AfterAt, q.AfterID = p1[1].ReceivedAt, p1[1].MsgID
			p2, _ := se.SearchMessages(ctx, ta, q)
			if len(p1) != 2 || fmt.Sprint(msgIDs(p2)) != fmt.Sprint([]string{m2.MsgID, m1.MsgID}) {
				t.Fatalf("pages: %v %v", msgIDs(p1), msgIDs(p2))
			}
			// relevance: more hits rank first, offset paging
			q = sq(t, "deploy hub", now)
			q.Relevance = true
			if rs, _ := se.SearchMessages(ctx, ta, q); len(rs) != 2 {
				t.Fatalf("relevance: %v", msgIDs(rs))
			}
			q.Offset = 1
			if rs, _ := se.SearchMessages(ctx, ta, q); len(rs) != 1 {
				t.Fatalf("relevance offset: %v", msgIDs(rs))
			}

			// files: one row per attachment, name / ext / size, path never leaks
			fs, err := se.SearchFiles(ctx, ta, sq(t, "type:file", now))
			if err != nil || len(fs) != 2 {
				t.Fatalf("files: %v %+v", err, fs)
			}
			if f := fs[0]; f.Name != "Q3 Report.pdf" || f.Idx != 1 || f.Mode != "blob" || len(f.FileID) != 64 || !f.HasBytes || f.Bytes != 2097152 || f.Msg.MsgID != m1.MsgID {
				t.Fatalf("file 1: %+v", f)
			}
			if f := fs[1]; f.Name != "logs" || f.Kind != "dir" || f.FileID != "" || f.HasBytes {
				t.Fatalf("file 2: %+v", f)
			}
			for qs, n := range map[string]int{`"q3 report"`: 1, "ext:pdf": 1, "ext:PDF": 1, "larger:1M": 1, "larger:2M": 0,
				"smaller:3M": 1, "name:log": 1, "filename:REPORT from:GRK-03": 1, "report in:dm": 0, "-ext:pdf": 1} {
				fq := sq(t, qs, now)
				if rs, err := se.SearchFiles(ctx, ta, fq); err != nil || len(rs) != n {
					t.Errorf("files %q: %v %d, want %d", qs, err, len(rs), n)
				}
			}
			fq := sq(t, "type:file", now)
			fq.Limit, fq.AfterAt, fq.AfterID, fq.AfterIdx = 5, fs[0].Msg.ReceivedAt, fs[0].Msg.MsgID, 1
			if rs, _ := se.SearchFiles(ctx, ta, fq); len(rs) != 1 || rs[0].Idx != 2 {
				t.Fatalf("files keyset: %+v", rs)
			}
			if rs, _ := se.SearchFiles(ctx, tb, sq(t, "report", now)); len(rs) != 1 || rs[0].Msg.MsgID != other.MsgID {
				t.Fatalf("CONTROL tenant B files: %+v", rs)
			}

			// topics: title FTS, participants, root, DM privacy
			th, err := se.SearchTopics(ctx, ta, sq(t, "title:migration", now))
			if err != nil || len(th) != 1 || th[0].TaskID != tk2 || th[0].Title != "Migration plan for 0020" || th[0].Parent != tk1 || th[0].Count != 1 {
				t.Fatalf("title: %v %+v", err, th)
			}
			if th, _ := se.SearchTopics(ctx, ta, sq(t, "please", now)); len(th) != 1 || th[0].TaskID != tk1 || th[0].Count != 2 {
				t.Fatalf("topic text: %+v", th)
			}
			if th, _ := se.SearchTopics(ctx, ta, sq(t, "is:root from:CLE-07", now)); len(th) != 1 || th[0].TaskID != tk1 {
				t.Fatalf("root topics with a message from CLE-07: %+v", th)
			}
			tq := sq(t, "type:topic in:dm", now)
			tq.Viewer = "HUM-1"
			if th, _ := se.SearchTopics(ctx, ta, tq); len(th) != 1 || th[0].TaskID != dm {
				t.Fatalf("CONTROL topic DM privacy: %+v", th)
			}

			// humans: names, never email; tenant scoped
			if h, ok := s.(Humans); ok {
				id, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("s-"), Email: "ops@example.com", Name: "Ops Person"}, ta, AdmitPolicy{BootstrapOwner: true}, now)
				if err != nil {
					t.Fatal(err)
				}
				hs, err := se.TenantHumans(ctx, ta)
				if err != nil || len(hs) != 1 || hs[0].HumanID != id || hs[0].DisplayName != "Ops Person" {
					t.Fatalf("humans: %v %+v", err, hs)
				}
				if hs, _ := se.TenantHumans(ctx, tb); len(hs) != 0 {
					t.Fatalf("CONTROL humans of B: %+v", hs)
				}
			}

			// a search writes nothing (FR-019)
			if st, _ := s.DeliveryState(ctx, ta, m1.MsgID, "box-b"); st != "queued" {
				t.Fatalf("search changed a delivery: %s", st)
			}
		})
	}
}

// TestSearchP95 seeds a corpus and measures search latency on Postgres
// (search-v1 §7, T053). SPOOL_TEST_SEARCH_N sets the corpus size per tenant:
// the default 2,000 is the CI smoke (a shared runner under -race with every
// Postgres suite in parallel); the recorded measurement is N=20000.
func TestSearchP95(t *testing.T) {
	d := drivers(t)
	s, ok := d["postgres"]
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	pg := s.(*Postgres)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	n := 2000
	if v := os.Getenv("SPOOL_TEST_SEARCH_N"); v != "" {
		fmt.Sscan(v, &n) //nolint:errcheck
	}
	ta, tb := newTenant(t, s), newTenant(t, s)
	words := []string{"deploy", "hub", "migration", "release", "rollback", "tenant", "billing", "search", "index", "cursor",
		"topic", "channel", "robot", "report", "latency", "budget", "alert", "disk", "network", "certificate"}
	// bulk seed through COPY-like multi-row inserts, as the owner role (RLS: tenant scope per batch)
	for _, tid := range []string{ta, tb} {
		for base := 0; base < n; base += 1000 {
			top := min(base+999, n-1)
			err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
					kind, body, files, msg, env_sig, env, received_at, expires_at)
					SELECT $1, gen_random_uuid(), gen_random_uuid(), (ARRAY['tasks','alerts','lobby',NULL])[1 + g % 4], $2::timestamptz - g * interval '1 second',
						'box-' || (g % 7), (ARRAY['CLE-07','GRK-03','HUM-1'])[1 + g % 3], 'box-b', 'CLE-07',
						(ARRAY['task','note','result','reject'])[1 + g % 4],
						(SELECT string_agg(w, ' ') FROM (SELECT ($3::text[])[1 + ((g * 7 + k * 13) % 20)] AS w FROM generate_series(1, 12) k) z),
						CASE WHEN g % 10 = 0 THEN '[{"mode":"blob","kind":"file","name":"report.pdf","bytes":1048577}]'::jsonb ELSE '[]'::jsonb END,
						'{}'::jsonb, 'sig', '\x00'::bytea, $2::timestamptz - g * interval '1 second', $2::timestamptz + interval '30 days'
					FROM generate_series($4::int, $5::int) g`, tid, now, words, base, top)
				return err
			})
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	// a real table has statistics; a freshly bulk-loaded one does not yet
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages`); err != nil {
		t.Fatal(err)
	}
	queries := []string{"deploy", `"deploy hub"`, "deploy -rollback from:CLE-07", "in:#tasks is:note migration",
		"type:file ext:pdf", "has:file after:7d", "title:release", "(latency OR budget) -in:dm", "box:box-3 certificate", "zzz-no-hit"}
	// CI records the numbers and fails only on a generous regression ceiling
	// (a shared runner is no latency gate); SPOOL_TEST_SEARCH_STRICT=1 holds
	// the contract's 2 s budget (the local hub-pg bench).
	budget, ceiling := 30*time.Second, 10*time.Second
	if os.Getenv("SPOOL_TEST_SEARCH_STRICT") == "1" {
		budget, ceiling = 2*time.Second, 2*time.Second
	}
	var lat []time.Duration
	byType := map[search.Type][]time.Duration{}
	for round := -1; round < 5; round++ { // round -1 warms the cache, not measured
		for _, qs := range queries {
			p, err := search.Parse(qs, now)
			if err != nil {
				t.Fatal(err)
			}
			q := SearchQuery{Q: p, Now: now, Limit: 21, Viewer: "HUM-1", Budget: budget}
			for _, ty := range p.Types {
				start := time.Now()
				switch ty {
				case search.TypeMessage:
					_, err = pg.SearchMessages(ctx, ta, q)
				case search.TypeFile:
					_, err = pg.SearchFiles(ctx, ta, q)
				case search.TypeTopic:
					_, err = pg.SearchTopics(ctx, ta, q)
				default:
					continue
				}
				if err != nil {
					t.Fatalf("%q %s: %v", qs, ty, err)
				}
				if round >= 0 {
					lat = append(lat, time.Since(start))
					byType[ty] = append(byType[ty], time.Since(start))
				}
			}
		}
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	p95 := lat[len(lat)*95/100]
	t.Logf("search p95 = %v, p50 = %v, max = %v over %d statements; corpus %d messages per tenant x 2 tenants", p95, lat[len(lat)/2], lat[len(lat)-1], len(lat), n)
	for ty, ls := range byType {
		sort.Slice(ls, func(i, j int) bool { return ls[i] < ls[j] })
		t.Logf("  %s: p95 %v over %d", ty, ls[len(ls)*95/100], len(ls))
	}
	if p95 > ceiling {
		t.Fatalf("p95 %v is over the %v ceiling", p95, ceiling)
	}
	// the budget answers ErrSearchBudget, never a hang
	p, _ := search.Parse("type:topic deploy", now)
	if _, err := pg.SearchTopics(ctx, ta, SearchQuery{Q: p, Now: now, Limit: 21, Budget: time.Millisecond}); err != nil && !errors.Is(err, ErrSearchBudget) {
		t.Fatalf("budget: %v", err)
	}
}

// TestCandidateQuery is spec 100 T005: the probe's tsquery is the root's
// AND-chain text terms joined with &&, never a term under an Or or a Not and
// never from Query.Positive; the values are bind parameters only. A trailing
// space keeps the last bare word from turning into an as-you-type prefix.
func TestCandidateQuery(t *testing.T) {
	now := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	plain := func(n int) string { return fmt.Sprintf("plainto_tsquery('spool_search', $%d::text)", n) }
	pfx := func(n int) string {
		p := plain(n)
		return "(CASE WHEN numnode(" + p + ") = 0 THEN " + p + " ELSE (" + p + "::text || ':*')::tsquery END)"
	}
	for _, tc := range []struct {
		q    string
		want string
		args []any
		ok   bool
	}{
		{"deploy ", "(" + plain(1) + ")", []any{"deploy"}, true},
		{"deplo", "(" + pfx(1) + ")", []any{"deplo"}, true}, // as you type (search 1.1)
		{`"rolling deploy"`, "(phraseto_tsquery('spool_search', $1::text))", []any{"rolling deploy"}, true},
		{"deplo*", "(" + pfx(1) + ")", []any{"deplo"}, true},
		{"deploy rollback ", "(" + plain(1) + " && " + plain(2) + ")", []any{"deploy", "rollback"}, true},
		{"foo OR bar", "", nil, false},
		{"-foo", "", nil, false},
		{"from:x foo ", "(" + plain(1) + ")", []any{"foo"}, true},
		{"from:x", "", nil, false},
		{`from:x "a b" deplo* (c OR d) -e f `,
			"(phraseto_tsquery('spool_search', $1::text) && " + pfx(2) + " && " + plain(3) + ")",
			[]any{"a b", "deplo", "f"}, true},
	} {
		p, err := search.Parse(tc.q, now)
		if err != nil {
			t.Fatalf("parse %q: %v", tc.q, err)
		}
		c := &sqlc{}
		got, ok := c.candidateQuery(p.Root, search.OpText)
		if ok != tc.ok || got != tc.want {
			t.Errorf("%q: got (%q, %v), want (%q, %v)", tc.q, got, ok, tc.want, tc.ok)
		}
		if fmt.Sprint(c.args) != fmt.Sprint(tc.args) {
			t.Errorf("%q: args %v, want %v", tc.q, c.args, tc.args)
		}
	}
}

// TestCandidateProbeSQL is spec 100 T006 without a database: the kill switch
// (ScanOnly) and a query with no AND-chain text term never probe; ids filter
// the statement and nothing else changes; nil ids leave it as it was.
func TestCandidateProbeSQL(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		q        string
		scanOnly bool
		ok       bool
	}{
		{"deploy ", false, true},
		{"deploy ", true, false},
		{"from:x deploy ", false, true},
		{"from:x", false, false},
		{"foo OR bar", false, false},
		{"-foo", false, false},
	} {
		q := sq(t, tc.q, now)
		q.ScanOnly = tc.scanOnly
		sql, args, ok := candidateProbeSQL(q, searchIndexCap, search.OpText)
		if ok != tc.ok {
			t.Fatalf("%q scanOnly=%v: probe %v, want %v", tc.q, tc.scanOnly, ok, tc.ok)
		}
		if ok && (!strings.HasPrefix(sql, "SELECT msg_id::text FROM spool_search_candidates(") || args[len(args)-1] != searchIndexCap) {
			t.Fatalf("%q: probe %s %v", tc.q, sql, args)
		}
	}
	q := sq(t, "deploy ", now)
	plain, pargs := searchMessagesSQL("t1", q, true, nil)
	ids := []string{uuid4(), uuid4()}
	narrow, nargs := searchMessagesSQL("t1", q, true, ids)
	if strings.Contains(plain, "::uuid[])") {
		t.Fatalf("nil ids filtered the statement:\n%s", plain)
	}
	m := regexp.MustCompile(` AND m\.msg_id = ANY\(\$(\d+)::uuid\[\]\)`).FindStringSubmatch(narrow)
	if m == nil {
		t.Fatalf("ids did not filter the statement:\n%s", narrow)
	}
	n, _ := strconv.Atoi(m[1])
	if got := renumber(strings.Replace(narrow, m[0], "", 1), n); got != plain || len(nargs) != len(pargs)+1 {
		t.Fatalf("ids changed more than the filter:\n%s\nvs\n%s", got, plain)
	}
	if fmt.Sprint(nargs[n-1]) != fmt.Sprint(ids) {
		t.Fatalf("ids arg %v", nargs[n-1])
	}
}

// renumber shifts every bind parameter above $from down by one (the
// statement without the ids filter, whose parameter sits at $from).
func renumber(sql string, from int) string {
	for n := from + 1; n <= from+10; n++ {
		sql = strings.ReplaceAll(sql, fmt.Sprintf("$%d", n), fmt.Sprintf("$%d", n-1))
	}
	return sql
}

// TestSearchIndexPathEqualsScan is spec 100 T006 on Postgres: below the cap
// (the id filter) and above it (cap + 1 candidates: today's statement), the
// index path returns the scan path's rows, row for row and in order, on every
// keyset page and by relevance; the switch off never probes.
func TestSearchIndexPathEqualsScan(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx, now := context.Background(), time.Now().UTC()
	tid := newTenant(t, pg)
	// 700 rows say "common", every 50th also says "rare" (14); every 7th is
	// in another channel; one is expired.
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id,
				kind, body, files, msg, env_sig, env, received_at, expires_at, channel)
			SELECT $1, gen_random_uuid(), gen_random_uuid(), $2::timestamptz - i * interval '1 minute', 'box-a', 'GRK-03',
				'box-b', 'CLE-07', 'note',
				'common word ' || CASE WHEN i % 50 = 0 THEN 'rare rare ' ELSE '' END || md5(i::text),
				'[]', '{"v":1}', 'sig', '\x00', $2::timestamptz - (i % 3) * interval '1 minute',
				CASE WHEN i = 100 THEN $2::timestamptz - interval '1 minute' ELSE $2::timestamptz + interval '30 days' END,
				CASE WHEN i % 7 = 0 THEN 'ops' ELSE 'lobby' END
			FROM generate_series(1, 700) i`, tid, now)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if !pg.hasSearchIndex(ctx) {
		t.Fatal("rdb 0143 spool_search_candidates not found by the probe")
	}
	for _, text := range []string{"rare ", "rare in:lobby ", "rare -in:ops ", "common ", "common rare ", "rar", "from:GRK-03 common "} {
		base := sq(t, text, now)
		sql, args, ok := candidateProbeSQL(base, searchIndexCap, search.OpText)
		if !ok {
			t.Fatalf("%q: no probe", text)
		}
		var n int
		if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM (`+sql+`) c`, args...).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		ids, err := pg.searchCandidates(ctx, tid, base, searchIndexCap, search.OpText)
		if err != nil {
			t.Fatal(err)
		}
		if above := n > searchIndexCap; above != (ids == nil) {
			t.Fatalf("%q: %d candidates, ids nil=%v: the id filter must apply exactly at or below the cap", text, n, ids == nil)
		}
		walk := func(scanOnly, relevance bool) []string {
			var out []string
			q := base
			q.ScanOnly, q.Relevance, q.Limit, q.Budget = scanOnly, relevance, 40, 5*time.Second
			for page := 0; page < 50; page++ {
				rows, err := pg.SearchMessages(ctx, tid, q)
				if err != nil {
					t.Fatalf("%q scanOnly=%v: %v", text, scanOnly, err)
				}
				out = append(out, msgIDs(rows)...)
				if len(rows) < q.Limit {
					return out
				}
				last := rows[len(rows)-1]
				q.AfterAt, q.AfterID, q.Offset = last.ReceivedAt, last.MsgID, q.Offset+len(rows)
			}
			t.Fatalf("%q: paging did not end", text)
			return nil
		}
		for _, rel := range []bool{false, true} {
			scan, idx := walk(true, rel), walk(false, rel)
			if len(scan) == 0 || fmt.Sprint(scan) != fmt.Sprint(idx) {
				t.Fatalf("%q relevance=%v: index path %d rows != scan path %d rows", text, rel, len(idx), len(scan))
			}
		}
		t.Logf("%q: %d candidates, filter=%v", text, n, ids != nil)
	}
	off := sq(t, "rare ", now)
	off.ScanOnly = true
	if _, _, ok := candidateProbeSQL(off, searchIndexCap, search.OpText); ok {
		t.Fatal("switch off: probe built")
	}
	if ids, err := pg.searchCandidates(ctx, tid, off, searchIndexCap, search.OpText); ids != nil || err != nil {
		t.Fatalf("switch off: probed (%v, %v)", ids, err)
	}
}

// TestSearchTopicsSQLIds is spec 100 T007 without a database: the topic
// probe takes text and title: terms (the kill switch never probes); ids add
// one filter inside topicCandidates and nothing else changes; nil ids leave
// the statement as it was.
func TestSearchTopicsSQLIds(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		q  string
		ok bool
	}{{"deploy ", true}, {"title:deploy", true}, {"in:ops title:deploy", true}, {"in:ops", false}, {"foo OR bar", false}} {
		if _, _, ok := candidateProbeSQL(sq(t, tc.q, now), searchIndexCap, search.OpText, search.OpTitle); ok != tc.ok {
			t.Fatalf("%q: topic probe %v, want %v", tc.q, ok, tc.ok)
		}
	}
	q := sq(t, "deploy in:ops ", now)
	plain, pargs := searchTopicsSQL("t1", q, true, nil)
	ids := []string{uuid4(), uuid4()}
	narrow, nargs := searchTopicsSQL("t1", q, true, ids)
	if strings.Contains(plain, "::uuid[])") {
		t.Fatalf("nil ids filtered the statement:\n%s", plain)
	}
	m := regexp.MustCompile(` AND k\.msg_id = ANY\(\$(\d+)::uuid\[\]\)\)`).FindStringSubmatch(narrow)
	if m == nil {
		t.Fatalf("ids did not filter topicCandidates:\n%s", narrow)
	}
	n, _ := strconv.Atoi(m[1])
	if got := renumber(strings.Replace(narrow, m[0], ")", 1), n); got != plain || len(nargs) != len(pargs)+1 {
		t.Fatalf("ids changed more than the filter:\n%s\nvs\n%s", got, plain)
	}
	if fmt.Sprint(nargs[n-1]) != fmt.Sprint(ids) {
		t.Fatalf("ids arg %v", nargs[n-1])
	}
}

// TestSearchTopicsIndexPathEqualsScan is spec 100 T007 on Postgres: below the
// cap (the id filter in topicCandidates) and above it (cap + 1 candidates:
// today's statement), topics via the index equal topics via the scan, row for
// row and in order, on every keyset page; the switch off never probes.
// CONTROL: the same comparison against ids missing ONE topic's first message
// (what a truncated set could be) fails.
func TestSearchTopicsIndexPathEqualsScan(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx, now := context.Background(), time.Now().UTC()
	tid := newTenant(t, pg)
	// 300 topics of 3 messages (900 say "common"). Every 20th topic's first
	// message says "rare" (15 titles); every 30th topic's replies say "rare"
	// (never its title); every 7th topic is in another channel; one reply is
	// expired.
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id,
				kind, body, files, msg, env_sig, env, received_at, expires_at, channel)
			SELECT $1, gen_random_uuid(), md5('topic' || i)::uuid, $2::timestamptz - i * interval '1 minute', 'box-a',
				CASE WHEN j = 2 THEN 'CLE-07' ELSE 'GRK-03' END, 'box-b', 'CLE-07', 'note',
				CASE WHEN j = 1 THEN 'common word ' || CASE WHEN i % 20 = 0 THEN 'rare ' ELSE '' END || md5(i::text)
					ELSE 'reply common ' || CASE WHEN i % 30 = 0 THEN 'rare ' ELSE '' END || md5(i || 'r' || j) END,
				'[]', '{"v":1}', 'sig', '\x00', $2::timestamptz - i * interval '1 minute' + j * interval '1 second',
				CASE WHEN i = 60 AND j = 3 THEN $2::timestamptz - interval '1 minute' ELSE $2::timestamptz + interval '30 days' END,
				CASE WHEN i % 7 = 0 THEN 'ops' ELSE 'lobby' END
			FROM generate_series(1, 300) i, generate_series(1, 3) j`, tid, now)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if !pg.hasSearchIndex(ctx) {
		t.Fatal("rdb 0143 spool_search_candidates not found by the probe")
	}
	ops := []string{search.OpText, search.OpTitle}
	walk := func(text string, base SearchQuery, scanOnly bool, limit int) []string {
		var out []string
		q := base
		q.ScanOnly, q.Limit, q.Budget = scanOnly, limit, 5*time.Second
		for page := 0; page < 200; page++ {
			rows, err := pg.SearchTopics(ctx, tid, q)
			if err != nil {
				t.Fatalf("%q scanOnly=%v: %v", text, scanOnly, err)
			}
			for _, r := range rows {
				out = append(out, fmt.Sprint(r.TaskID, r.Title, r.Count, r.LastAt.UnixNano(), r.Channel, r.Kinds, r.Parties))
			}
			if len(rows) < q.Limit {
				return out
			}
			last := rows[len(rows)-1]
			q.AfterAt, q.AfterID = last.LastAt, last.TaskID
		}
		t.Fatalf("%q: paging did not end", text)
		return nil
	}
	for _, text := range []string{"rare ", "title:rare", "rare in:lobby ", "rare -in:ops ", "rar", "from:GRK-03 rare ",
		"common ", "common rare ", "title:common"} {
		base := sq(t, text, now)
		sql, args, ok := candidateProbeSQL(base, searchIndexCap, ops...)
		if !ok {
			t.Fatalf("%q: no probe", text)
		}
		var n int
		if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM (`+sql+`) c`, args...).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		ids, err := pg.searchCandidates(ctx, tid, base, searchIndexCap, ops...)
		if err != nil {
			t.Fatal(err)
		}
		if above := n > searchIndexCap; above != (ids == nil) {
			t.Fatalf("%q: %d candidates, ids nil=%v: the id filter must apply exactly at or below the cap", text, n, ids == nil)
		}
		// small pages below the cap (several keyset pages of the id filter);
		// above it both paths run today's statement, so fewer, larger pages
		limit := 4
		if ids == nil {
			limit = 40
		}
		scan, idx := walk(text, base, true, limit), walk(text, base, false, limit)
		if len(scan) == 0 || fmt.Sprint(scan) != fmt.Sprint(idx) {
			t.Fatalf("%q: index path %d topics != scan path %d topics\n%v\n%v", text, len(idx), len(scan), idx, scan)
		}
		t.Logf("%q: %d candidates, filter=%v, %d topics", text, n, ids != nil, len(scan))
	}

	// CONTROL: drop the first message of the newest "rare" topic from the
	// candidates; that topic must go, so the equality above can fail.
	base := sq(t, "rare ", now)
	base.Limit, base.Budget = 50, 5*time.Second
	scan, err := pg.SearchTopics(ctx, tid, SearchQuery{Q: base.Q, Now: now, Limit: 50, Budget: 5 * time.Second, ScanOnly: true})
	if err != nil || len(scan) == 0 {
		t.Fatalf("control scan: %d topics, %v", len(scan), err)
	}
	ids, err := pg.searchCandidates(ctx, tid, base, searchIndexCap, ops...)
	if err != nil || ids == nil {
		t.Fatalf("control probe: %v, %v", ids, err)
	}
	var first string
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT msg_id::text FROM messages WHERE task_id = $1::uuid ORDER BY received_at, msg_id LIMIT 1`,
			scan[0].TaskID).Scan(&first)
	}); err != nil {
		t.Fatal(err)
	}
	cut := slices.DeleteFunc(slices.Clone(ids), func(id string) bool { return id == first })
	if len(cut) != len(ids)-1 {
		t.Fatalf("control: first message %s not among the %d candidates", first, len(ids))
	}
	sql, args := searchTopicsSQL(tid, base, pg.hasSearchSig(ctx), cut)
	var got []string
	if err := pg.search(ctx, tid, base, sql, args, func(rows pgx.Rows) error {
		var id string
		var skip any
		dst := []any{&id}
		for range rows.FieldDescriptions()[1:] {
			dst = append(dst, &skip)
		}
		if err := rows.Scan(dst...); err != nil {
			return err
		}
		got = append(got, id)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != len(scan)-1 || slices.Contains(got, scan[0].TaskID) {
		t.Fatalf("control: a candidate set missing topic %s's first message still returned %d of %d topics", scan[0].TaskID, len(got), len(scan))
	}

	off := sq(t, "rare ", now)
	off.ScanOnly = true
	if ids, err := pg.searchCandidates(ctx, tid, off, searchIndexCap, ops...); ids != nil || err != nil {
		t.Fatalf("switch off: probed (%v, %v)", ids, err)
	}
}
