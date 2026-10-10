package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

var testEmbedLife = EmbedTokenLife{Sliding: 30 * 24 * time.Hour, Cap: 180 * 24 * time.Hour}

const day = 24 * time.Hour

// newTokenHash is the sha256 of a fresh 256-bit token, as the hub stores it.
func newTokenHash(t *testing.T) []byte {
	t.Helper()
	tok := make([]byte, 32)
	if _, err := rand.Read(tok); err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(tok)
	return h[:]
}

func mintVisitor(t *testing.T, s *Postgres, tenant, embed string, now time.Time) (EmbedVisitor, []byte) {
	t.Helper()
	hash := newTokenHash(t)
	v, err := s.MintEmbedVisitor(context.Background(), EmbedVisitorMint{TenantID: tenant, EmbedID: embed, TokenHash: hash, Life: testEmbedLife}, now)
	if err != nil {
		t.Fatal(err)
	}
	return v, hash
}

// TestInChannelRefusesNoChannel: inChannel refuses, before Postgres, a scope
// that would read as "no channel scope" ("") or open a channel every member
// shares (lobby, tasks, alerts, the general alias, the issue discussions),
// and a missing workspace. CONTROL: a visitor channel id passes the check.
func TestInChannelRefusesNoChannel(t *testing.T) {
	s := &Postgres{} // no pool: a refusal must come before any statement
	ran := false
	fn := func(pgx.Tx) error { ran = true; return nil }
	for _, ch := range []string{"", "lobby", "tasks", "alerts", ChannelGeneralAlias, "Not A Slug", "v-" + strings.Repeat("a", 70)} {
		if err := s.inChannel(context.Background(), "t-1", ch, fn); !errors.Is(err, ErrNoChannel) {
			t.Errorf("inChannel(%q) = %v, want ErrNoChannel", ch, err)
		}
	}
	if err := s.inChannel(context.Background(), " ", "v-0123456789abcdef", fn); !errors.Is(err, ErrNoTenant) {
		t.Errorf("inChannel without a workspace = %v, want ErrNoTenant", err)
	}
	if ran {
		t.Error("fn ran under a refused scope")
	}
	ch, err := newVisitorChannelID()
	if err != nil || checkChannel(ch) != nil {
		t.Fatalf("CONTROL: a fresh visitor channel %q is refused (%v, %v)", ch, err, checkChannel(ch))
	}
}

// TestEmbedVisitorMint: the runtime role mints a visitor in one transaction:
// a channel_guest HUM with no e-mail, its channel_guest membership, a private
// channel it created, its channel_humans row and the visitor row; the token
// hash finds it, any other key does not. A disabled or unknown embed mints
// nothing.
func TestEmbedVisitorMint(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	v, hash := mintVisitor(t, rt, a, embed, now)
	if v.TenantID != a || v.EmbedID != embed || v.VisitorID == "" || !strings.HasPrefix(v.HumanID, "HUM-") ||
		checkChannel(v.ChannelID) != nil || !v.CreatedAt.Equal(now) || !v.ExpiresAt.Equal(now.Add(30*day)) {
		t.Fatalf("minted %+v", v)
	}
	var kind, role, createdBy, addedBy string
	var email *string
	var private bool
	err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT h.kind, h.email, m.role, c.created_by, c.is_private, ch.added_by
			FROM humans h JOIN tenant_memberships m ON m.human_id = h.human_id AND m.tenant_id = $1
			JOIN channels c ON c.tenant_id = $1 AND c.channel_id = $3
			JOIN channel_humans ch ON ch.tenant_id = $1 AND ch.channel_id = $3 AND ch.human_id = h.human_id
			WHERE h.human_id = $2`, a, v.HumanID, v.ChannelID).Scan(&kind, &email, &role, &createdBy, &private, &addedBy)
	})
	if err != nil || kind != "channel_guest" || email != nil || role != rbac.ChannelGuest || createdBy != v.HumanID || !private || addedBy != "embed" {
		t.Fatalf("the mint wrote kind=%s email=%v role=%s created_by=%s private=%v added_by=%s (%v)", kind, email, role, createdBy, private, addedBy, err)
	}

	if got, err := rt.EmbedVisitorByToken(ctx, embed, hash, now.Add(time.Minute)); err != nil || got != v {
		t.Errorf("lookup by its token = %+v, %v; want %+v", got, err, v)
	}
	for what, k := range map[string]struct {
		embed string
		hash  []byte
		at    time.Time
	}{
		"another embed":    {seedEmbedCustomer(t, pg, a, true), hash, now},
		"another token":    {embed, newTokenHash(t), now},
		"after its expiry": {embed, hash, v.ExpiresAt},
	} {
		if _, err := rt.EmbedVisitorByToken(ctx, k.embed, k.hash, k.at); !errors.Is(err, ErrNotFound) {
			t.Errorf("lookup with %s: %v, want ErrNotFound", what, err)
		}
	}

	off := seedEmbedCustomer(t, pg, a, false)
	before := countOf(t, pg, "embed_visitors", a)
	for _, e := range []string{off, uid("e-")} {
		if _, err := rt.MintEmbedVisitor(ctx, EmbedVisitorMint{TenantID: a, EmbedID: e, TokenHash: newTokenHash(t), Life: testEmbedLife}, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("mint on embed %s: %v, want ErrNotFound", e, err)
		}
	}
	if n := countOf(t, pg, "embed_visitors", a); n != before {
		t.Errorf("a refused mint wrote: %d visitors, want %d", n, before)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE embed_customers SET enabled = false WHERE embed_id = $1`, embed)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, hash, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("lookup once its embed is disabled: %v, want ErrNotFound", err)
	}
}

