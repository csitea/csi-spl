package hub

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestAuthActivityRecorderWiring: the memory store cannot append, so auth
// auditing stays off (nil recorder); the retention window is the owner's 90
// days. The append/list/sweep themselves are proven on Postgres
// (store.TestMemberActivity).
func TestAuthActivityRecorderWiring(t *testing.T) {
	if r := AuthActivityRecorder(store.NewMemory()); r != nil {
		t.Errorf("AuthActivityRecorder(memory) = %v, want nil (no append support)", r)
	}
	if AuthActivityRetention != 90*24*time.Hour {
		t.Errorf("AuthActivityRetention = %v, want 90 days", AuthActivityRetention)
	}
}
