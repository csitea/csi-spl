package store

import (
	"context"
	"fmt"
	"time"
)

// Quota counters (rdb 0127, specs/077 3.7). One count per (tenant, human,
// kind, window): the hub TAKES a unit before the work the quota caps, and a
// refused take changes nothing. The window is the caller's: T013 counts agent
// turns per demo visit (window = the visit's membership created_at), T012
// will count posts per minute and per day (window = the minute, the day).

// QuotaKindMax is rdb 0127's kind length cap.
const QuotaKindMax = 40

// QuotaCounter is implemented by Memory and Postgres.
type QuotaCounter interface {
	// TakeQuota adds one to the (tenant, human, kind, window) count unless it
	// holds limit already, in one atomic step: n is the count after the take;
	// ok false is a refusal that wrote nothing (n = limit). limit < 1 refuses.
	TakeQuota(ctx context.Context, tenant, human, kind string, window time.Time, limit int) (n int, ok bool, err error)
	// MemberSince is human's tenant_memberships.created_at in tenant. A demo
	// visit is one membership row: the expiry sweep drops it and the next
	// admission seats a new one, so it names the visit. ErrNotFound: none.
	MemberSince(ctx context.Context, tenant, human string) (time.Time, error)
}

var (
	_ QuotaCounter = (*Memory)(nil)
	_ QuotaCounter = (*Postgres)(nil)
)

// quotaKey is one counter; window in UTC at microsecond precision, as
// Postgres stores it.
type quotaKey struct {
	tenant, human, kind string
	window              time.Time
}

// checkQuota is the Go side of rdb 0127's CHECKs.
func checkQuota(tenant, human, kind string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if human == "" || kind == "" || len(kind) > QuotaKindMax {
		return fmt.Errorf("quota: a human and a kind of 1..%d bytes are required", QuotaKindMax)
	}
	return nil
}

// Memory side: a per-store map beside the Memory struct, guarded by s.mu.
var memQuotas = map[*Memory]map[quotaKey]int{}

func (s *Memory) TakeQuota(_ context.Context, tenant, human, kind string, window time.Time, limit int) (int, bool, error) {
	if err := checkQuota(tenant, human, kind); err != nil {
		return 0, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := memQuotas[s]
	if rows == nil {
		rows = map[quotaKey]int{}
		memQuotas[s] = rows
	}
	k := quotaKey{tenant, human, kind, window.UTC().Truncate(time.Microsecond)}
	if rows[k] >= limit {
		return max(limit, 0), false, nil
	}
	rows[k]++
	return rows[k], true, nil
}

func (s *Memory) MemberSince(_ context.Context, tenant, human string) (time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	m, ok := s.hum.members[[2]string{tenant, human}]
	if !ok {
		return time.Time{}, ErrNotFound
	}
	return m.since, nil
}
