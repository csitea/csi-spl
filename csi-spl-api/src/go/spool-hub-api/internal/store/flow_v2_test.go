package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// Spec 130 (rdb 0177), lane L1: the write labels a blocker line `blocked`
// and a line carrying `accepts` `ready`; an agent <id>@<box> gets the
// channel lines that name it, never a DM; the folded read is one line per
// topic per UTC day plus one release line per UTC day. Memory and, with
// SPOOL_TEST_PG_DSN, Postgres.
func TestFlowV2(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe := s.(FlowEvents)
			ff, ok := s.(FlowFolder)
			if !ok {
				t.Fatalf("%s store has no FlowFolder", name)
			}
			ctx := context.Background()
			day := time.Now().UTC().Truncate(24 * time.Hour).Add(-48 * time.Hour)
			tid := newTenant(t, s)
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "sec", Name: "sec", CreatedBy: "HUM-1", CreatedAt: day}); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "sec", []string{"HUM-1"}, "HUM-1", day); err != nil {
				t.Fatal(err)
			}
			if err := s.(Channels).InviteChannelAgent(ctx, tid, "sec", "box-a", "c-002", day); err != nil {
				t.Fatal(err)
			}
			n := 0
			post := func(at time.Time, from, to, channel, task, kind, body, inner string) Message {
				t.Helper()
				n++
				at = at.Add(time.Duration(n) * time.Second)
				m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
				m.FromID, m.ToID, m.Channel, m.Kind, m.Body = from, to, channel, kind, body
				if inner != "" {
					m.Msg = []byte(inner)
				}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			now := day.Add(72 * time.Hour)
			kinds := func(member string) string {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: member, Limit: 50, Now: now})
				if err != nil {
					t.Fatal(err)
				}
				out := ""
				for _, e := range p.Events {
					out += e.Kind + ":" + e.Body + "|"
				}
				return out
			}

			task, other, quiet := uuid4(), uuid4(), uuid4()
			result := post(day, "HUM-1", "", "lobby", task, "task", "root", "")
			post(day, "c-009", "", "lobby", task, "blocker", "stuck, @HUM-1 and @c-002@box-a", "")
			post(day, "c-009", "", "lobby", task, "result", "accepted",
				fmt.Sprintf(`{"v":1,"accepts":%q}`, result.MsgID))
			post(day, "c-009", "c-002", "", other, "task", "a DM to c-002 on box-a", "")
			post(day, "HUM-1", "", "sec", quiet, "note", "@c-002@box-a in sec, @c-003@box-a not a member", "")
			post(day.Add(24*time.Hour), "c-009", "", "lobby", task, "note", "next day", "")

			// The kind labels: blocked outranks the mention; ready marks the line
			// that carries accepts (no body parsing).
			h1 := kinds("HUM-1")
			if !strings.Contains(h1, "blocked:stuck") {
				t.Fatalf("HUM-1 flow %q: the blocker line must be `blocked`, not `mention`", h1)
			}
			if !strings.Contains(h1, "ready:accepted") {
				t.Fatalf("HUM-1 flow %q: the line carrying accepts must be `ready`", h1)
			}
			// The agent: the channel lines that name it with its box, behind
			// its channel membership; never the DM, never a reply.
			if got, want := kinds("c-002@box-a"), "mention:@c-002@box-a in sec, @c-003@box-a not a member|blocked:stuck, @HUM-1 and @c-002@box-a|"; got != want {
				t.Fatalf("agent flow\n got %s\nwant %s", got, want)
			}
			if got := kinds("c-003@box-a"); got != "" {
				t.Fatalf("an agent outside #sec got %s", got)
			}
			if got := kinds("c-002"); got != "" {
				t.Fatalf("a bare agent id got %s", got)
			}

			// The fold: one line per topic per UTC day, the strongest kind, the
			// count, the authors newest first, the topic's title.
			f, err := ff.FlowFoldRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 30, Now: now})
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, l := range f.Lines {
				if l.Kind == FlowRelease {
					continue
				}
				got = append(got, fmt.Sprintf("%s %s n=%d from=%v title=%s", l.Day, l.Kind, l.Count, l.From, l.Title))
			}
			d0, d1 := flowDay(day), flowDay(day.Add(24*time.Hour))
			want := []string{
				d1 + " reply n=1 from=[c-009] title=root",
				d0 + " blocked n=2 from=[c-009] title=root",
			}
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("folded lines\n got %s\nwant %s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
			if f.More {
				t.Fatal("one short window: no next page")
			}
			// One line per page: the cursor is the oldest kept event, so the
			// next page holds the rest.
			p1, err := ff.FlowFoldRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 1, Now: now})
			if err != nil {
				t.Fatal(err)
			}
			// Release lines are estate-wide (other tests' rows on a shared
			// database): the paging asserts read the topic lines.
			topics := func(ls []FlowLine) []FlowLine {
				var out []FlowLine
				for _, l := range ls {
					if l.Kind != FlowRelease {
						out = append(out, l)
					}
				}
				return out
			}
			p1.Lines = topics(p1.Lines)
			if len(p1.Lines) != 1 || !p1.More || p1.Lines[0].Day != d1 {
				t.Fatalf("page 1 = %+v more=%v", p1.Lines, p1.More)
			}
			p2, err := ff.FlowFoldRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 1, Now: now, BeforeAt: p1.NextAt, BeforeID: p1.NextID})
			if err != nil {
				t.Fatal(err)
			}
			p2.Lines = topics(p2.Lines)
			if len(p2.Lines) != 1 || p2.More || p2.Lines[0].Day != d0 || p2.Lines[0].Count != 2 {
				t.Fatalf("page 2 = %+v more=%v", p2.Lines, p2.More)
			}
		})
	}
}

