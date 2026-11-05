package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

// Spec 114 T002a (P10, control C10) on testkit Postgres: the own-workspace
// reads name the tenant, so a document another workspace shared with this
// one never enters its own list, head or search. T002's share DDL is not on
// the tree yet, so the test plants the same shape for its run: a grant
// table and a permissive SELECT policy on workspace_doc and
// workspace_doc_item, as bench/share-grant.sql's share_read, with one
// accepted grant. RED CONTROL: drop "d.tenant_id = $4" from wsDocHeadSQL or
// "i.tenant_id = $4" from DocSearch and the shared doc shows up.
//
//	go test ./internal/store -run 'WorkspaceDocOwnReads' -v   (SPOOL_TEST_PG_DSN)

// shareProbeDDL is the planted share_read; the grant table carries no
// tenant_id, so RLS reads it unfiltered, as the policy's sub-select needs.
var shareProbeDDL = []string{
	`CREATE TABLE t002a_share_probe (doc_id uuid NOT NULL, to_tenant text NOT NULL, accepted_at timestamptz NULL)`,
	`CREATE POLICY t002a_share_read ON workspace_doc FOR SELECT USING (id = ANY (ARRAY(
		SELECT s.doc_id FROM t002a_share_probe s
		 WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '') AND s.accepted_at IS NOT NULL)))`,
	`CREATE POLICY t002a_share_read ON workspace_doc_item FOR SELECT USING (doc_id = ANY (ARRAY(
		SELECT s.doc_id FROM t002a_share_probe s
		 WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '') AND s.accepted_at IS NOT NULL)))`,
}

// plantShareProbe creates the planted share_read and drops it at the end.
func plantShareProbe(t *testing.T, pg *Postgres) {
	t.Helper()
	ctx := context.Background()
	drop := func() {
		for _, q := range []string{`DROP POLICY IF EXISTS t002a_share_read ON workspace_doc`,
			`DROP POLICY IF EXISTS t002a_share_read ON workspace_doc_item`, `DROP TABLE IF EXISTS t002a_share_probe`} {
			if _, err := pg.Pool().Exec(ctx, q); err != nil {
				t.Errorf("%s: %v", q, err)
			}
		}
	}
	drop()
	t.Cleanup(drop)
	for _, q := range shareProbeDDL {
		if _, err := pg.Pool().Exec(ctx, q); err != nil {
			t.Fatalf("plant share_read: %v", err)
		}
	}
}

// ownReads is what the receiving workspace's own list and search answer.
func ownReads(t *testing.T, pg *Postgres, tenant, word string) ([]DocHead, []DocHit) {
	t.Helper()
	ctx := context.Background()
	heads, err := pg.DocList(ctx, tenant, "", 1000)
	if err != nil {
		t.Fatalf("DocList: %v", err)
	}
	hits, err := pg.DocSearch(ctx, tenant, "", word, 100)
	if err != nil {
		t.Fatalf("DocSearch: %v", err)
	}
	return heads, hits
}

func headIDs(hs []DocHead) string {
	out := ""
	for _, h := range hs {
		out += fmt.Sprintf("%s(%s) ", h.ID, h.TenantID)
	}
	return out
}

func hitIDs(hs []DocHit) string {
	out := ""
	for _, h := range hs {
		out += fmt.Sprintf("%s/%s(%s) ", h.DocID, h.ItemID, h.TenantID)
	}
	return out
}

// TestWorkspaceDocOwnReadsShareGrant: one accepted grant of owner's doc to
// the receiver; the receiver's DocList, DocHeadOf and DocSearch are the
// same as before it, each row labelled with the receiver as its owner,
// while DocSubtree, unfiltered by design, reads the shared doc.
func TestWorkspaceDocOwnReadsShareGrant(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	owner, recv := newTenant(t, pg), newTenant(t, pg)
	const word = "quokkashare"
	mk := func(tenant, title string) string {
		doc, root, err := pg.DocCreateIn(ctx, tenant, "", title, "", "t")
		if err != nil {
			t.Fatalf("create %s in %s: %v", title, tenant, err)
		}
		if _, err := pg.DocItemAdd(ctx, tenant, DocItemAddReq{DocID: doc, Anchor: root, Where: DocChild,
			Title: word + " " + title, Body: word + " body", Actor: "t"}); err != nil {
			t.Fatalf("item in %s: %v", tenant, err)
		}
		return doc
	}
	shared, own := mk(owner, "shared"), mk(recv, "own")
	plantShareProbe(t, pg)
	headsBefore, hitsBefore := ownReads(t, pg, recv, word)
	if len(headsBefore) != 1 || headsBefore[0].ID != own || headsBefore[0].TenantID != recv {
		t.Fatalf("before the grant: DocList(%s) = %s, want only %s(%s)", recv, headIDs(headsBefore), own, recv)
	}
	if len(hitsBefore) != 1 || hitsBefore[0].DocID != own || hitsBefore[0].TenantID != recv {
		t.Fatalf("before the grant: DocSearch(%s) = %s, want one hit in %s(%s)", recv, hitIDs(hitsBefore), own, recv)
	}

	if _, err := pg.Pool().Exec(ctx, `INSERT INTO t002a_share_probe (doc_id, to_tenant, accepted_at) VALUES ($1, $2, now())`,
		shared, recv); err != nil {
		t.Fatalf("seed the grant: %v", err)
	}
	// The grant is live: RLS now admits the shared doc and its items to the
	// receiver, so whatever keeps them out below is the store's own filter.
	if n := countIn(t, pg, recv, `SELECT count(*) FROM workspace_doc WHERE id = $1`, shared); n != 1 {
		t.Fatalf("planted share_read: the receiver reads %d rows of the shared doc, want 1 (test is vacuous)", n)
	}
	if n := countIn(t, pg, recv, `SELECT count(*) FROM workspace_doc_item WHERE doc_id = $1`, shared); n < 2 {
		t.Fatalf("planted share_read: the receiver reads %d items of the shared doc, want root + 1", n)
	}

	headsAfter, hitsAfter := ownReads(t, pg, recv, word)
	if headIDs(headsAfter) != headIDs(headsBefore) {
		t.Errorf("P10 DocList(%s) changed by the grant: %s, want %s", recv, headIDs(headsAfter), headIDs(headsBefore))
	}
	if hitIDs(hitsAfter) != hitIDs(hitsBefore) {
		t.Errorf("P10 DocSearch(%s) changed by the grant: %s, want %s", recv, hitIDs(hitsAfter), hitIDs(hitsBefore))
	}
	if _, err := pg.DocHeadOf(ctx, recv, shared); !errors.Is(err, ErrDocNotFound) {
		t.Errorf("P10 DocHeadOf(%s, shared doc) = %v, want ErrDocNotFound", recv, err)
	}
	if items, err := pg.DocSubtree(ctx, recv, shared, ""); err != nil || len(items) < 2 {
		t.Errorf("DocSubtree(%s, shared doc) = %d items, %v: want it readable, RLS decides", recv, len(items), err)
	}
	// The owner's own reads label its doc with itself.
	if h, err := pg.DocHeadOf(ctx, owner, shared); err != nil || h.TenantID != owner {
		t.Errorf("DocHeadOf(%s, its doc) = %q, %v: want TenantID %s", owner, h.TenantID, err, owner)
	}
}
