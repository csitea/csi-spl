package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// linkedTasks is the issue's discussions, sorted.
func linkedTasks(t *testing.T, d IssueDiscussions, tenant string, number int) []string {
	t.Helper()
	links, err := d.IssueDiscussionLinks(context.Background(), tenant, []int{number})
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, l := range links[number] {
		out = append(out, l.TaskID)
	}
	sort.Strings(out)
	return out
}

func sameTasks(got []string, want ...string) bool {
	sort.Strings(want)
	return strings.Join(got, ",") == strings.Join(want, ",")
}

// topicMsg stores one #lobby message of topic task in tenant.
func topicMsg(t *testing.T, s Store, tenant, task, body string) string {
	t.Helper()
	at := time.Now().UTC().Truncate(time.Microsecond)
	id := uuid4()
	m := Message{TenantID: tenant, MsgID: id, TaskID: task, Channel: ChannelLobby, TS: at,
		FromBox: "box-wui", FromID: "HUM-1", ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: body,
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte(`{"env":1}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour), IsParent: 1}
	if _, err := s.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return id
}

// SPL-1593 (rdb 0194): a create needs at least one discussion; links add,
// de-duplicate and never drop to zero. Memory and, with SPOOL_TEST_PG_DSN,
// Postgres.
func TestIssueDiscussionsLinks(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			is, d := s.(Issues), s.(IssueDiscussions)
			now := time.Now().UTC().Truncate(time.Microsecond)
			tn := newTenant(t, s)
			for _, ds := range [][]string{nil, {}, {"SPL-1"}, {"/t/" + uuid4()}} {
				if _, err := is.CreateIssue(ctx, Issue{TenantID: tn, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1", Discussions: ds}, now); !errors.Is(err, ErrInvalidIssue) {
					t.Fatalf("discussions %q: %v, want ErrInvalidIssue", ds, err)
				}
			}
			// Control: the refused creates took no number.
			if all, err := is.ListIssues(ctx, tn); err != nil || len(all) != 0 {
				t.Fatalf("after the refusals: %v %v", all, err)
			}
			a, b := uuid4(), uuid4()
			one, err := is.CreateIssue(ctx, Issue{TenantID: tn, Title: "one", TaskID: uuid4(), CreatedBy: "HUM-1",
				Discussions: []string{a, strings.ToUpper(a)}}, now)
			if err != nil {
				t.Fatal(err)
			}
			if got := linkedTasks(t, d, tn, one.Number); !sameTasks(got, a) {
				t.Fatalf("create links %v, want [%s] (deduplicated)", got, a)
			}
			if added, err := d.LinkIssueDiscussion(ctx, tn, one.Number, b, "HUM-2", now); err != nil || !added {
				t.Fatalf("link b: %v %v", added, err)
			}
			if added, err := d.LinkIssueDiscussion(ctx, tn, one.Number, b, "HUM-2", now); err != nil || added {
				t.Fatalf("link b again: %v %v, want a no-op", added, err)
			}
			if _, err := d.LinkIssueDiscussion(ctx, tn, 999, b, "HUM-2", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("link on no issue: %v", err)
			}
			if err := d.UnlinkIssueDiscussion(ctx, tn, one.Number, a); err != nil {
				t.Fatal(err)
			}
			if err := d.UnlinkIssueDiscussion(ctx, tn, one.Number, b); !errors.Is(err, ErrIssueDiscussionLast) {
				t.Fatalf("unlink the last: %v, want ErrIssueDiscussionLast", err)
			}
			if err := d.UnlinkIssueDiscussion(ctx, tn, one.Number, a); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unlink one it does not link: %v", err)
			}
			if got := linkedTasks(t, d, tn, one.Number); !sameTasks(got, b) {
				t.Fatalf("after: %v, want [%s]", got, b)
			}
			// Another tenant sees none of it.
			if links, err := d.IssueDiscussionLinks(ctx, newTenant(t, s), nil); err != nil || len(links) != 0 {
				t.Fatalf("other tenant: %v %v", links, err)
			}
			// States: a topic with a message is live, one without is gone.
			topicMsg(t, s, tn, a, "**Login breaks**\nmore")
			st, err := d.DiscussionStates(ctx, tn, []string{a, b})
			if err != nil || st[a].State != DiscussionLive || st[a].Title != "Login breaks" || st[a].Channel != ChannelLobby || st[b].State != DiscussionGone {
				t.Fatalf("states %+v %v", st, err)
			}
		})
	}
}

// rdb 0194 on Postgres: the database itself refuses an issue with no link and
// the removal of an issue's last link; the Go ids match the SQL functions;
// deleting a discussion physically relinks an issue left with none to the
// tenant's default, and a merged topic takes its links along.
func TestIssueDiscussions0194(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	for _, tn := range []string{"t1", "acme", uid("x-")} {
		var backlog, def string
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT spool_issue_backlog_id($1)::text, issue_discussion_default($1)::text`, tn).Scan(&backlog, &def)
		}); err != nil {
			t.Fatal(err)
		}
		if backlog != IssueBacklogID(tn) || def != IssueDiscussionDefault(tn) {
			t.Fatalf("%s: SQL %s / %s, Go %s / %s", tn, backlog, def, IssueBacklogID(tn), IssueDiscussionDefault(tn))
		}
	}
	if IssueDiscussionDefault("t1") != IssueDiscussionDefaultT1 || IssueDiscussionDefault("acme") != IssueBacklogID("acme") {
		t.Fatal("the default: t1 the owner's topic, any other tenant its backlog topic")
	}

	tn := newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	refused := func(what string, err error) {
		t.Helper()
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "23514" || pe.ConstraintName != "issue_discussions_at_least_one" {
			t.Fatalf("%s: %v, want a 23514 issue_discussions_at_least_one refusal", what, err)
		}
	}
	refused("an issue with no link", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO issues (tenant_id, number, title, task_id, created_by, updated_by)
			VALUES ($1, 1, 'bare', gen_random_uuid(), 'HUM-1', 'HUM-1')`, tn)
		return err
	}))
	one, err := pg.CreateIssue(ctx, Issue{TenantID: tn, Title: "one", TaskID: uuid4(), CreatedBy: "HUM-1", Discussions: []string{uuid4()}}, now)
	if err != nil {
		t.Fatal(err)
	}
	refused("removing the last link", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM issue_discussions WHERE tenant_id = $1 AND number = $2`, tn, one.Number)
		return err
	}))
	// Control: the issue goes with its links (a tenant delete, a cascade).
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM issues WHERE tenant_id = $1 AND number = $2`, tn, one.Number)
		return err
	}); err != nil {
		t.Fatalf("deleting the issue with its links: %v", err)
	}

	// The relink (owner msg 81a43a7f, "B").
	solo, shared, merged, target := uuid4(), uuid4(), uuid4(), uuid4()
	soloMsg := topicMsg(t, pg, tn, solo, "solo")
	topicMsg(t, pg, tn, solo, "a reply")
	sharedMsg := topicMsg(t, pg, tn, shared, "shared")
	topicMsg(t, pg, tn, merged, "merged away")
	topicMsg(t, pg, tn, target, "the merge target")
	mk := func(ds ...string) int {
		t.Helper()
		i, err := pg.CreateIssue(ctx, Issue{TenantID: tn, Title: "i", TaskID: uuid4(), CreatedBy: "HUM-1", Discussions: ds}, now)
		if err != nil {
			t.Fatal(err)
		}
		return i.Number
	}
	onlySolo, soloAndShared, onlyMerged := mk(solo), mk(solo, shared), mk(merged)
	if err := pg.DeleteMessage(ctx, tn, soloMsg); err != nil {
		t.Fatal(err)
	}
	// Control: one message of the topic is left, so nothing moved.
	if got := linkedTasks(t, pg, tn, onlySolo); !sameTasks(got, solo) {
		t.Fatalf("after one of two messages: %v, want [%s]", got, solo)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1 AND task_id = $2`, tn, solo)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	def := IssueDiscussionDefault(tn)
	if got := linkedTasks(t, pg, tn, onlySolo); !sameTasks(got, def) {
		t.Fatalf("an issue whose only discussion is gone: %v, want the default [%s]", got, def)
	}
	if got := linkedTasks(t, pg, tn, soloAndShared); !sameTasks(got, shared) {
		t.Fatalf("an issue with another discussion left: %v, want [%s]", got, shared)
	}
	if err := pg.DeleteMessage(ctx, tn, sharedMsg); err != nil {
		t.Fatal(err)
	}
	if got := linkedTasks(t, pg, tn, soloAndShared); !sameTasks(got, def) {
		t.Fatalf("after its second discussion is gone too: %v, want [%s]", got, def)
	}
	// A merge moves every message of the topic into another: the link follows.
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE messages SET task_id = $3 WHERE tenant_id = $1 AND task_id = $2`, tn, merged, target)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := linkedTasks(t, pg, tn, onlyMerged); !sameTasks(got, target) {
		t.Fatalf("after the merge: %v, want [%s]", got, target)
	}
	// The backlog probe: tn's issues now link its backlog topic, which has no
	// message yet.
	missing, err := pg.TenantsMissingIssueBacklog(ctx)
	if err != nil || !contains(missing, tn) {
		t.Fatalf("tenants missing the backlog topic: %v %v, want %s in it", missing, err, tn)
	}
}

// rdb 0194's backfill links every issue (deleted and archived ones too) to
// its tenant's default. The statement runs again in one operator transaction
// on rows inserted raw before it, so the rule checks at that COMMIT.
func TestMigration0194Backfill(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	backfill := backfill0194(t)
	a, b := uid("m186a-"), uid("m186b-")
	for _, tn := range []string{a, b} {
		if err := pg.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
			t.Fatal(err)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		for _, r := range []struct {
			tn  string
			n   int
			del bool
		}{{a, 1, false}, {a, 2, true}, {b, 1, false}} {
			if _, err := tx.Exec(ctx, `INSERT INTO issue_counters (tenant_id, last_number) VALUES ($1, $2)
				ON CONFLICT (tenant_id) DO UPDATE SET last_number = GREATEST(issue_counters.last_number, $2)`, r.tn, r.n); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO issues (tenant_id, number, title, task_id, created_by, updated_by, deleted_at)
				VALUES ($1, $2, 'old', gen_random_uuid(), 'HUM-1', 'HUM-1', CASE WHEN $3 THEN now() END)`, r.tn, r.n, r.del); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, backfill)
		return err
	}); err != nil {
		t.Fatalf("raw issues + the 0194 backfill: %v", err)
	}
	for _, c := range []struct {
		tn string
		n  int
	}{{a, 1}, {a, 2}, {b, 1}} {
		if got := linkedTasks(t, pg, c.tn, c.n); !sameTasks(got, IssueBacklogID(c.tn)) {
			t.Errorf("%s-%d: %v, want its backlog topic", c.tn, c.n, got)
		}
	}
}

// backfill0194 is rdb 0194's backfill statement: a test that inserts issues
// raw runs it in the same transaction, so they commit with a discussion.
func backfill0194(t testing.TB) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0194_issue_discussions.sql"))
	if err != nil {
		t.Fatal(err)
	}
	_, after, ok := strings.Cut(string(raw), "-- Backfill, in the migrator's operator scope")
	if !ok {
		t.Fatal("0194 has no backfill section")
	}
	return "-- Backfill" + after
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
