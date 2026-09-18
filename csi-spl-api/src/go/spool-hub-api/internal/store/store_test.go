package store

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// sqlDir is csi-spl-rdb/src/sql/postgres/spool-hub, relative to this file,
// unless $SPOOL_TEST_SQL_DIR overrides it.
func sqlDir(t *testing.T) string {
	if d := os.Getenv("SPOOL_TEST_SQL_DIR"); d != "" {
		return d
	}
	_, f, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "..", "..", "csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
}

// drivers returns every Store the contract suite runs against: Memory always,
// Postgres when $SPOOL_TEST_PG_DSN names a database (hub-pg.tst.sh sets it).
func drivers(t *testing.T) map[string]Store {
	out := map[string]Store{"memory": NewMemory()}
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		return out
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatalf("postgres: %v", err)
	}
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(pg.Close)
	out["postgres"] = pg
	return out
}

func uid(prefix string) string {
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	return prefix + hex.EncodeToString(b)
}

func uuid4() string {
	b := make([]byte, 16)
	rand.Read(b) //nolint:errcheck
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}

func pubkey() ed25519.PublicKey {
	pub, _, _ := ed25519.GenerateKey(nil)
	return pub
}

func newTenant(t *testing.T, s Store) string {
	id := uid("t-")
	if err := s.CreateTenant(context.Background(), Tenant{ID: id, RootPubKey: pubkey()}); err != nil {
		t.Fatal(err)
	}
	return id
}

func msgFor(tenant, task, toBox string, ts, now time.Time, env string) Message {
	return Message{
		TenantID: tenant, MsgID: uuid4(), TaskID: task, TS: ts,
		FromBox: "box-a", FromID: "GRK-03", ToBox: toBox, ToID: "CLE-07", Kind: "task", Body: "hi",
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte(env),
		ReceivedAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
}

func TestTenantsAndPins(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			root := pubkey()
			tid := uid("t-")
			if err := s.CreateTenant(ctx, Tenant{ID: tid, RootPubKey: root}); err != nil {
				t.Fatal(err)
			}
			if err := s.CreateTenant(ctx, Tenant{ID: tid, RootPubKey: root}); err != nil {
				t.Fatalf("same root must be idempotent: %v", err)
			}
			if err := s.CreateTenant(ctx, Tenant{ID: tid, RootPubKey: pubkey()}); !errors.Is(err, ErrConflict) {
				t.Fatalf("different root: want conflict, got %v", err)
			}
			if _, err := s.GetTenant(ctx, uid("nope-")); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown tenant: %v", err)
			}

			k1, k2 := pubkey(), pubkey()
			if err := s.PutPin(ctx, tid, "box-a", k1, false, now); err != nil {
				t.Fatal(err)
			}
			if err := s.PutPin(ctx, tid, "box-a", k1, false, now); err != nil {
				t.Fatalf("same key re-pin: %v", err)
			}
			if err := s.PutPin(ctx, tid, "box-a", k2, false, now); !errors.Is(err, ErrConflict) {
				t.Fatalf("different key without force: %v", err)
			}
			if err := s.PutPin(ctx, tid, "box-a", k2, true, now); err != nil {
				t.Fatalf("force: %v", err)
			}
			got, err := s.GetPin(ctx, tid, "box-a")
			if err != nil || !got.Equal(k2) {
				t.Fatalf("GetPin after force: %v", err)
			}
			if err := s.PutPin(ctx, uid("nope-"), "box-a", k1, false, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("pin in unknown tenant: %v", err)
			}
			if err := s.RevokePin(ctx, tid, "box-a", now); err != nil {
				t.Fatal(err)
			}
			if _, err := s.GetPin(ctx, tid, "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("revoked pin still active: %v", err)
			}
			pins, _ := s.ListPins(ctx, tid)
			if len(pins) != 0 {
				t.Fatalf("revoked pin listed: %v", pins)
			}
			reasons := pinHistoryReasons(t, s, tid, "box-a")
			if fmt.Sprint(reasons) != "[pin pin force revoke]" {
				t.Fatalf("pins_history reasons = %v, want [pin pin force revoke]", reasons)
			}
		})
	}
}