// Spec 130 section 4: released_at is set when a commit first gets a version
// and never restamped by a re-sent row; the Flow folds it per UTC day.
func TestFlowReleaseLines(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rn, ok := s.(ReleaseNotes)
			if !ok {
				t.Skip("no release notes")
			}
			ff := s.(FlowFolder)
			ctx := context.Background()
			tid := newTenant(t, s)
			// A year far ahead keeps this test's rows apart from other tests'
			// on a shared database (release_notes has no tenant).
			base := time.Date(2091, 3, 4, 10, 0, 0, 0, time.UTC).Add(time.Duration(time.Now().UnixNano()%1000) * 24 * time.Hour)
			sha := func() string { return strings.Repeat(uuid4()[:8], 5) }
			note := func(s, v string) ReleaseNote {
				return ReleaseNote{SHA: s, Version: v, CommittedAt: base.Add(-time.Hour), Subject: "x", State: "ok"}
			}
			// Majors above TestReleaseNotes' 100000..899999: its lists read every
			// version below its own major + 1.
			major := 900000 + int(time.Now().UnixNano()%99999)
			v := func(z int) string { return fmt.Sprintf("v%d.0.%d", major, z) }
			a, b, c := sha(), sha(), sha()
			// release_notes is estate-wide: other packages' release tests read
			// the newest versions, so these rows go when the test ends.
			if pg, ok := s.(*Postgres); ok {
				t.Cleanup(func() {
					pg.pool.Exec(context.Background(), `DELETE FROM release_notes WHERE sha = ANY($1)`, []string{a, b, c}) //nolint:errcheck
				})
			}
			// a is ingested before it has a version, then gets v..1 at base.
			if err := rn.PutReleaseNotes(ctx, []ReleaseNote{note(a, "")}, base.Add(-time.Hour)); err != nil {
				t.Fatal(err)
			}
			if err := rn.PutReleaseNotes(ctx, []ReleaseNote{note(a, v(1)), note(b, v(2))}, base); err != nil {
				t.Fatal(err)
			}
			// A re-send an hour later must not restamp them; c is v..3 the next day.
			if err := rn.PutReleaseNotes(ctx, []ReleaseNote{note(a, v(1)), note(b, v(2))}, base.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			if err := rn.PutReleaseNotes(ctx, []ReleaseNote{note(c, v(3))}, base.Add(24*time.Hour)); err != nil {
				t.Fatal(err)
			}
			f, err := ff.FlowFoldRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 30, Now: base.Add(25 * time.Hour), Kind: FlowRelease})
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, l := range f.Lines {
				got = append(got, fmt.Sprintf("%s %s..%s n=%d at=%s sha=%v", l.Day, l.VersionFrom, l.VersionTo, l.Versions,
					l.At.UTC().Format("15:04"), l.SHA == c || l.SHA == b))
			}
			want := []string{
				fmt.Sprintf("%s %s..%s n=1 at=10:00 sha=true", flowDay(base.Add(24*time.Hour)), v(3), v(3)),
				fmt.Sprintf("%s %s..%s n=2 at=10:00 sha=true", flowDay(base), v(1), v(2)),
			}
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("release lines\n got %s\nwant %s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
			if !f.Lines[0].Unread {
				t.Fatal("a release line with no f:seen and no f:rel: mark is unread")
			}
			if err := s.(ReadMarks).SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{FlowReleaseMarkKey(v(3)): {At: base}}, base); err != nil {
				t.Fatal(err)
			}
			f, err = ff.FlowFoldRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 30, Now: base.Add(25 * time.Hour), Kind: FlowRelease})
			if err != nil {
				t.Fatal(err)
			}
			if f.Lines[0].Unread || !f.Lines[1].Unread {
				t.Fatalf("after f:rel:%s unread = %v %v, want false true", v(3), f.Lines[0].Unread, f.Lines[1].Unread)
			}
		})
	}
}

