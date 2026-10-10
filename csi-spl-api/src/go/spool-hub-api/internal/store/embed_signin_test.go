package store

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// specs/121 T205: the store side of the signed-in customer (embed_signin.go).

func signIn(t *testing.T, s *Postgres, tenant, embed, sub string, now time.Time) (EmbedVisitor, []byte) {
	t.Helper()
	hash := newTokenHash(t)
	v, err := s.SignInEmbedVisitor(context.Background(), EmbedVisitorMint{TenantID: tenant, EmbedID: embed, TokenHash: hash, Life: testEmbedLife}, sub, now)
	if err != nil {
		t.Fatalf("sign in %s: %v", sub, err)
	}
	return v, hash
}

// TestEmbedSignInOneVisitorPerSub: (embed, sub) is one channel_guest. A
// second sign-in of the same sub is the same visitor, HUM and channel with a
// new token (the old one stops working) and a fresh 30 days. CONTROL: another
// sub, and the same sub on another embed, are other visitors; a disabled or
// unknown embed writes nothing.
func TestEmbedSignInOneVisitorPerSub(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)

	v1, h1 := signIn(t, rt, a, embed, "user-42", now)
	if v1.EmbedID != embed || checkChannel(v1.ChannelID) != nil || !v1.ExpiresAt.Equal(now.Add(30*day)) {
		t.Fatalf("first sign-in %+v", v1)
	}
	later := now.Add(200 * day) // past the first token's 180-day cap
	v2, h2 := signIn(t, rt, a, embed, "user-42", later)
	if v2.VisitorID != v1.VisitorID || v2.HumanID != v1.HumanID || v2.ChannelID != v1.ChannelID {
		t.Fatalf("second sign-in of one sub is another visitor: %+v vs %+v", v2, v1)
	}
	if !v2.ExpiresAt.Equal(later.Add(30 * day)) {
		t.Errorf("second sign-in expires %v, want %v", v2.ExpiresAt, later.Add(30*day))
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, h1, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("the replaced token still names the visitor: %v", err)
	}
	if got, err := rt.EmbedVisitorByToken(ctx, embed, h2, later); err != nil || got.VisitorID != v1.VisitorID {
		t.Errorf("the new token: %+v, %v", got, err)
	}

	other, _ := signIn(t, rt, a, embed, "user-43", now)
	embed2 := seedEmbedCustomer(t, pg, a, true)
	elsewhere, _ := signIn(t, rt, a, embed2, "user-42", now)
	for what, v := range map[string]EmbedVisitor{"another sub": other, "another embed": elsewhere} {
		if v.VisitorID == v1.VisitorID || v.ChannelID == v1.ChannelID || v.HumanID == v1.HumanID {
			t.Errorf("CONTROL %s shares the visitor: %+v", what, v)
		}
	}

	before := countOf(t, pg, "embed_visitors", a)
	for _, e := range []string{seedEmbedCustomer(t, pg, a, false), uid("e-")} {
		_, err := rt.SignInEmbedVisitor(ctx, EmbedVisitorMint{TenantID: a, EmbedID: e, TokenHash: newTokenHash(t), Life: testEmbedLife}, "user-42", now)
		if !errors.Is(err, ErrNotFound) {
			t.Errorf("sign-in on embed %s: %v, want ErrNotFound", e, err)
		}
	}
	if n := countOf(t, pg, "embed_visitors", a); n != before {
		t.Errorf("a refused sign-in wrote: %d visitors, want %d", n, before)
	}
}

// TestEmbedSignInNeverInTenant: the signed-in path is a visitor path (spec
// 4.2): SignInEmbedVisitor reaches inChannel and never the workspace scope.
// CONTROL: the same walk from EmbedCustomers reaches queryTenant.
func TestEmbedSignInNeverInTenant(t *testing.T) {
	g := storeCallGraph(t)
	r := reach(g, "SignInEmbedVisitor")
	var bad []string
	for name := range r {
		if tenantScopeEntries[name] || name == "pgScopeTenant" {
			bad = append(bad, name)
		}
	}
	sort.Strings(bad)
	if len(bad) > 0 || !r["inChannel"] || r["asOperatorQuery"] {
		t.Errorf("SignInEmbedVisitor reaches %v; inChannel=%v operator=%v", bad, r["inChannel"], r["asOperatorQuery"])
	}
	if !reach(g, "EmbedCustomers")["queryTenant"] {
		t.Fatal("CONTROL: the walk from EmbedCustomers does not reach queryTenant")
	}
}