func TestRosterIsPerBox(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC()
			tid := newTenant(t, s)
			if err := s.SetRoster(ctx, tid, "box-a", []string{"GRK-03", "CLE-07"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-b", []string{"CLE-07"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-a", []string{"GRK-03"}, now); err != nil {
				t.Fatal(err)
			}
			r, _ := s.Roster(ctx, tid)
			if fmt.Sprint(r) != "map[box-a:[GRK-03] box-b:[CLE-07]]" {
				t.Fatalf("roster = %v", r)
			}
			other := newTenant(t, s)
			if r, _ := s.Roster(ctx, other); len(r) != 0 {
				t.Fatalf("roster leaked across tenants: %v", r)
			}
		})
	}
}

// delivery state transitions: queued → sent (claim), sent → queued (unclaim),
// queued → expired (TTL sweep and per-box cap); idempotent ingest (FR-010).
func TestMessagesAndDeliveries(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			task := uuid4()
			m := msgFor(tid, task, "box-b", now, now, `{"e":1}`)

			if ins, err := s.InsertMessage(ctx, m); err != nil || !ins {
				t.Fatalf("insert: %v %v", ins, err)
			}
			if ins, err := s.InsertMessage(ctx, m); err != nil || ins {
				t.Fatalf("identical replay must be a no-op: %v %v", ins, err)
			}
			d := m
			d.Env = []byte(`{"e":2}`)
			if _, err := s.InsertMessage(ctx, d); !errors.Is(err, ErrConflict) {
				t.Fatalf("different canonical: want conflict, got %v", err)
			}
			other := newTenant(t, s)
			m2 := m
			m2.TenantID = other
			if ins, err := s.InsertMessage(ctx, m2); err != nil || !ins {
				t.Fatalf("same msg_id in another tenant must be independent: %v %v", ins, err)
			}

			ttl := now.Add(7 * 24 * time.Hour)
			if err := s.Enqueue(ctx, tid, m.MsgID, "box-b", now, ttl, 1000); err != nil {
				t.Fatal(err)
			}
			if st, _ := s.DeliveryState(ctx, tid, m.MsgID, "box-b"); st != StateQueued {
				t.Fatalf("state = %q, want queued", st)
			}
			q, _ := s.QueuedFor(ctx, tid, "box-b", now)
			if len(q) != 1 || string(q[0].Env) != `{"e":1}` {
				t.Fatalf("queued = %+v", q)
			}
			if ok, _ := s.ClaimSent(ctx, tid, m.MsgID, "box-b", now); !ok {
				t.Fatal("claim failed")
			}
			if ok, _ := s.ClaimSent(ctx, tid, m.MsgID, "box-b", now); ok {
				t.Fatal("double claim succeeded")
			}
			if err := s.Unclaim(ctx, tid, m.MsgID, "box-b"); err != nil {
				t.Fatal(err)
			}
			if st, _ := s.DeliveryState(ctx, tid, m.MsgID, "box-b"); st != StateQueued {
				t.Fatalf("after unclaim: %q", st)
			}

			// Per-box cap: 3 queued with cap 2 → the oldest expires.
			var ids []string
			for i := 0; i < 3; i++ {
				mi := msgFor(tid, task, "box-c", now.Add(time.Duration(i+1)*time.Second), now, fmt.Sprintf(`{"c":%d}`, i))
				s.InsertMessage(ctx, mi) //nolint:errcheck
				if err := s.Enqueue(ctx, tid, mi.MsgID, "box-c", now.Add(time.Duration(i)*time.Second), ttl, 2); err != nil {
					t.Fatal(err)
				}
				ids = append(ids, mi.MsgID)
			}
			if st, _ := s.DeliveryState(ctx, tid, ids[0], "box-c"); st != StateExpired {
				t.Fatalf("cap: oldest is %q, want expired", st)
			}
			if q, _ := s.QueuedFor(ctx, tid, "box-c", now); len(q) != 2 {
				t.Fatalf("cap: %d queued, want 2", len(q))
			}

			// TTL sweep.
			res, err := s.Sweep(ctx, ttl.Add(time.Second))
			if err != nil {
				t.Fatal(err)
			}
			if res.Expired < 3 {
				t.Fatalf("sweep expired %d, want ≥3", res.Expired)
			}
			if st, _ := s.DeliveryState(ctx, tid, m.MsgID, "box-b"); st != StateExpired {
				t.Fatalf("after TTL: %q", st)
			}
			if ok, _ := s.ClaimSent(ctx, tid, m.MsgID, "box-b", ttl.Add(time.Second)); ok {
				t.Fatal("claimed an expired delivery")
			}

			envs, _ := s.TaskEnvelopes(ctx, tid, task)
			if len(envs) != 4 || string(envs[0]) != `{"e":1}` {
				t.Fatalf("task envelopes = %d %q", len(envs), envs)
			}

			// Retention purge (30 days).
			res, _ = s.Sweep(ctx, now.Add(31*24*time.Hour))
			if res.Purged < 4 {
				t.Fatalf("purged %d, want ≥4", res.Purged)
			}
			if envs, _ := s.TaskEnvelopes(ctx, tid, task); len(envs) != 0 {
				t.Fatalf("messages survived retention: %d", len(envs))
			}
		})
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pg.Close()
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	res, err := Migrate(ctx, pg.Pool(), sqlDir(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range res {
		if !a.Skipped {
			t.Fatalf("re-run applied %s again", a.File)
		}
	}

	// A changed, already-applied file is refused.
	dir := t.TempDir()
	files, _ := filepath.Glob(filepath.Join(sqlDir(t), "*.sql"))
	for _, f := range files {
		raw, _ := os.ReadFile(f)
		os.WriteFile(filepath.Join(dir, filepath.Base(f)), append(raw, []byte("\n-- edited\n")...), 0o644) //nolint:errcheck
	}
	if _, err := Migrate(ctx, pg.Pool(), dir); err == nil {
		t.Fatal("edited applied migration was accepted")
	}
}

func pinHistoryReasons(t *testing.T, s Store, tenant, box string) []string {
	t.Helper()
	switch x := s.(type) {
	case *Memory:
		var out []string
		for _, h := range x.history {
			if h.tenant == tenant && h.box == box {
				out = append(out, h.reason)
			}
		}
		return out
	case *Postgres:
		rows, err := x.Pool().Query(context.Background(),
			`SELECT reason FROM pins_history WHERE tenant_id = $1 AND box_id = $2 ORDER BY at, ctid`, tenant, box)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var r string
			if err := rows.Scan(&r); err != nil {
				t.Fatal(err)
			}
			out = append(out, r)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		return out
	default:
		t.Fatalf("unknown store %T", s)
		return nil
	}
}

// T001: boxes/pins/pins_history live in csi-spl-rdb SQL, not as Go store entities.
func TestPinSQLLivesInRDB(t *testing.T) {
	dir := sqlDir(t)
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("sql dir %s: %v %v", dir, files, err)
	}
	var all string
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		body := string(raw)
		if strings.Contains(body, "package store") || strings.Contains(body, "type Message") ||
			strings.Contains(body, "type Pin struct") {
			t.Fatalf("%s contains a Go store entity", f)
		}
		all += body + "\n"
	}
	for _, tbl := range []string{"boxes", "pins", "pins_history"} {
		if !strings.Contains(all, "CREATE TABLE "+tbl+" ") && !strings.Contains(all, "CREATE TABLE "+tbl+"\n") &&
			!strings.Contains(all, "CREATE TABLE "+tbl+" (") {
			t.Fatalf("rdb SQL is missing CREATE TABLE %s", tbl)
		}
	}
}