// TestEmbedVisitorSlideAndExpire: each request slides the expiry 30 days
// from now, never past 180 days after the mint; an expired token never
// slides back to life; Expire ends a live token at once.
func TestEmbedVisitorSlideAndExpire(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, t0 := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	v, hash := mintVisitor(t, rt, a, embed, t0)
	for _, c := range []struct{ at, want time.Duration }{
		{10 * day, 40 * day}, {35 * day, 65 * day}, {60 * day, 90 * day}, {85 * day, 115 * day},
		{110 * day, 140 * day}, {135 * day, 165 * day}, {160 * day, 180 * day}, {179 * day, 180 * day},
	} {
		got, err := rt.SlideEmbedVisitor(ctx, v, testEmbedLife, t0.Add(c.at))
		if err != nil || !got.ExpiresAt.Equal(t0.Add(c.want)) || !got.LastSeenAt.Equal(t0.Add(c.at)) {
			t.Fatalf("slide at day %d: expires day %d, seen %v (%v), want expires day %d", c.at/day, got.ExpiresAt.Sub(t0)/day, got.LastSeenAt, err, c.want/day)
		}
	}
	if _, err := rt.SlideEmbedVisitor(ctx, v, testEmbedLife, t0.Add(180*day)); !errors.Is(err, ErrNotFound) {
		t.Errorf("slide at the cap: %v, want ErrNotFound", err)
	}

	w, whash := mintVisitor(t, rt, a, embed, t0)
	if err := rt.ExpireEmbedVisitor(ctx, w, t0.Add(day)); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, whash, t0.Add(day)); !errors.Is(err, ErrNotFound) {
		t.Errorf("lookup after Expire: %v, want ErrNotFound", err)
	}
	if _, err := rt.SlideEmbedVisitor(ctx, w, testEmbedLife, t0.Add(day)); !errors.Is(err, ErrNotFound) {
		t.Errorf("slide after Expire: %v, want ErrNotFound", err)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, hash, t0.Add(180*day)); !errors.Is(err, ErrNotFound) {
		t.Errorf("the first visitor's token, expired at the cap, still looks up: %v", err)
	}
}