// f:rel:<version> is a read mark for exactly the release versions.
func TestFlowReleaseMarkKey(t *testing.T) {
	for _, v := range []string{"v1.3.400", "v1.0.1-c2", "v999999.0.0"} {
		if !releaseVersionRe.MatchString(v) || !ValidReadMarkKey(FlowReleaseMarkKey(v)) {
			t.Errorf("%s: release %v, mark %v", v, releaseVersionRe.MatchString(v), ValidReadMarkKey(FlowReleaseMarkKey(v)))
		}
	}
	for _, v := range []string{"1.3.400", "v1.3", "v1.0.1-c1", "v1.3.400 ", "vX.1.2"} {
		if releaseVersionRe.MatchString(v) || ValidReadMarkKey(FlowReleaseMarkKey(v)) {
			t.Errorf("%s accepted", v)
		}
	}
}

// Spec 130 section 6 (FR-003 of 062 kept) and section 3: the badge counts
// the release days newer than f:seen, never the history before it; setting
// an issue assignee makes the human seat a watcher of the issue's topic, so
// the next reply in it is in their Flow.
func TestFlowReleaseBadgeAndAssigneeWatch(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe, ctx := s.(FlowEvents), context.Background()
			tid := newTenant(t, s)
			base := time.Date(2092, 5, 6, 10, 0, 0, 0, time.UTC).Add(time.Duration(time.Now().UnixNano()%1000) * 24 * time.Hour)
			if rn, ok := s.(ReleaseNotes); ok {
				major := 900000 + int(time.Now().UnixNano()%99999)
				var shas []string
				for i, at := range []time.Time{base.Add(-time.Hour), base.Add(time.Hour), base.Add(2 * time.Hour), base.Add(25 * time.Hour)} {
					sha := strings.Repeat(uuid4()[:8], 5)
					shas = append(shas, sha)
					if err := rn.PutReleaseNotes(ctx, []ReleaseNote{{SHA: sha, Version: fmt.Sprintf("v%d.1.%d", major, i), CommittedAt: base, Subject: "x", State: "ok"}}, at); err != nil {
						t.Fatal(err)
					}
				}
				if pg, ok := s.(*Postgres); ok {
					t.Cleanup(func() {
						pg.pool.Exec(context.Background(), `DELETE FROM release_notes WHERE sha = ANY($1)`, shas) //nolint:errcheck
					})
				}
				read := func() FlowCounts {
					p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: base.Add(26 * time.Hour)})
					if err != nil {
						t.Fatal(err)
					}
					return p.Counts
				}
				if c := read(); c.Release != 0 {
					t.Fatalf("no f:seen: release = %d, want 0 (no flood)", c.Release)
				}
				if err := s.(ReadMarks).SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{FlowSeenKey: {At: base}}, base); err != nil {
					t.Fatal(err)
				}
				// Two days after f:seen (base day: +1 h, +2 h; next day: +25 h).
				if c := read(); c.Release < 2 || c.Total != 0 {
					t.Fatalf("after f:seen: release %d total %d, want >= 2 and 0", c.Release, c.Total)
				}
			}

			is, ok := s.(Issues)
			if !ok {
				t.Skip("no issues")
			}
			task := uuid4()
			now := time.Now().UTC().Truncate(time.Microsecond)
			post := func(from, body string, at time.Time) {
				m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
				m.FromID, m.ToID, m.Channel, m.Body = from, "", "lobby", body
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			post("c-009", "the topic", now)
			iss, err := is.CreateIssue(ctx, Issue{TenantID: tid, Title: "t", TaskID: task, CreatedBy: "HUM-9", Assignee: "HUM-3"}, now)
			if err != nil {
				t.Fatal(err)
			}
			post("c-009", "a reply", now.Add(time.Second))
			who := ""
			if _, err := is.UpdateIssue(ctx, tid, iss.Number, IssuePatch{Assignee: &[]string{"HUM-4"}[0]}, "HUM-9", now.Add(2*time.Second)); err != nil {
				t.Fatal(err)
			}
			post("c-009", "another reply", now.Add(3*time.Second))
			for _, m := range []string{"HUM-3", "HUM-4"} {
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: m, Limit: 10, Now: now.Add(time.Hour)})
				if err != nil {
					t.Fatal(err)
				}
				for _, e := range p.Events {
					who += m + ":" + e.Kind + ":" + e.Body + "|"
				}
			}
			if want := "HUM-3:reply:another reply|HUM-3:reply:a reply|HUM-4:reply:another reply|"; who != want {
				t.Fatalf("assignee watch\n got %s\nwant %s", who, want)
			}
		})
	}
}

