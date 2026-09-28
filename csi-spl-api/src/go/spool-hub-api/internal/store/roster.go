package store

import "context"

// Roster is what GET /v1/view/roster reads (SPL-1111): the tenant's boxes,
// its members' pictures and its member directory.
type Roster struct {
	Boxes   []ViewBox
	Avatars map[string]string // HUM-* -> avatar file id, "" = none (TenantAvatars)
	Members []Member          // ListMembers
}

// RosterReader reads a Roster in one call. *Postgres sends the tenant scope
// and the three reads as ONE batch: one round trip where the single readers
// paid three.
type RosterReader interface {
	ViewRoster(ctx context.Context, tenant string) (Roster, error)
}

func (s *Postgres) ViewRoster(ctx context.Context, tenant string) (Roster, error) {
	rs := Roster{Avatars: map[string]string{}, Members: []Member{}}
	err := s.queryTenantBatch(ctx, tenant, viewBoxesRead(tenant, &rs.Boxes),
		tenantAvatarsRead(tenant, rs.Avatars), listMembersRead(tenant, &rs.Members))
	if err != nil {
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
	return rs, nil
}
