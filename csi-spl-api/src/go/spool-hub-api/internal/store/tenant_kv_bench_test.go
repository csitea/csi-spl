package store

import (
	"context"
	"fmt"
	"os"
	"testing"
)

// Spec 098 section 5 (owner, t1 29b19f85 msg 505e7698: "ensure the
// performance does not degrade in complex json operations"): the settings
// object against today's column, on Postgres. Run:
//
//	SPOOL_TEST_PG_DSN=... go test -run '^$' -bench TenantKV -benchmem ./internal/store/
//
// The row holds kvBenchKeys stored keys, more than any workspace has today.

const kvBenchKeys = 16

func benchPG(b *testing.B) (*Postgres, string) {
	b.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		b.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(pg.Close)
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(b)); err != nil {
		b.Fatal(err)
	}
	tid := uid("t-")
	if err := pg.CreateTenant(ctx, Tenant{ID: tid, RootPubKey: pubkey()}); err != nil {
		b.Fatal(err)
	}
	set := map[string]any{"test.flag": true, "test.mode": "b"}
	for i := 0; i < kvBenchKeys-2; i++ {
		set[fmt.Sprintf("test.k%02d", i)] = i
	}
	if _, err := pg.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: set}); err != nil {
		b.Fatal(err)
	}
	return pg, tid
}

// Read: one column (today) vs the settings object plus its decode, each a
// full round trip under the tenant's RLS scope; and the cached tenant row,
// which is what a request path reads.
func BenchmarkTenantKVRead(b *testing.B) {
	pg, tid := benchPG(b)
	ctx := context.Background()
	b.Run("column", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			var on bool
			if err := pg.queryRowTenant(ctx, tid, `SELECT marketing_enabled FROM tenants WHERE tenant_id = $1`,
				[]any{tid}, &on); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("settings", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			var raw []byte
			if err := pg.queryRowTenant(ctx, tid, `SELECT settings FROM tenants WHERE tenant_id = $1`,
				[]any{tid}, &raw); err != nil {
				b.Fatal(err)
			}
			if v := decodeTenantSettings(raw); !v.Bool("test.flag") {
				b.Fatal("decode lost a key")
			}
		}
	})
	b.Run("tenant_row_uncached", func(b *testing.B) { // getTenant: every column + settings
		for i := 0; i < b.N; i++ {
			if _, err := pg.getTenant(ctx, tid); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("tenant_row_cached", func(b *testing.B) { // the request path
		for i := 0; i < b.N; i++ {
			t, err := pg.GetTenant(ctx, tid)
			if err != nil || !t.Settings.Bool("test.flag") {
				b.Fatal(err)
			}
		}
	})
}

// Write: one column (today) vs one key merged into the object.
func BenchmarkTenantKVWrite(b *testing.B) {
	pg, tid := benchPG(b)
	ctx := context.Background()
	b.Run("column", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			if err := pg.SetMarketingEnabled(ctx, tid, i%2 == 0); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("settings_one_key", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			if _, err := pg.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{"test.flag": i%2 == 0}}); err != nil {
				b.Fatal(err)
			}
		}
	})
}

// Decode alone: the cost paid once per tenant cache fill.
func BenchmarkTenantKVDecode(b *testing.B) {
	raw := []byte(`{"test.flag": true, "test.mode": "b"`)
	for i := 0; i < kvBenchKeys-2; i++ {
		raw = append(raw, fmt.Sprintf(`, "test.k%02d": %d`, i, i)...)
	}
	raw = append(raw, '}')
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if v := decodeTenantSettings(raw); len(v) != kvBenchKeys {
			b.Fatalf("decoded %d keys", len(v))
		}
	}
}