// Spec 130 lane L4, "one deploy -> one new release line, not 500": a deploy's
// do_release_note_ingest re-sends a 500-commit window (RELEASE_NOTE_DEPTH);
// prd measured 500 rows re-stamped by one deploy (section 1). Only the one
// commit that newly got a version is a release: the deploy day carries ONE
// version, and the 500 already-versioned rows stay on their own day.
func TestFlowReleaseOneDeployOneLine(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rn, ok := s.(ReleaseNotes)
			if !ok {
				t.Skip("no release notes")
			}
			ctx := context.Background()
			tid := newTenant(t, s)
			// 2093+: apart from TestFlowReleaseLines' 2091 days on a shared database.
			hist := time.Date(2093, 1, 1, 9, 0, 0, 0, time.UTC).Add(time.Duration(time.Now().UnixNano()%1000) * 24 * time.Hour)
			deploy := hist.Add(3 * 24 * time.Hour)
			major := 900000 + int(time.Now().UnixNano()%99999)
			const depth = 500
			window := make([]ReleaseNote, 0, depth+1)
			shas := make([]string, 0, depth+1)
			for i := 0; i < depth; i++ {
				sha := fmt.Sprintf("%08x", i) + strings.Repeat(uuid4()[:8], 4)
				shas = append(shas, sha)
				window = append(window, ReleaseNote{SHA: sha, Version: fmt.Sprintf("v%d.0.%d", major, i+1),
					CommittedAt: hist.Add(-time.Hour), Subject: "x", State: "ok"})
			}
			if pg, ok := s.(*Postgres); ok {
				t.Cleanup(func() {
					pg.pool.Exec(context.Background(), `DELETE FROM release_notes WHERE sha = ANY($1)`, shas) //nolint:errcheck
				})
			}
			if err := rn.PutReleaseNotes(ctx, window, hist); err != nil {
				t.Fatal(err)
			}
			// The deploy: the newest 500, so 499 of them re-sent plus the one new
			// versioned commit.
			fresh := strings.Repeat(uuid4()[:8], 5)
			shas = append(shas, fresh)
			window = append(window, ReleaseNote{SHA: fresh, Version: fmt.Sprintf("v%d.0.%d", major, depth+1),
				CommittedAt: deploy.Add(-time.Minute), Subject: "x", State: "ok"})
			if err := rn.PutReleaseNotes(ctx, window[1:], deploy); err != nil {
				t.Fatal(err)
			}
			f, err := s.(FlowFolder).FlowFoldRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 30, Now: deploy.Add(time.Hour), Kind: FlowRelease})
			if err != nil {
				t.Fatal(err)
			}
			got := map[string]string{}
			for _, l := range f.Lines {
				if l.Day == flowDay(deploy) || l.Day == flowDay(hist) {
					got[l.Day] = fmt.Sprintf("%s..%s n=%d sha=%v", l.VersionFrom, l.VersionTo, l.Versions, l.SHA == fresh)
				}
			}
			v := func(z int) string { return fmt.Sprintf("v%d.0.%d", major, z) }
			want := map[string]string{
				flowDay(deploy): fmt.Sprintf("%s..%s n=1 sha=true", v(depth+1), v(depth+1)),
				flowDay(hist):   fmt.Sprintf("%s..%s n=%d sha=false", v(1), v(depth), depth),
			}
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("one deploy must add one release line of one version, not %d\n got %v\nwant %v", depth, got, want)
			}
		})
	}
}
