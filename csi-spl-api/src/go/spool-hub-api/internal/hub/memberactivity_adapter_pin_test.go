package hub

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// apAppender is a memory store that can append member activity: it records
// each AppendMemberActivity, so the adapter's field mapping can be read back.
type apAppender struct {
	*store.Memory
	got []store.MemberActivity
}

func (a *apAppender) AppendMemberActivity(_ context.Context, m store.MemberActivity) error {
	a.got = append(a.got, m)
	return nil
}

// apRecord sends one auth event with seven distinct values through the adapter.
func apRecord(a authActivityAdapter, at time.Time) error {
	return a.RecordAuthEvent(context.Background(), auth.Event{
		Tenant: "ap-tenant", HumanID: "ap-hum", Kind: "ap-kind", Method: "ap-method", IP: "ap-ip", UA: "ap-ua", At: at,
	})
}

// TestAuthActivityAdapterFieldMapping pins the adapter: seven distinct values
// each land in their own store.MemberActivity field, so a swap of two string
// fields (IP and UA, tenant and human) fails here (SPL-5363).
func TestAuthActivityAdapterFieldMapping(t *testing.T) {
	fake := &apAppender{Memory: store.NewMemory()}
	at := time.Date(2026, 11, 12, 9, 30, 0, 0, time.UTC)
	if err := apRecord(authActivityAdapter{store: fake}, at); err != nil {
		t.Fatalf("RecordAuthEvent: %v", err)
	}
	if len(fake.got) != 1 {
		t.Fatalf("appended %d rows, want 1", len(fake.got))
	}
	want := store.MemberActivity{
		TenantID: "ap-tenant", SubjectHum: "ap-hum", Kind: "ap-kind", Detail: "ap-method",
		IP: "ap-ip", UA: "ap-ua", CreatedAt: at,
	}
	if g := fake.got[0]; g != want {
		t.Errorf("appended %+v, want %+v", g, want)
	}
}
