package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Spec 075 repo-edit T06 on Postgres (hub-pg.tst.sh). The queue's worker
// methods are global (asOperator) and other tests of this package seed
// queued rows at the wall clock, so these tests run their clock in 2001:
// nothing of another test is due, stale or counted in their window.

var repoDocEpoch = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

func repoDocNow() time.Time {
	return repoDocEpoch.Add(time.Duration(time.Now().UnixNano() % int64(24*time.Hour))).Truncate(time.Microsecond)
}

// repoDocTenant is a new workspace whose edits are dropped when the test
// ends, so no queued or pushing row of it is left for the next claim.
func repoDocTenant(t *testing.T, pg *Postgres) string {
	t.Helper()
	tenant := newTenant(t, pg)
	t.Cleanup(func() {
		if _, err := pg.execTenant(context.Background(), tenant, `DELETE FROM repo_doc_edits WHERE tenant_id = $1`, tenant); err != nil {
			t.Error(err)
		}
	})
	return tenant
}

func repoDocSave(tenant, human, path string) RepoDocEdit {
	id := uuid4()
	return RepoDocEdit{EditID: id, TenantID: tenant, HumanID: human, ActorKind: "member", Path: path,
		BaseBlob: "blob0", OverlayKey: ".edits/" + path + "/" + id + ".md", TextSHA256: "sha-" + id[:8],
		AuthorName: "FirstName LastName", AuthorEmail: human + "@example.com", AuthorSource: "signin"}
}

func repoDocInsert(t *testing.T, pg *Postgres, e RepoDocEdit, now time.Time) (RepoDocEdit, []string) {
	t.Helper()
	out, sup, err := pg.InsertRepoDocEdit(context.Background(), e, 2*time.Minute, 10*time.Minute, now)
	if err != nil {
		t.Fatal(err)
	}
	return out, sup
}

func repoDocStatus(t *testing.T, pg *Postgres, tenant, id string) string {
	t.Helper()
	e, err := pg.GetRepoDocEdit(context.Background(), tenant, id)
	if err != nil {
		t.Fatal(err)
	}
	return e.Status
}

