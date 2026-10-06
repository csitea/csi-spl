package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 098 (rdb 0136 tenants.settings): the generic workspace settings. The
// keys below exist only in this test binary.

const kvConcurrentKeys = 16

func init() {
	RegisterTenantSetting(TenantSettingDef{Key: "test.flag", Kind: SettingBool, Default: false})
	RegisterTenantSetting(TenantSettingDef{Key: "test.count", Kind: SettingInt, Default: 5, Min: 1, Max: 100})
	RegisterTenantSetting(TenantSettingDef{Key: "test.mode", Kind: SettingString, Default: "a", OneOf: []string{"a", "b"}})
	RegisterTenantSetting(TenantSettingDef{Key: "test.label", Kind: SettingString, Default: "", MaxLen: 8})
	for i := 0; i < kvConcurrentKeys; i++ {
		RegisterTenantSetting(TenantSettingDef{Key: fmt.Sprintf("test.k%02d", i), Kind: SettingInt, Default: 0})
	}
}

func TestTenantKV(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			kv := st.(TenantKV)
			ts := st.(TenantSettings)
			tid := newTenant(t, st)

			// A fresh tenant stores nothing and reads every default.
			tn, err := st.GetTenant(ctx, tid)
			if err != nil || len(tn.Settings) != 0 {
				t.Fatalf("fresh settings %v: %v", tn.Settings, err)
			}
			if tn.Settings.Bool("test.flag") || tn.Settings.Int("test.count") != 5 || tn.Settings.String("test.mode") != "a" {
				t.Fatalf("fresh defaults: %v", tn.Settings.Effective())
			}

			got, err := kv.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{
				"test.flag": true, "test.count": 42, "test.mode": "b"}})
			if err != nil || len(got) != 3 {
				t.Fatalf("set: %v %v", got, err)
			}
			// The cached row (the hot path) sees the write at once.
			tn, _ = st.GetTenant(ctx, tid)
			if !tn.Settings.Bool("test.flag") || tn.Settings.Int("test.count") != 42 || tn.Settings.String("test.mode") != "b" {
				t.Fatalf("after set, cached row: %v", tn.Settings)
			}
			cfg, err := ts.TenantConfig(ctx, tid)
			if err != nil || cfg.Settings.Int("test.count") != 42 {
				t.Fatalf("after set, TenantConfig: %v %v", cfg.Settings, err)
			}

			// Unset reverts one key to its default and keeps the others.
			if _, err := kv.SetTenantSettings(ctx, tid, TenantSettingsPatch{Unset: []string{"test.count"}}); err != nil {
				t.Fatal(err)
			}
			tn, _ = st.GetTenant(ctx, tid)
			if tn.Settings.Int("test.count") != 5 || !tn.Settings.Bool("test.flag") {
				t.Fatalf("after unset: %v", tn.Settings)
			}

			// Refused patches change nothing.
			for _, p := range []TenantSettingsPatch{
				{Set: map[string]any{"test.count": 0}},
				{Set: map[string]any{"test.count": 101}},
				{Set: map[string]any{"test.count": 1.5}},
				{Set: map[string]any{"test.count": "7"}},
				{Set: map[string]any{"test.flag": "true"}},
				{Set: map[string]any{"test.mode": "c"}},
				{Set: map[string]any{"test.label": "123456789"}},
				{Set: map[string]any{"test.label": "a\nb"}},
				{Set: map[string]any{"no.such": 1}},
				{Unset: []string{"no.such"}},
				{Set: map[string]any{"test.flag": false}, Unset: []string{"test.flag"}},
			} {
				if _, err := kv.SetTenantSettings(ctx, tid, p); !errors.Is(err, ErrBadTenantSetting) {
					t.Errorf("patch %+v: err %v, want ErrBadTenantSetting", p, err)
				}
			}
			tn, _ = st.GetTenant(ctx, tid)
			if !tn.Settings.Bool("test.flag") || tn.Settings.String("test.mode") != "b" || len(tn.Settings) != 2 {
				t.Fatalf("a refused patch changed settings: %v", tn.Settings)
			}

			if _, err := kv.SetTenantSettings(ctx, "t-none", TenantSettingsPatch{Set: map[string]any{"test.flag": true}}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no tenant: %v", err)
			}
		})
	}
}

