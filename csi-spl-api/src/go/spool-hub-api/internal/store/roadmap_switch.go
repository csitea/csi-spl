package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// RoadmapSwitch is a workspace's roadmap visibility switch (specs/112 HUB-2,
// spec 12.5, OQ3; rdb 0162 tenants.roadmap_public). A workspace roadmap is
// internal until a biz_owner or admin of that workspace turns it public: the
// sync writes its goal:, release: and spec: events with RoadmapAudience of
// the switch, and flipping the switch re-audiences that workspace's live
// synced events of those families in the same transaction. A db: event stays
// internal either way (spec 4.3).
type RoadmapSwitch interface {
	// RoadmapPublic reads the switch; ErrNotFound when no such tenant.
	RoadmapPublic(ctx context.Context, tenant string) (bool, error)
	// SetRoadmapPublic writes it and re-audiences the synced events; it
	// answers how many events changed audience. ErrNotFound when no tenant.
	SetRoadmapPublic(ctx context.Context, tenant string, public bool, now time.Time) (int, error)
}

var (
	_ RoadmapSwitch = (*Memory)(nil)
	_ RoadmapSwitch = (*Postgres)(nil)
)

// RoadmapAudience is the audience of a synced goal:, release: or spec: event
// in a workspace whose switch reads public: internal (that workspace's
// members), or public (the workspace and signed-out visitors).
func RoadmapAudience(public bool) string {
	if public {
		return CalendarPublic
	}
	return CalendarInternal
}

// roadmapSwitched: key is a synced key the switch re-audiences (not db:).
func roadmapSwitched(key string) bool {
	return key != "" && !strings.HasPrefix(key, "db:")
}

// ---- Memory -----------------------------------------------------------------

func (s *Memory) RoadmapPublic(_ context.Context, tenant string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return false, ErrNotFound
	}
	return s.roadmapPublic[tenant], nil
}

func (s *Memory) SetRoadmapPublic(_ context.Context, tenant string, public bool, now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return 0, ErrNotFound
	}
	if s.roadmapPublic == nil {
		s.roadmapPublic = map[string]bool{}
	}
	if public {
		s.roadmapPublic[tenant] = true
	} else {
		delete(s.roadmapPublic, tenant)
	}
	aud, at, n := RoadmapAudience(public), calendarNow(now), 0
	for _, e := range s.cal.events[tenant] {
		if roadmapSwitched(e.SourceKey) && e.DeletedAt.IsZero() && e.Audience != aud {
			e.Audience, e.UpdatedAt = aud, at
			n++
		}
	}
	return n, nil
}

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) RoadmapPublic(ctx context.Context, tenant string) (bool, error) {
	var on bool
	err := s.queryRowTenant(ctx, tenant, `SELECT roadmap_public FROM tenants WHERE tenant_id = $1`,
		[]any{tenant}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return on, err
}

// roadmapReaudience moves the live synced non-db: events of $1 to audience $2.
const roadmapReaudience = `UPDATE calendar_events SET audience = $2, updated_at = $3
	WHERE tenant_id = $1 AND source_key IS NOT NULL AND left(source_key, 3) <> 'db:'
		AND deleted_at IS NULL AND audience <> $2`

func (s *Postgres) SetRoadmapPublic(ctx context.Context, tenant string, public bool, now time.Time) (int, error) {
	synced := s.hasCalendar(ctx) && s.calendarShape(ctx).key
	n := 0
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE tenants SET roadmap_public = $2 WHERE tenant_id = $1`, tenant, public)
		switch {
		case err != nil:
			return err
		case tag.RowsAffected() == 0:
			return ErrNotFound
		case !synced:
			return nil
		}
		tag, err = tx.Exec(ctx, roadmapReaudience, tenant, RoadmapAudience(public), calendarNow(now))
		n = int(tag.RowsAffected())
		return err
	})
	if err != nil {
		return 0, err
	}
	return n, nil
}