// claimMine claims at now and keeps the rows of paths, failing on any other.
func claimMine(t *testing.T, pg *Postgres, now time.Time, paths ...string) []RepoDocEdit {
	t.Helper()
	got, err := pg.ClaimRepoDocEdits(context.Background(), 100, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range got {
		ok := false
		for _, p := range paths {
			ok = ok || e.Path == p
		}
		if !ok {
			t.Fatalf("claim at %s took a row of another test: %+v", now, e)
		}
	}
	return got
}

// TestRepoDocEditsPinRdb: the Go states and backoff are 0142's and spec 3's.
func TestRepoDocEditsPinRdb(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0142_repo_doc_edits.sql"))
	if err != nil {
		t.Fatal(err)
	}
	sql := strings.Join(strings.Fields(string(raw)), " ")
	m := regexp.MustCompile(`status text NOT NULL CHECK \(status IN \(([^)]*)\)\)`).FindStringSubmatch(sql)
	want := "'" + strings.Join(RepoDocStates, "', '") + "'"
	if m == nil || strings.ReplaceAll(m[1], " ", "") != strings.ReplaceAll(want, " ", "") {
		t.Errorf("status: rdb %v, Go (%s)", m, want)
	}
	if len(RepoDocBackoff) != 7 || RepoDocBackoff[0] != 30*time.Second || RepoDocBackoff[6] != time.Hour {
		t.Errorf("backoff drifted from spec section 3: %v", RepoDocBackoff)
	}
}

// TestRepoDocCoalesce: one author's saves of one path fold into the newest,
// the window restarts from it and is capped at coalesce_max after the run's
// first save; another author, another agent, a member vs an agent and
// another path never fold.
func TestRepoDocCoalesce(t *testing.T) {
	pg := pgOnly(t)
	tenant := repoDocTenant(t, pg)
	now := repoDocNow()
	path := "doc/" + uid("c-") + ".md"

	a1, sup := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", path), now)
	if len(sup) != 0 || a1.Status != RepoDocQueued || !a1.FirstSavedAt.Equal(now) || !a1.NextTryAt.Equal(now.Add(2*time.Minute)) {
		t.Fatalf("first save: %+v superseded %v", a1, sup)
	}
	a2, sup := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", path), now.Add(time.Minute))
	if len(sup) != 1 || sup[0] != a1.EditID || !a2.FirstSavedAt.Equal(now) || !a2.NextTryAt.Equal(now.Add(3*time.Minute)) {
		t.Fatalf("second save: %+v superseded %v", a2, sup)
	}
	if st := repoDocStatus(t, pg, tenant, a1.EditID); st != RepoDocSuperseded {
		t.Fatalf("folded row is %s", st)
	}
	// 9 min after the first save: due at the cap (10 min), not 11 min.
	a3, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", path), now.Add(9*time.Minute))
	if !a3.NextTryAt.Equal(now.Add(10 * time.Minute)) {
		t.Fatalf("cap: next_try_at %s, want %s", a3.NextTryAt, now.Add(10*time.Minute))
	}

	// Never joins two authors, nor member and agent, nor two agents.
	b, sup := repoDocInsert(t, pg, repoDocSave(tenant, "hum-b", path), now.Add(9*time.Minute))
	if len(sup) != 0 {
		t.Fatalf("another author folded %v", sup)
	}
	ag := repoDocSave(tenant, "hum-a", path)
	ag.ActorKind, ag.AgentID = "agent", "c-001"
	ag1, sup := repoDocInsert(t, pg, ag, now.Add(9*time.Minute))
	if len(sup) != 0 {
		t.Fatalf("agent edit folded the member's %v", sup)
	}
	ag2 := repoDocSave(tenant, "hum-a", path)
	ag2.ActorKind, ag2.AgentID = "agent", "c-002"
	if _, sup = repoDocInsert(t, pg, ag2, now.Add(9*time.Minute)); len(sup) != 0 {
		t.Fatalf("another agent folded %v", sup)
	}
	ag3 := repoDocSave(tenant, "hum-a", path)
	ag3.ActorKind, ag3.AgentID = "agent", "c-001"
	if _, sup = repoDocInsert(t, pg, ag3, now.Add(9*time.Minute)); len(sup) != 1 || sup[0] != ag1.EditID {
		t.Fatalf("same agent and requester: superseded %v, want %s", sup, ag1.EditID)
	}
	// A changed identity of the same member is a new author: no fold.
	re := repoDocSave(tenant, "hum-a", path)
	re.AuthorEmail = "other@example.com"
	if _, sup = repoDocInsert(t, pg, re, now.Add(9*time.Minute)); len(sup) != 0 {
		t.Fatalf("changed identity folded %v", sup)
	}
	if st := repoDocStatus(t, pg, tenant, b.EditID); st != RepoDocQueued {
		t.Fatalf("other author's row is %s", st)
	}
	if st := repoDocStatus(t, pg, tenant, a3.EditID); st != RepoDocQueued {
		t.Fatalf("member's row is %s", st)
	}
}

// TestRepoDocClaimAndTransitions: claim takes due rows FIFO per path, a
// pushing row freezes its path, and every worker verdict moves only a
// pushing row.
func TestRepoDocClaimAndTransitions(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant := repoDocTenant(t, pg)
	now := repoDocNow()
	p1, p2 := "doc/"+uid("p1-")+".md", "doc/"+uid("p2-")+".md"

	x1, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p1), now)
	x2, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-b", p1), now.Add(time.Second))
	y1, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p2), now.Add(5*time.Minute))

	if got := claimMine(t, pg, now.Add(time.Minute), p1, p2); len(got) != 0 {
		t.Fatalf("claimed rows not yet due: %+v", got)
	}
	got := claimMine(t, pg, now.Add(3*time.Minute), p1, p2)
	if len(got) != 1 || got[0].EditID != x1.EditID || got[0].Status != RepoDocPushing {
		t.Fatalf("claim: want only %s (FIFO on p1), got %+v", x1.EditID, got)
	}
	if got = claimMine(t, pg, now.Add(3*time.Minute), p1, p2); len(got) != 0 {
		t.Fatalf("pushing row did not freeze its path: %+v", got)
	}
	// A save during a push is a new queued row, never folded into it.
	if _, sup := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p1), now.Add(3*time.Minute)); len(sup) != 0 {
		t.Fatalf("a save folded a pushing row: %v", sup)
	}

	if _, err := pg.PushedRepoDocEdit(ctx, x1.EditID, "c0ffee", "", now.Add(4*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.PushedRepoDocEdit(ctx, x1.EditID, "c0ffee", "", now); !errors.Is(err, ErrConflict) {
		t.Fatalf("second verdict on a pushed row: %v, want ErrConflict", err)
	}
	got = claimMine(t, pg, now.Add(8*time.Minute), p1, p2)
	if len(got) != 2 || got[0].EditID != x2.EditID || got[1].EditID != y1.EditID {
		t.Fatalf("claim after push: want %s then %s, got %+v", x2.EditID, y1.EditID, got)
	}

	// Transient: queued again after the backoff, tries counted.
	r, err := pg.RetryLaterRepoDocEdit(ctx, x2.EditID, "github 502", now.Add(8*time.Minute))
	if err != nil || r.Status != RepoDocQueued || r.Tries != 1 || r.LastError != "github 502" ||
		!r.NextTryAt.Equal(now.Add(8*time.Minute+30*time.Second)) {
		t.Fatalf("retry later: %+v %v", r, err)
	}
	// Conflict and permanent failure.
	if c, err := pg.ConflictRepoDocEdit(ctx, y1.EditID, "same lines", now.Add(9*time.Minute)); err != nil || c.Status != RepoDocConflict {
		t.Fatalf("conflict: %+v %v", c, err)
	}
	if _, err := pg.FailRepoDocEdit(ctx, y1.EditID, "x", now); !errors.Is(err, ErrConflict) {
		t.Fatalf("fail on a conflict row: %v", err)
	}
	// The author's new save supersedes their conflict row.
	if _, sup := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p2), now.Add(10*time.Minute)); len(sup) != 1 || sup[0] != y1.EditID {
		t.Fatalf("re-save after conflict superseded %v", sup)
	}

	// Published: the pushed row of the commit.
	pushed, err := pg.PushedRepoDocEdits(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, e := range pushed {
		found = found || e.EditID == x1.EditID
	}
	if !found {
		t.Fatalf("PushedRepoDocEdits lacks %s", x1.EditID)
	}
	if n, err := pg.PublishRepoDocEdits(ctx, []string{"c0ffee"}, now.Add(20*time.Minute)); err != nil || n < 1 {
		t.Fatalf("publish: %d %v", n, err)
	}
	if st := repoDocStatus(t, pg, tenant, x1.EditID); st != RepoDocPublished {
		t.Fatalf("published row is %s", st)
	}
}

