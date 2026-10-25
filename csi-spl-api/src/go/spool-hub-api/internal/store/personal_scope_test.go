package store

import (
	"context"
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
)

// specs/119 7.2, tasks.md T002: the person scope is set in one place and
// never mixed with a tenant scope.

// personCallers is every store method that runs in the person scope
// (inPerson), with what it reads or writes. A new caller fails
// TestPersonScopeCallers until it is added here, i.e. reviewed: its person
// must come from the authenticated human session only.
var personCallers = map[string]string{
	"RealmProfileOf":      "personal.profile of the session's own person",
	"PutRealmProfile":     "personal.profile of the session's own person",
	"AppendRealmLimits":   "personal.settings of the session's own person (118 C3)",
	"RealmLimitsHistory":  "personal.settings of the session's own person",
	"RealmLimitsOn":       "personal.settings of the session's own person",
	"RealmReceipts":       "personal.hours_receipts of the session's own person (118 C5, C6)",
	"DeleteRealmReceipts": "personal.delete_my_receipts, the person's own erasure (8.3, OQ-4 A)",
	"appendRealmReceipts": "personal.hours_receipts rev 0 + receipt_due of the leaver, the receipt copy's step 2 (8.1, T004)",
	// spec 155 B3: the notes store, personal.notes / note_items / note_links
	// of the session's own person; no notes method opens a tenant scope.
	"ListNotes":      "personal.notes + counts of note_items, note_links of the session's own person (155 section 5)",
	"CreateNote":     "personal.notes, note_items, note_links of the session's own person, the 2 000-note cap (155 C8)",
	"NoteOf":         "personal.notes, note_items, note_links of the session's own person",
	"PatchNote":      "personal.notes + the D4 label erase in note_links of the session's own person",
	"DeleteNote":     "personal.notes of the session's own person; items and links cascade",
	"PutNoteItems":   "personal.note_items (+ D4 in note_links) of the session's own person",
	"AddNoteLink":    "personal.note_links of the session's own person, the 100-link cap",
	"PatchNoteLink":  "personal.note_links of the session's own person",
	"DeleteNoteLink": "personal.note_links of the session's own person",
	"ExportNotes":    "personal.notes, note_items, note_links of the session's own person (155 2.8 export)",
	"EraseNotes":     "personal.notes of the session's own person (155 2.8 erase)",
}

// realmTenantCallers is the realm code allowed to ALSO run a tenant scope,
// each in its own transaction, never nested (spec 7.2, 8.1): the 118 read
// (one inTenant per workspace, then one inPerson) and the receipt copy
// (inTenant for the leaver's hours, then inPerson to write the receipt).
// The receipt copy (T004, copyRealmReceipts) opens no scope itself: its
// step 1 is 107's own store reads and its step 2 is appendRealmReceipts
// above, so it is not listed here. Spec 118 adds its read here.
var realmTenantCallers = map[string]string{}

// realmForeignScopes set app.tenant_id or the operator scope (a wider
// list than embed_visitors_test.go's tenantScopeEntries): every
// function that opens such a scope, directly or as one batch.
var realmForeignScopes = map[string]bool{
	"inTenant": true, "inChannel": true, "inMember": true, "tenantBatch": true, "memberBatch": true,
	"scopeBatch": true, "execTenant": true, "queryRowTenant": true, "queryTenant": true,
	"queryTenantBatch": true, "execMember": true, "queryMember": true,
	"asOperator": true, "asOperatorQuery": true, "asOperatorInTx": true,
}

// calledName is the function a call expression names (x.f or f), or "".
func calledName(c *ast.CallExpr) string {
	switch f := c.Fun.(type) {
	case *ast.SelectorExpr:
		return f.Sel.Name
	case *ast.Ident:
		return f.Name
	}
	return ""
}

// personScopeScan is what TestPersonScopeCallers checks, from parsed
// non-test files: the callers of inPerson, the realm functions that also
// open a tenant scope, and every rule broken.
type personScopeScan struct {
	callers, mixed map[string]bool
	defined        bool
	bad            []string
}