// TestInChannelIsolatesVisitors: two visitors of one workspace, plus a staff
// channel, lobby and a DM. Visitor A's channel scope, as the runtime role,
// reads only A's channel: one message, one channel, one membership row, one
// visitor row; and it cannot slide or expire visitor B, even handed B's id.
// CONTROL: the same reads and the same forged write under inTenant reach B,
// the staff channel, lobby and the DM, so the zeros are the scope's.
func TestInChannelIsolatesVisitors(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	va, _ := mintVisitor(t, rt, a, embed, now)
	vb, bhash := mintVisitor(t, rt, a, embed, now)
	staff := uid("s-")
	if err := pg.CreateChannel(ctx, Channel{TenantID: a, ChannelID: staff, Name: staff, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := pg.AddChannelHumans(ctx, a, staff, []string{"HUM-1"}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	for _, ch := range []string{va.ChannelID, vb.ChannelID, staff, "lobby", ""} {
		m := msgFor(a, uuid4(), "box-a", now, now, "env-"+ch)
		m.Channel = ch
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	reads := []struct{ name, sql string }{
		{"messages", `SELECT count(*), count(*) FILTER (WHERE channel IS DISTINCT FROM $1) FROM messages`},
		{"channels", `SELECT count(*), count(*) FILTER (WHERE channel_id <> $1) FROM channels`},
		{"channel_humans", `SELECT count(*), count(*) FILTER (WHERE channel_id <> $1) FROM channel_humans`},
		{"embed_visitors", `SELECT count(*), count(*) FILTER (WHERE channel_id <> $1) FROM embed_visitors`},
	}
	// forged: visitor B's id under A's scope, as a bug in a caller might pass.
	forged := EmbedVisitor{TenantID: a, ChannelID: va.ChannelID, VisitorID: vb.VisitorID}
	err := rt.inChannel(ctx, a, va.ChannelID, func(tx pgx.Tx) error {
		for _, r := range reads {
			var all, off int
			if err := tx.QueryRow(ctx, r.sql, va.ChannelID).Scan(&all, &off); err != nil {
				return err
			}
			if all != 1 || off != 0 {
				t.Errorf("%s: A's scope reads %d rows, %d off its channel (want 1, 0)", r.name, all, off)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rt.SlideEmbedVisitor(ctx, forged, testEmbedLife, now.Add(day)); !errors.Is(err, ErrNotFound) {
		t.Errorf("A's scope slid visitor B: %v, want ErrNotFound", err)
	}
	if err := rt.ExpireEmbedVisitor(ctx, forged, now); err != nil {
		t.Fatal(err)
	}
	if got, err := rt.EmbedVisitorByToken(ctx, embed, bhash, now.Add(time.Minute)); err != nil || !got.ExpiresAt.Equal(vb.ExpiresAt) {
		t.Errorf("A's scope moved visitor B: %+v, %v", got, err)
	}

	// CONTROL: the workspace scope, same runtime role, reaches all of it.
	rolledBack := errors.New("rollback")
	err = rt.inTenant(ctx, a, func(tx pgx.Tx) error {
		for _, r := range reads {
			var all, off int
			if err := tx.QueryRow(ctx, r.sql, va.ChannelID).Scan(&all, &off); err != nil {
				return err
			}
			if off == 0 {
				t.Errorf("CONTROL: %s: the workspace scope reads %d rows, none off A's channel: the seed proves nothing", r.name, all)
			}
		}
		tag, err := tx.Exec(ctx, `UPDATE embed_visitors SET expires_at = $3 WHERE tenant_id = $1 AND visitor_id = $2::uuid`, a, vb.VisitorID, now)
		if err == nil && tag.RowsAffected() != 1 {
			t.Errorf("CONTROL: the forged write reaches %d rows under the workspace scope, want 1", tag.RowsAffected())
		}
		if err != nil {
			return err
		}
		return rolledBack
	})
	if !errors.Is(err, rolledBack) {
		t.Fatal(err)
	}
	// The scope is transaction-local: the pool's next workspace read sees all.
	if n := countOf(t, rt, "messages", a); n != 5 {
		t.Errorf("after inChannel the workspace scope reads %d messages, want 5", n)
	}
}

// tenantScopeEntries set the workspace scope without a channel: a visitor
// request must reach none of them (spec 4.2).
var tenantScopeEntries = map[string]bool{"inTenant": true, "tenantBatch": true, "execTenant": true,
	"queryRowTenant": true, "queryTenant": true, "queryTenantBatch": true}

// storeCallGraph maps each function or method name of this package's
// non-test files to the names it calls or references (methods of the same
// name on Memory and Postgres merge: over-reach, never under-reach).
func storeCallGraph(t *testing.T) map[string]map[string]bool {
	t.Helper()
	fset := token.NewFileSet()
	files, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	g := map[string]map[string]bool{}
	for _, f := range files {
		if !strings.HasSuffix(f.Name(), ".go") || strings.HasSuffix(f.Name(), "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f.Name(), nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			calls := g[fd.Name.Name]
			if calls == nil {
				calls = map[string]bool{}
				g[fd.Name.Name] = calls
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				switch x := n.(type) {
				case *ast.SelectorExpr:
					calls[x.Sel.Name] = true
				case *ast.Ident:
					calls[x.Name] = true
				}
				return true
			})
		}
	}
	return g
}

// reach is every name reachable from root through g.
func reach(g map[string]map[string]bool, root string) map[string]bool {
	seen := map[string]bool{root: true}
	todo := []string{root}
	for len(todo) > 0 {
		fn := todo[len(todo)-1]
		todo = todo[:len(todo)-1]
		for c := range g[fn] {
			if !seen[c] {
				seen[c] = true
				todo = append(todo, c)
			}
		}
	}
	return seen
}

// TestEmbedVisitorPathNeverInTenant (T102 done line): no method a visitor
// request reaches (embedVisitorPath) can reach the workspace scope (any
// tenantScopeEntries function, or pgScopeTenant itself); each reaches
// inChannel or a reviewed operator read. CONTROL: the same walk from the
// staff list EmbedCustomers does reach queryTenant, so the walker sees a
// workspace scope when there is one.
func TestEmbedVisitorPathNeverInTenant(t *testing.T) {
	g := storeCallGraph(t)
	for _, fn := range embedVisitorPath {
		if g[fn] == nil {
			t.Fatalf("%s is in embedVisitorPath but not defined: the walk reads the wrong files", fn)
		}
		r := reach(g, fn)
		var bad []string
		for name := range r {
			if tenantScopeEntries[name] || name == "pgScopeTenant" {
				bad = append(bad, name)
			}
		}
		sort.Strings(bad)
		if len(bad) > 0 {
			t.Errorf("visitor path %s reaches the workspace scope through %v: use inChannel", fn, bad)
		}
		if !r["inChannel"] && !r["asOperatorQuery"] {
			t.Errorf("visitor path %s reaches neither inChannel nor a reviewed operator read", fn)
		}
		if r["asOperatorQuery"] {
			if _, ok := operatorCallers[fn]; !ok {
				t.Errorf("visitor path %s reads as operator but is not a reviewed operatorCallers entry", fn)
			}
		}
	}
	if !reach(g, "EmbedCustomers")["queryTenant"] {
		t.Fatal("CONTROL: the walk from EmbedCustomers does not reach queryTenant: it cannot see a workspace scope")
	}
}