// TestRepoDocRetriesSpent: the eighth transient error fails the row; the
// editor's retry queues it again with its tries reset.
func TestRepoDocRetriesSpent(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant := repoDocTenant(t, pg)
	now := repoDocNow()
	path := "doc/" + uid("r-") + ".md"
	e, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", path), now)
	if _, err := pg.RetryRepoDocEdit(ctx, tenant, e.EditID, now); !errors.Is(err, ErrConflict) {
		t.Fatalf("retry of a queued row: %v, want ErrConflict", err)
	}
	at := now.Add(3 * time.Minute)
	for i := 0; i <= len(RepoDocBackoff); i++ {
		if got := claimMine(t, pg, at, path); len(got) != 1 {
			t.Fatalf("try %d: claim %+v", i, got)
		}
		r, err := pg.RetryLaterRepoDocEdit(ctx, e.EditID, "timeout", at)
		if err != nil {
			t.Fatal(err)
		}
		if i < len(RepoDocBackoff) {
			if r.Status != RepoDocQueued || !r.NextTryAt.Equal(at.Add(RepoDocBackoff[i])) {
				t.Fatalf("try %d: %+v", i, r)
			}
			at = r.NextTryAt
		} else if r.Status != RepoDocFailed {
			t.Fatalf("after %d tries: %s, want failed", r.Tries, r.Status)
		}
	}
	r, err := pg.RetryRepoDocEdit(ctx, tenant, e.EditID, at)
	if err != nil || r.Status != RepoDocQueued || r.Tries != 0 || !r.NextTryAt.Equal(at) {
		t.Fatalf("retry: %+v %v", r, err)
	}
	if _, err := pg.RetryRepoDocEdit(ctx, tenant, uuid4(), at); !errors.Is(err, ErrNotFound) {
		t.Fatalf("retry of an unknown edit: %v", err)
	}
}

