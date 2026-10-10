package store

import (
	"bytes"
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// TestEmbedVisitorRelink (specs/121 T206): a visitor leaves an address, is
// found by it and by its id with its current token hash, and the relink
// swaps that hash once: the old token is dead, the new one names the same
// visitor and channel, and a second swap from the old hash (a reused link)
// is ErrNotFound. An expired visitor (a block, the sweep) is found by
// neither key, keeps no address change and never relinks. The owner's list
// holds only the visitors with an address, of its own workspace.
func TestEmbedVisitorRelink(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a, b := newTenant(t, pg), newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	va, ha := mintVisitor(t, rt, a, embed, now)
	vb, hb := mintVisitor(t, rt, a, embed, now)
	mintVisitor(t, rt, a, embed, now) // no address: never listed
	for v, e := range map[*EmbedVisitor]string{&va: "a@example.com", &vb: "b@example.com"} {
		if err := rt.SetEmbedVisitorEmail(ctx, *v, e, now); err != nil {
			t.Fatal(err)
		}
	}
	for what, k := range map[string]EmbedRelinkKey{"address": {Email: "a@example.com"}, "id": {VisitorID: va.VisitorID}} {
		got, hash, err := rt.EmbedRelinkVisitor(ctx, embed, k, now)
		if err != nil || got.VisitorID != va.VisitorID || got.Email != "a@example.com" || !bytes.Equal(hash, ha) {
			t.Errorf("by %s: %+v %x (%v), want A with its token hash", what, got, hash, err)
		}
	}
	for what, k := range map[string]EmbedRelinkKey{"neither": {}, "both": {Email: "a@example.com", VisitorID: va.VisitorID},
		"an unknown address": {Email: "z@example.com"}, "an unknown id": {VisitorID: "00000000-0000-4000-8000-000000000000"}} {
		if _, _, err := rt.EmbedRelinkVisitor(ctx, embed, k, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("by %s: %v, want ErrNotFound", what, err)
		}
	}
	if _, _, err := rt.EmbedRelinkVisitor(ctx, seedEmbedCustomer(t, pg, a, true), EmbedRelinkKey{Email: "a@example.com"}, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("another embed: %v, want ErrNotFound", err)
	}

	fresh := newTokenHash(t)
	got, err := rt.RelinkEmbedVisitor(ctx, va, ha, fresh, testEmbedLife, now.Add(time.Minute))
	if err != nil || got.VisitorID != va.VisitorID || got.ChannelID != va.ChannelID || !got.LastSeenAt.Equal(now.Add(time.Minute)) {
		t.Fatalf("relink: %+v (%v)", got, err)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, ha, now.Add(time.Minute)); !errors.Is(err, ErrNotFound) {
		t.Errorf("the old token after the relink: %v, want ErrNotFound", err)
	}
	if v, err := rt.EmbedVisitorByToken(ctx, embed, fresh, now.Add(time.Minute)); err != nil || v.VisitorID != va.VisitorID {
		t.Errorf("the new token: %+v (%v), want A", v, err)
	}
	if _, err := rt.RelinkEmbedVisitor(ctx, va, ha, newTokenHash(t), testEmbedLife, now.Add(2*time.Minute)); !errors.Is(err, ErrNotFound) {
		t.Errorf("a second swap from the old hash (a reused link): %v, want ErrNotFound", err)
	}

	if err := rt.ExpireEmbedVisitor(ctx, vb, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	later := now.Add(2 * time.Minute)
	if _, _, err := rt.EmbedRelinkVisitor(ctx, embed, EmbedRelinkKey{Email: "b@example.com"}, later); !errors.Is(err, ErrNotFound) {
		t.Errorf("an expired visitor by its address: %v, want ErrNotFound", err)
	}
	if _, err := rt.RelinkEmbedVisitor(ctx, vb, hb, newTokenHash(t), testEmbedLife, later); !errors.Is(err, ErrNotFound) {
		t.Errorf("an expired visitor relinked: %v, want ErrNotFound", err)
	}
	if err := rt.SetEmbedVisitorEmail(ctx, vb, "c@example.com", later); !errors.Is(err, ErrNotFound) {
		t.Errorf("an expired visitor's address set: %v, want ErrNotFound", err)
	}

	list, err := pg.EmbedVisitorEmails(ctx, a, embed)
	emails := []string{}
	for _, e := range list {
		emails = append(emails, e.Email)
	}
	sort.Strings(emails)
	if err != nil || len(emails) != 2 || emails[0] != "a@example.com" || emails[1] != "b@example.com" {
		t.Errorf("the owner's list = %v (%v), want a@ and b@ only", emails, err)
	}
	if other, err := pg.EmbedVisitorEmails(ctx, b, embed); err != nil || len(other) != 0 {
		t.Errorf("another workspace lists %+v (%v), want none", other, err)
	}
	if err := rt.SetEmbedVisitorEmail(ctx, got, "", later); err != nil {
		t.Fatal(err)
	}
	if list, _ := pg.EmbedVisitorEmails(ctx, a, embed); len(list) != 1 || list[0].Email != "b@example.com" {
		t.Errorf("after A cleared its address: %+v, want b@ only", list)
	}
}

// TestEmbedRelinkPathNeverInTenant: every relink method a visitor request
// reaches runs under inChannel or a reviewed operator read, never the
// workspace scope (spec 4.2), as TestEmbedVisitorPathNeverInTenant for
// T104's. CONTROL: the owner's list, a staff read, does reach the workspace
// scope, so the walk can see one.
func TestEmbedRelinkPathNeverInTenant(t *testing.T) {
	g := storeCallGraph(t)
	for _, fn := range embedRelinkPath {
		if g[fn] == nil {
			t.Fatalf("%s is in embedRelinkPath but not defined", fn)
		}
		r := reach(g, fn)
		for name := range r {
			if tenantScopeEntries[name] || name == "pgScopeTenant" {
				t.Errorf("relink path %s reaches the workspace scope through %s: use inChannel", fn, name)
			}
		}
		if !r["inChannel"] && !r["asOperatorQuery"] {
			t.Errorf("relink path %s reaches neither inChannel nor a reviewed operator read", fn)
		}
		if _, ok := operatorCallers[fn]; r["asOperatorQuery"] && !ok {
			t.Errorf("relink path %s reads as operator but is not a reviewed operatorCallers entry", fn)
		}
	}
	if !reach(g, "EmbedVisitorEmails")["queryTenant"] {
		t.Fatal("CONTROL: the walk from EmbedVisitorEmails does not reach queryTenant")
	}
}
