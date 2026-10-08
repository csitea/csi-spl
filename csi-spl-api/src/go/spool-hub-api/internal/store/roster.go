package store

import (
	"context"
	"time"
)

// Roster is what GET /v1/view/roster reads (SPL-1111): the tenant's boxes,
// its members' pictures and its member directory.
type Roster struct {
	Boxes   []ViewBox
	Avatars map[string]string // HUM-* -> avatar file id, "" = none (TenantAvatars)
	Members []Member          // ListMembers
	// Statuses is every live manual status by HUM-* (spec 096, rdb 0141);
	// empty before the table exists.
	Statuses map[string]HumanStatus
}

// RosterReader reads a Roster in one call. *Postgres sends the tenant scope
// and the three reads as ONE batch: one round trip where the single readers
// paid three.
type RosterReader interface {
	ViewRoster(ctx context.Context, tenant string) (Roster, error)
}

func (s *Postgres) ViewRoster(ctx context.Context, tenant string) (Roster, error) {
	rs := Roster{Avatars: map[string]string{}, Members: []Member{}, Statuses: map[string]HumanStatus{}}
	reads := []tenantRead{viewBoxesRead(tenant, &rs.Boxes, s.hasAgentSeats(ctx), s.hasAgentRun(ctx)),
		tenantAvatarsRead(tenant, rs.Avatars), listMembersRead(tenant, &rs.Members, s.hasAccessUntil(ctx))}
	if s.hasHumanStatus(ctx) { // spec 096: one more read in the same round trip
		reads = append(reads, humanStatusRead(tenant, s.now(), rs.Statuses))
	}
	if err := s.queryTenantBatch(ctx, tenant, reads...); err != nil {
		return Roster{}, err
	}
	return rs, nil
}

func (s *Memory) ViewRoster(ctx context.Context, tenant string) (rs Roster, err error) {
	if rs.Boxes, err = s.ViewBoxes(ctx, tenant); err != nil {
		return Roster{}, err
	}
	if rs.Avatars, err = s.TenantAvatars(ctx, tenant); err != nil {
		return Roster{}, err
	}
	if rs.Members, err = s.ListMembers(ctx, tenant); err != nil {
		return Roster{}, err
	}
	if rs.Statuses, err = s.HumanStatuses(ctx, tenant, time.Now()); err != nil {
		return Roster{}, err
	}
	return rs, nil
}