func scanPersonScope(files map[string]*ast.File) personScopeScan {
	sc := personScopeScan{callers: map[string]bool{}, mixed: map[string]bool{}}
	for name, af := range files {
		realmFile := strings.HasPrefix(name, "personal")
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			fn := fd.Name.Name
			if fn == "inPerson" {
				sc.defined = true
				continue
			}
			person, tenant := false, false
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if id, ok := n.(*ast.Ident); ok && id.Name == "pgScopePerson" {
					sc.bad = append(sc.bad, fn+" sets the person scope directly (pgScopePerson): use inPerson")
				}
				c, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				switch called := calledName(c); {
				case called == "inPerson":
					person = true
					sc.bad = append(sc.bad, nestedIn(fn, "inPerson", c, realmForeignScopes)...)
				case realmForeignScopes[called]:
					tenant = true
					sc.bad = append(sc.bad, nestedIn(fn, called, c, map[string]bool{"inPerson": true})...)
				}
				return true
			})
			if person {
				sc.callers[fn] = true
			}
			if tenant && (person || realmFile) {
				sc.mixed[fn] = true
			}
		}
	}
	return sc
}

// nestedIn names each call of a forbidden scope inside the arguments of
// call c (its fn closure): a scope opened inside the other's transaction.
func nestedIn(fn, outer string, c *ast.CallExpr, forbidden map[string]bool) []string {
	var bad []string
	for _, a := range c.Args {
		ast.Inspect(a, func(n ast.Node) bool {
			if in, ok := n.(*ast.CallExpr); ok && forbidden[calledName(in)] {
				bad = append(bad, fn+" nests "+calledName(in)+" inside "+outer)
			}
			return true
		})
	}
	return bad
}

// parseStoreFiles parses this package's non-test files, by file name.
func parseStoreFiles(t *testing.T) map[string]*ast.File {
	t.Helper()
	fset := token.NewFileSet()
	ents, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]*ast.File{}
	for _, e := range ents {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		out[name] = af
	}
	return out
}

// diffKeys is the names in found but not in want, and in want but not found.
func diffKeys(found map[string]bool, want map[string]string) (extra, gone []string) {
	for fn := range found {
		if _, ok := want[fn]; !ok {
			extra = append(extra, fn)
		}
	}
	for fn := range want {
		if !found[fn] {
			gone = append(gone, fn)
		}
	}
	sort.Strings(extra)
	sort.Strings(gone)
	return extra, gone
}

// TestPersonScopeCallers pins pgScopePerson to inPerson, the callers of
// inPerson to personCallers, and the realm code that also opens a tenant
// scope to realmTenantCallers; no function nests one scope in the other.
// CONTROL: inPerson's own definition is found, and a planted source that
// nests inTenant inside inPerson, sets pgScopePerson directly and mixes the
// scopes in a realm file turns each rule red.
func TestPersonScopeCallers(t *testing.T) {
	files := parseStoreFiles(t)
	sc := scanPersonScope(files)
	if !sc.defined {
		t.Fatal("control: inPerson's definition was not found - the scan reads the wrong files")
	}
	for _, b := range sc.bad {
		t.Error(b)
	}
	if extra, gone := diffKeys(sc.callers, personCallers); len(extra)+len(gone) > 0 {
		t.Errorf("inPerson callers: new %v (add each to personCallers with what it reads), gone %v (drop them)", extra, gone)
	}
	if extra, gone := diffKeys(sc.mixed, realmTenantCallers); len(extra)+len(gone) > 0 {
		t.Errorf("realm code opening a tenant or operator scope: new %v (spec 119 7.2 allows only the 118 read and the receipt copy), gone %v", extra, gone)
	}
	// The raw setting is named in rls.go alone (tasks.md T002 Done).
	for name := range files {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if name != "rls.go" && strings.Contains(string(b), "app.person_id") {
			t.Errorf("%s names app.person_id: only rls.go's inPerson sets the person scope", name)
		}
	}

	plant := `package store
func (s *Postgres) PlantNested(ctx context.Context) error {
	return s.inPerson(ctx, "HUM-1", func(tx pgx.Tx) error {
		return s.inTenant(ctx, "t", func(pgx.Tx) error { return nil })
	})
}
func (s *Postgres) PlantRaw(ctx context.Context, tx pgx.Tx) { tx.Exec(ctx, pgScopePerson, "HUM-1") }
func (s *Postgres) PlantMixed(ctx context.Context) { s.execTenant(ctx, "t", "SELECT 1") }`
	af, err := parser.ParseFile(token.NewFileSet(), "personal_plant.go", plant, 0)
	if err != nil {
		t.Fatal(err)
	}
	files["personal_plant.go"] = af
	red := scanPersonScope(files)
	joined := strings.Join(red.bad, "\n")
	for _, w := range []string{"PlantNested nests inTenant inside inPerson", "PlantRaw sets the person scope directly"} {
		if !strings.Contains(joined, w) {
			t.Errorf("control: %q stayed green:\n%s", w, joined)
		}
	}
	if !red.mixed["PlantNested"] || !red.mixed["PlantMixed"] || !red.callers["PlantNested"] {
		t.Errorf("control: the planted realm callers were not seen: callers %v mixed %v", red.callers, red.mixed)
	}
}

