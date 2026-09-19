package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sort"
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
				"thread:" + tk2:                  {m3.MsgID},
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

			// threads: title FTS, participants, root, DM privacy
			th, err := se.SearchThreads(ctx, ta, sq(t, "title:migration", now))
			if err != nil || len(th) != 1 || th[0].TaskID != tk2 || th[0].Title != "Migration plan for 0020" || th[0].Parent != tk1 || th[0].Count != 1 {
				t.Fatalf("title: %v %+v", err, th)
			}
			if th, _ := se.SearchThreads(ctx, ta, sq(t, "please", now)); len(th) != 1 || th[0].TaskID != tk1 || th[0].Count != 2 {
				t.Fatalf("thread text: %+v", th)
			}
			if th, _ := se.SearchThreads(ctx, ta, sq(t, "is:root from:CLE-07", now)); len(th) != 1 || th[0].TaskID != tk1 {
				t.Fatalf("root threads with a message from CLE-07: %+v", th)
			}
			tq := sq(t, "type:thread in:dm", now)
			tq.Viewer = "HUM-1"
			if th, _ := se.SearchThreads(ctx, ta, tq); len(th) != 1 || th[0].TaskID != dm {
				t.Fatalf("CONTROL thread DM privacy: %+v", th)
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
// (search-v1 §7, T053). SPOOL_TEST_SEARCH_N sets the corpus size.
func TestSearchP95(t *testing.T) {
	d := drivers(t)
	s, ok := d["postgres"]
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	pg := s.(*Postgres)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	n := 20000
	if v := os.Getenv("SPOOL_TEST_SEARCH_N"); v != "" {
		fmt.Sscan(v, &n) //nolint:errcheck
	}
	ta, tb := newTenant(t, s), newTenant(t, s)
	words := []string{"deploy", "hub", "migration", "release", "rollback", "tenant", "billing", "search", "index", "cursor",
		"thread", "channel", "robot", "report", "latency", "budget", "alert", "disk", "network", "certificate"}
	// bulk seed through COPY-like multi-row inserts, as the owner role (RLS: tenant scope per batch)
	for _, tid := range []string{ta, tb} {
		for base := 0; base < n; base += 1000 {
			err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
					kind, body, files, msg, env_sig, env, received_at, expires_at)
					SELECT $1, gen_random_uuid(), gen_random_uuid(), (ARRAY['tasks','alerts','lobby',NULL])[1 + g % 4], $2::timestamptz - g * interval '1 second',
						'box-' || (g % 7), (ARRAY['CLE-07','GRK-03','HUM-1'])[1 + g % 3], 'box-b', 'CLE-07',
						(ARRAY['task','note','result','reject'])[1 + g % 4],
						(SELECT string_agg(w, ' ') FROM (SELECT ($3::text[])[1 + ((g * 7 + k * 13) % 20)] AS w FROM generate_series(1, 12) k) z),
						CASE WHEN g % 10 = 0 THEN '[{"mode":"blob","kind":"file","name":"report.pdf","bytes":1048577}]'::jsonb ELSE '[]'::jsonb END,
						'{}'::jsonb, 'sig', '\x00'::bytea, $2::timestamptz - g * interval '1 second', $2::timestamptz + interval '30 days'
					FROM generate_series($4::int, $5::int) g`, tid, now, words, base, base+999)
				return err
			})
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	queries := []string{"deploy", `"deploy hub"`, "deploy -rollback from:CLE-07", "in:#tasks is:note migration",
		"type:file ext:pdf", "has:file after:7d", "title:release", "(latency OR budget) -in:dm", "box:box-3 certificate", "zzz-no-hit"}
	var lat []time.Duration
	byType := map[search.Type][]time.Duration{}
	for round := 0; round < 5; round++ {
		for _, qs := range queries {
			p, err := search.Parse(qs, now)
			if err != nil {
				t.Fatal(err)
			}
			q := SearchQuery{Q: p, Now: now, Limit: 21, Viewer: "HUM-1", Budget: 2 * time.Second}
			for _, ty := range p.Types {
				start := time.Now()
				switch ty {
				case search.TypeMessage:
					_, err = pg.SearchMessages(ctx, ta, q)
				case search.TypeFile:
					_, err = pg.SearchFiles(ctx, ta, q)
				case search.TypeThread:
					_, err = pg.SearchThreads(ctx, ta, q)
				default:
					continue
				}
				if err != nil {
					t.Fatalf("%q %s: %v", qs, ty, err)
				}
				lat = append(lat, time.Since(start))
				byType[ty] = append(byType[ty], time.Since(start))
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
	if p95 > 2*time.Second {
		t.Fatalf("p95 %v is over the 2 s budget", p95)
	}
	// the budget answers ErrSearchBudget, never a hang
	p, _ := search.Parse("type:thread deploy", now)
	if _, err := pg.SearchThreads(ctx, ta, SearchQuery{Q: p, Now: now, Limit: 21, Budget: time.Millisecond}); err != nil && !errors.Is(err, ErrSearchBudget) {
		t.Fatalf("budget: %v", err)
	}
}