// Two admins setting two keys at once both land: the UPDATE merges into the
// row it locks, never into a copy read earlier.
func TestTenantKVConcurrentKeys(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			kv := st.(TenantKV)
			tid := newTenant(t, st)
			var wg sync.WaitGroup
			errs := make(chan error, kvConcurrentKeys)
			for i := 0; i < kvConcurrentKeys; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					_, err := kv.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{fmt.Sprintf("test.k%02d", i): i + 1}})
					errs <- err
				}(i)
			}
			wg.Wait()
			close(errs)
			for err := range errs {
				if err != nil {
					t.Fatal(err)
				}
			}
			tn, err := st.GetTenant(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			for i := 0; i < kvConcurrentKeys; i++ {
				if got := tn.Settings.Int(fmt.Sprintf("test.k%02d", i)); got != i+1 {
					t.Errorf("test.k%02d = %d, want %d (a concurrent write was lost)", i, got, i+1)
				}
			}
		})
	}
}

// A hub image that reaches a database without rdb 0136 reads the defaults
// and refuses a write with ErrTenantSettingsUnavailable, never a 500.
func TestTenantKVColumnMissing(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	tid := newTenant(t, pg)
	if _, err := pg.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{"test.flag": true}}); err != nil {
		t.Fatal(err)
	}

	old, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(old.Close)
	old.kv.check = func(context.Context) (bool, error) { return false, nil } // the column is "not there"
	tn, err := old.GetTenant(ctx, tid)
	if err != nil || tn.Settings.Bool("test.flag") {
		t.Fatalf("pre-0136 read: %v %v", tn.Settings, err)
	}
	if cfg, err := old.TenantConfig(ctx, tid); err != nil || len(cfg.Settings) != 0 {
		t.Fatalf("pre-0136 TenantConfig: %v %v", cfg.Settings, err)
	}
	if _, err := old.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{"test.flag": false}}); !errors.Is(err, ErrTenantSettingsUnavailable) {
		t.Fatalf("pre-0136 write: %v", err)
	}
}

// Isolation (FR-SEC-014): under tenant A's RLS scope, B's settings are neither
// readable nor writable, and A's store write leaves B's object untouched.
func TestTenantKVCrossTenant(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	if _, err := pg.SetTenantSettings(ctx, b, TenantSettingsPatch{Set: map[string]any{"test.mode": "b"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.SetTenantSettings(ctx, a, TenantSettingsPatch{Set: map[string]any{"test.mode": "a", "test.flag": true}}); err != nil {
		t.Fatal(err)
	}
	err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE tenants SET settings = settings || '{"test.flag": true}' WHERE tenant_id = $1`, b)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 0 {
			t.Errorf("A's scope updated B's settings (%d rows)", tag.RowsAffected())
		}
		var raw []byte
		if err := tx.QueryRow(ctx, `SELECT settings FROM tenants WHERE tenant_id = $1`, b).Scan(&raw); !errors.Is(err, pgx.ErrNoRows) {
			t.Errorf("A's scope read B's settings: %s %v", raw, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := pg.TenantConfig(ctx, b)
	if err != nil || cfg.Settings.String("test.mode") != "b" || cfg.Settings.Bool("test.flag") || len(cfg.Settings) != 1 {
		t.Fatalf("B's settings after A's writes: %v %v", cfg.Settings, err)
	}
}

func TestDecodeTenantSettings(t *testing.T) {
	for raw, want := range map[string]int{
		``:   0,
		`{}`: 0,
		`{"test.flag": true, "gone.key": 1, "test.count": 1000, "test.mode": "b"}`: 2, // unknown + out-of-range skipped
		`{"test.count": 7}`:   1,
		`{"test.count": 7.5}`: 0,
		`not json`:            0,
	} {
		if got := decodeTenantSettings([]byte(raw)); len(got) != want {
			t.Errorf("decode %q = %v, want %d keys", raw, got, want)
		}
	}
	v := decodeTenantSettings([]byte(`{"test.count": 1000}`))
	if v.Int("test.count") != 5 {
		t.Errorf("an out-of-range stored value must read as the default, got %d", v.Int("test.count"))
	}
}

func TestRegisterTenantSettingRefuses(t *testing.T) {
	for _, d := range []TenantSettingDef{
		{Key: "test.flag", Kind: SettingBool, Default: false},              // duplicate
		{Key: "Bad.Key", Kind: SettingBool, Default: false},                // grammar
		{Key: "test.nokind", Default: false},                               // kind
		{Key: "test.baddef", Kind: SettingInt, Default: 0, Min: 1, Max: 2}, // default out of range
		{Key: "test.wrongdef", Kind: SettingBool, Default: "yes"},          // default type
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("RegisterTenantSetting(%+v) did not panic", d)
				}
			}()
			RegisterTenantSetting(d)
		}()
	}
}
