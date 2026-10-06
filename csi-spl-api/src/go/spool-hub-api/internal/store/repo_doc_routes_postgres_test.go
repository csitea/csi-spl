package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The reads of the Repo Docs edit routes (spec 075 repo-edit T08) on Postgres.

// TestRepoDocSeatHumanOfConsumedToken: an agent seat made by a join token
// names that token's member (spec §4.3 e); a seat of no such token, a token
// not consumed, or one of another workspace names nobody.
func TestRepoDocSeatHumanOfConsumedToken(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant, other := repoDocTenant(t, pg), repoDocTenant(t, pg)
	now := time.Now().UTC()
	token := func(tid, hash, forHuman, box string, consumed bool) {
		t.Helper()
		if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			var at *time.Time
			if consumed {
				at = &now
			}
			_, err := tx.Exec(ctx, `INSERT INTO agent_join_tokens (token_hash, tenant_id, created_by, for_human, expires_at, consumed_at, consumed_box)
				VALUES (encode(sha256(convert_to($1, 'UTF8')), 'hex'), $2, 'HUM-1', NULLIF($3, ''), $4, $5, NULLIF($6, ''))`,
				hash, tid, forHuman, now.Add(time.Hour), at, box)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	token(tenant, tenant+"-a", "HUM-7", "box-a", true)
	token(tenant, tenant+"-b", "HUM-8", "box-b", false)
	token(tenant, tenant+"-c", "", "box-c", true)
	token(other, other+"-a", "HUM-9", "box-a", true)
	for box, want := range map[string]string{"box-a": "HUM-7", "box-b": "", "box-c": "", "box-z": ""} {
		if got, err := pg.RepoDocSeatHuman(ctx, tenant, box); err != nil || got != want {
			t.Errorf("seat %s: %q %v, want %q", box, got, err, want)
		}
	}
	if got, _ := pg.RepoDocSeatHuman(ctx, other, "box-a"); got != "HUM-9" {
		t.Errorf("the other workspace's seat: %q", got)
	}
}

// TestRepoDocOverlaysNewestLive: the newest row per path that is neither
// superseded nor failed, of every workspace (the docs bucket is the env's).
func TestRepoDocOverlaysNewestLive(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tenant, other := repoDocTenant(t, pg), repoDocTenant(t, pg)
	now := repoDocNow()
	p, q := "csi-spl-doc/"+tenant+"/a.md", "csi-spl-doc/"+tenant+"/b.md"
	a1, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p), now)
	a2, _ := repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", p), now.Add(time.Second)) // supersedes a1
	b1, _ := repoDocInsert(t, pg, repoDocSave(other, "hum-b", p), now.Add(2*time.Second))
	repoDocInsert(t, pg, repoDocSave(tenant, "hum-a", q), now)
	rows, err := pg.RepoDocOverlays(ctx, p)
	if err != nil || len(rows) != 1 || rows[0].EditID != b1.EditID {
		t.Fatalf("newest of %s across workspaces: %+v %v (a1 %s a2 %s)", p, rows, err, a1.EditID, a2.EditID)
	}
	if _, err := pg.execTenant(ctx, other, `UPDATE repo_doc_edits SET status = 'failed' WHERE edit_id::text = $1`, b1.EditID); err != nil {
		t.Fatal(err)
	}
	if rows, _ = pg.RepoDocOverlays(ctx, p); len(rows) != 1 || rows[0].EditID != a2.EditID {
		t.Fatalf("a failed edit is skipped: %+v", rows)
	}
	all, err := pg.RepoDocOverlays(ctx, "")
	n := 0
	for _, e := range all {
		if e.Path == p || e.Path == q {
			n++
		}
	}
	if err != nil || n != 2 {
		t.Fatalf("every path: %d of ours, %v", n, err)
	}
}

func TestRepoDocPersonUnknown(t *testing.T) {
	pg := pgOnly(t)
	tenant := repoDocTenant(t, pg)
	if _, err := pg.RepoDocPerson(context.Background(), tenant, "HUM-999999999"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown human: %v", err)
	}
}