// TestRepoDocReclaim: a row stuck in pushing goes back to queued, due now;
// a fresh pushing row stays.
func TestRepoDocReclaim(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant := repoDocTenant(t, pg)
	now := repoDocNow()
	p1, p2 := "doc/"+uid("s1-")+".md", "doc/"+uid("s2-")+".md"
	old, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p1), now)
	if got := claimMine(t, pg, now.Add(3*time.Minute), p1); len(got) != 1 {
		t.Fatalf("claim old: %+v", got)
	}
	fresh, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p2), now.Add(20*time.Minute))
	if got := claimMine(t, pg, now.Add(23*time.Minute), p2); len(got) != 1 {
		t.Fatalf("claim fresh: %+v", got)
	}
	got, err := pg.ReclaimRepoDocEdits(ctx, now.Add(15*time.Minute), now.Add(24*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].EditID != old.EditID || got[0].Status != RepoDocQueued || !got[0].NextTryAt.Equal(now.Add(24*time.Minute)) {
		t.Fatalf("reclaim: %+v", got)
	}
	if st := repoDocStatus(t, pg, tenant, fresh.EditID); st != RepoDocPushing {
		t.Fatalf("fresh row is %s", st)
	}
	if _, err := pg.PushedRepoDocEdit(ctx, old.EditID, "beef", "", now); !errors.Is(err, ErrConflict) {
		t.Fatalf("verdict of the dead worker on a reclaimed row: %v", err)
	}
}

// TestRepoDocRatesAndMyEdits: the counts of spec 5.1 (agent edits count to
// the requester), "My edits" with the requester's agents' edits, and a
// workspace reads only its own rows.
func TestRepoDocRatesAndMyEdits(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant, other := repoDocTenant(t, pg), repoDocTenant(t, pg)
	now := repoDocNow()
	path := "doc/" + uid("m-") + ".md"
	envBefore, err := pg.RepoDocEditsEnvDay(ctx, now.Add(-24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}

	old, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", "doc/"+uid("o-")+".md"), now.Add(-2*time.Hour))
	own, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", path), now.Add(-time.Minute))
	ag := repoDocSave(tenant, "hum-a", path)
	ag.ActorKind, ag.AgentID = "agent", "c-009"
	agent, _ := repoDocInsert(t, pg, ag, now)
	repoDocInsert(t, pg, repoDocSave(tenant, "hum-b", path), now)
	foreign, _ := repoDocInsert(t, pg, repoDocSave(other, "hum-a", path), now)

	r, err := pg.RepoDocEditRates(ctx, tenant, "hum-a", "c-009", now)
	if err != nil {
		t.Fatal(err)
	}
	if r != (RepoDocRates{MemberHour: 2, AgentHour: 1, WorkspaceDay: 4}) {
		t.Fatalf("rates: %+v", r)
	}
	if r, _ = pg.RepoDocEditRates(ctx, tenant, "hum-a", "", now); r.AgentHour != 0 {
		t.Fatalf("no agent counted %d", r.AgentHour)
	}
	envAfter, err := pg.RepoDocEditsEnvDay(ctx, now.Add(-24*time.Hour))
	if err != nil || envAfter-envBefore != 5 {
		t.Fatalf("env day: %d -> %d (%v), want +5 across both workspaces", envBefore, envAfter, err)
	}

	mine, err := pg.ListRepoDocEdits(ctx, tenant, RepoDocEditFilter{HumanID: "hum-a"})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, e := range mine {
		ids = append(ids, e.EditID)
	}
	if want := []string{agent.EditID, own.EditID, old.EditID}; strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Fatalf("My edits: %v, want newest first %v", ids, want)
	}
	byPath, err := pg.ListRepoDocEdits(ctx, tenant, RepoDocEditFilter{Path: path, Limit: 2})
	if err != nil || len(byPath) != 2 {
		t.Fatalf("path filter with limit: %d %v", len(byPath), err)
	}
	for _, e := range append(mine, byPath...) {
		if e.TenantID != tenant {
			t.Fatalf("workspace read another's row: %+v", e)
		}
	}
	if _, err := pg.GetRepoDocEdit(ctx, tenant, foreign.EditID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("read another workspace's edit: %v", err)
	}
	if _, err := pg.RetryRepoDocEdit(ctx, tenant, foreign.EditID, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("retry of another workspace's edit: %v", err)
	}
	if _, _, err := pg.InsertRepoDocEdit(ctx, RepoDocEdit{}, time.Minute, time.Minute, now); !errors.Is(err, ErrNoTenant) {
		t.Fatalf("insert without a tenant: %v", err)
	}
}

