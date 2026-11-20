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

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// rdb 0300 (spec 033 section K.5, build row T020, SPL-5884): the two CHECKs
// that list the message kinds take the seven new ones. Postgres only.
//
// The database is migrated through 0300. "Before" is the same file with the
// seven left out, which is the 0058 / 0060 text; it is applied in a
// rolled-back transaction, then the real file on top of it. Each narrowed
// CHECK is added NOT VALID: Postgres still enforces it on every INSERT and
// UPDATE, and it skips the rows other tests committed with a new kind.
//
//   - before (the red control): a message set to `bug` breaks
//     messages_kind_check, a kind change to `bug` breaks
//     message_kind_changes_kind_to_check; `blocker` passes both.
//   - after: the same two writes pass for each of the 13 kinds.
//   - committed, through the store (n=13): a message of each kind is
//     inserted, and a kind change to each kind is recorded.
const messageKindsSevenFile = "0300_message_kinds_seven.sql"

// thirteenKinds is the order of msg.KindList: the six old kinds, then the
// owner's seven (msg 890eadfb).
var thirteenKinds = []string{"task", "result", "note", "reject", "blocker", "msg",
	"feature", "bug", "alert", "question", "idea", "decision", "docs"}

var (
	sevenKindsRe = regexp.MustCompile(`,\s*'feature', 'bug', 'alert', 'question', 'idea', 'decision', 'docs'`)
	kindCheckRe  = regexp.MustCompile(`(?m)(CHECK \(kind(?:_to)? IN \([^)]*\)\));$`)
)

func TestMessageKindsSeven0300(t *testing.T) {
	if got := strings.Join(thirteenKinds, "|"); got != msg.KindList {
		t.Fatalf("the migration's kinds %q differ from msg.KindList %q", got, msg.KindList)
	}
	pg := rlsStore(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), messageKindsSevenFile))
	if err != nil {
		t.Fatal(err)
	}
	after := string(raw)
	before := sevenKindsRe.ReplaceAllString(after, "")
	if n := len(kindCheckRe.FindAllString(before, -1)); n != 2 || strings.Contains(before, "'bug'") {
		t.Fatalf("%s: the before text did not narrow both CHECKs (%d found)", messageKindsSevenFile, n)
	}
	before = kindCheckRe.ReplaceAllString(before, "$1 NOT VALID;")

	tenant := newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	seed := msgFor(tenant, uuid4(), "box-a", now, now, "env-"+uuid4())
	if _, err := pg.InsertMessage(ctx, seed); err != nil {
		t.Fatal(err)
	}
	beforeAndAfter(t, pg, tenant, seed.MsgID, before, after)

	// Committed, through the store: each of the 13 kinds is stored, and a
	// change to each kind is recorded in the register.
	for i, k := range thirteenKinds {
		at := now.Add(time.Duration(i+1) * time.Second)
		m := msgFor(tenant, uuid4(), "box-a", at, at, "env-"+uuid4())
		m.Kind = k
		if ins, err := pg.InsertMessage(ctx, m); err != nil || !ins {
			t.Fatalf("insert a %s message: %v %v", k, ins, err)
		}
		if k == seed.Kind {
			continue // the same kind records nothing
		}
		c, err := pg.SetKind(ctx, tenant, seed.MsgID, k, "HUM-1", at)
		if err != nil || c.To != k {
			t.Fatalf("kind change to %s: %+v %v", k, c, err)
		}
	}
	cs, err := pg.KindChanges(ctx, tenant, seed.MsgID)
	if err != nil || len(cs) != len(thirteenKinds)-1 {
		t.Fatalf("register: %d changes, want %d (%v)", len(cs), len(thirteenKinds)-1, err)
	}
}

// beforeAndAfter applies the narrowed text, then the real file, in one
// rolled-back transaction, and checks which writes each refuses.
func beforeAndAfter(t *testing.T, pg *Postgres, tenant, msgID, before, after string) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, q := range []string{pgScopeOperator, before} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("before text: %v", err)
		}
	}
	// try runs one write under a savepoint and returns the CHECK it broke, "" if it passed.
	try := func(kind, q string) string {
		t.Helper()
		sp, err := tx.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer sp.Rollback(ctx) //nolint:errcheck
		_, err = sp.Exec(ctx, q, tenant, msgID, kind)
		if err == nil {
			return ""
		}
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "23514" {
			t.Fatalf("%s: not a CHECK violation: %v", q, err)
		}
		return pe.ConstraintName
	}
	const setKind = `UPDATE messages SET kind = $3 WHERE tenant_id = $1 AND msg_id = $2`
	const change = `INSERT INTO message_kind_changes (tenant_id, msg_id, seq, kind_from, kind_to, set_by, set_at)
		VALUES ($1, $2, 1000, 'note', $3, 'HUM-1', now())`
	want := func(stage, kind, q, check string) {
		t.Helper()
		if got := try(kind, q); got != check {
			t.Fatalf("%s, kind %s: broke %q, want %q", stage, kind, got, check)
		}
	}
	want("before", "bug", setKind, "messages_kind_check")
	want("before", "bug", change, "message_kind_changes_kind_to_check")
	want("before", "blocker", setKind, "")
	want("before", "blocker", change, "")
	if _, err := tx.Exec(ctx, after); err != nil {
		t.Fatalf("%s on the before text: %v", messageKindsSevenFile, err)
	}
	for _, k := range thirteenKinds {
		want("after", k, setKind, "")
		want("after", k, change, "")
	}
}