// refusedPersons are refused before any SQL (spec 11 T-N7).
var refusedPersons = []string{"", "AGT-1", "HUM-1; --", "hum-1", " HUM-1", "HUM-", "HUM-1\n"}

// realmCalls calls every Realm method for person; each returns its error.
func realmCalls(st Realm, person string) map[string]error {
	ctx := context.Background()
	now := time.Now()
	day := 480
	_, e1 := st.RealmProfileOf(ctx, person)
	_, e2 := st.RealmLimitsHistory(ctx, person)
	_, _, e3 := st.RealmLimitsOn(ctx, person, "2026-10-01")
	_, e4 := st.RealmReceipts(ctx, person)
	_, e5 := st.DeleteRealmReceipts(ctx, person, "ws-1")
	return map[string]error{
		"RealmProfileOf":      e1,
		"RealmLimitsHistory":  e2,
		"RealmLimitsOn":       e3,
		"RealmReceipts":       e4,
		"DeleteRealmReceipts": e5,
		"PutRealmProfile":     st.PutRealmProfile(ctx, person, RealmProfile{TimeZone: "UTC"}, now),
		"AppendRealmLimits":   st.AppendRealmLimits(ctx, person, RealmLimits{ValidFrom: "2026-10-01", DayLimitMinutes: &day}, now),
	}
}

// TestInPersonRefusesBeforeSQL is T-N7's store half: inPerson and every
// realm method refuse "", an agent id and an injection with ErrNoPerson
// before any SQL. The Postgres has no pool, so any statement would panic.
// CONTROL: a valid person on that Postgres does reach the pool (it panics),
// so a refusal here is the check, not an absent connection.
func TestInPersonRefusesBeforeSQL(t *testing.T) {
	ctx := context.Background()
	nopool := &Postgres{}
	for _, p := range refusedPersons {
		ran := false
		err := nopool.inPerson(ctx, p, func(pgx.Tx) error { ran = true; return nil })
		if !errors.Is(err, ErrNoPerson) || ran {
			t.Errorf("inPerson(%q): err %v ran %v, want ErrNoPerson before fn", p, err, ran)
		}
		for name, st := range map[string]Realm{"postgres": nopool, "memory": NewMemory()} {
			for call, err := range realmCalls(st, p) {
				if !errors.Is(err, ErrNoPerson) {
					t.Errorf("%s %s(%q): err %v, want ErrNoPerson", name, call, p, err)
				}
			}
		}
	}
	reached := func() (r any) {
		defer func() { r = recover() }()
		_ = nopool.inPerson(ctx, "HUM-1", func(pgx.Tx) error { return nil })
		return nil
	}()
	if reached == nil {
		t.Error("control: a valid person on a Postgres with no pool did not reach the pool")
	}
}