// TestRepoDocAuthorsNoticesKnown: the mapping row, the agents opt-out, the
// per-identity consent and the history's identities.
func TestRepoDocAuthorsNoticesKnown(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant, other := repoDocTenant(t, pg), repoDocTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)

	if _, err := pg.GetRepoDocAuthor(ctx, tenant, "hum-a"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no mapping: %v", err)
	}
	if err := pg.SetRepoDocAllowAgents(ctx, tenant, "hum-a", false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("opt-out without a row: %v", err)
	}
	a := RepoDocAuthor{TenantID: tenant, HumanID: "hum-a", GitName: "FirstName LastName", GitEmail: "a@example.com",
		VerifiedAt: now, AllowAgents: true}
	if err := pg.PutRepoDocAuthor(ctx, a); err != nil {
		t.Fatal(err)
	}
	a.GitEmail = "b@example.com"
	if err := pg.PutRepoDocAuthor(ctx, a); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetRepoDocAllowAgents(ctx, tenant, "hum-a", false); err != nil {
		t.Fatal(err)
	}
	got, err := pg.GetRepoDocAuthor(ctx, tenant, "hum-a")
	a.AllowAgents = false
	if err != nil || got != a {
		t.Fatalf("mapping: %+v %v, want %+v", got, err, a)
	}
	if _, err := pg.GetRepoDocAuthor(ctx, other, "hum-a"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("another workspace read the mapping: %v", err)
	}
	if err := pg.DeleteRepoDocAuthor(ctx, tenant, "hum-a"); err != nil {
		t.Fatal(err)
	}
	if err := pg.DeleteRepoDocAuthor(ctx, tenant, "hum-a"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v", err)
	}

	has := func(tn, name, email string) bool {
		ok, err := pg.HasRepoDocAuthorNotice(ctx, tn, "hum-a", name, email)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	if has(tenant, "FirstName LastName", "a@example.com") {
		t.Fatal("consent before the ack")
	}
	for i := 0; i < 2; i++ {
		if err := pg.AckRepoDocAuthorNotice(ctx, tenant, "hum-a", "FirstName LastName", "a@example.com", now); err != nil {
			t.Fatal(err)
		}
	}
	if !has(tenant, "FirstName LastName", "a@example.com") {
		t.Fatal("ack not recorded")
	}
	if has(tenant, "FirstName LastName", "b@example.com") || has(tenant, "Other Name", "a@example.com") {
		t.Fatal("a changed identity reused the consent")
	}
	if has(other, "FirstName LastName", "a@example.com") {
		t.Fatal("another workspace saw the consent")
	}

	email := uid("k-") + "@example.com"
	if err := pg.ReplaceRepoDocKnownAuthors(ctx, []RepoDocKnownAuthor{{GitEmail: email, GitName: "FirstName LastName"}}, now); err != nil {
		t.Fatal(err)
	}
	k, err := pg.LookupRepoDocKnownAuthor(ctx, " "+strings.ToUpper(email)+" ")
	if err != nil || k.GitEmail != email || !k.SeenAt.Equal(now) {
		t.Fatalf("known author: %+v %v", k, err)
	}
	if err := pg.ReplaceRepoDocKnownAuthors(ctx, nil, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.LookupRepoDocKnownAuthor(ctx, email); err != nil {
		t.Fatalf("an empty refresh wiped the history: %v", err)
	}
	other2 := uid("k-") + "@example.com"
	if err := pg.ReplaceRepoDocKnownAuthors(ctx, []RepoDocKnownAuthor{{GitEmail: other2, GitName: "Other Name"}}, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.LookupRepoDocKnownAuthor(ctx, email); !errors.Is(err, ErrNotFound) {
		t.Fatalf("an identity gone from history stayed: %v", err)
	}
}
