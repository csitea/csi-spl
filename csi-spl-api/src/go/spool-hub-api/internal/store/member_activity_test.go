package store

import (
	"context"
	"testing"
	"time"
)

// TestMemberActivity: append records events, list returns ONE subject's rows
// newest first (and never another subject's), the auth row keeps its method /
// masked IP / coarse UA, and the retention sweep prunes only the aged AUTH rows
// (membership rows are kept).
func TestMemberActivity(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	subj := seatMember(t, pg, tid, "developer")
	base := time.Now().UTC().Truncate(time.Microsecond)

	rows := []MemberActivity{
		{TenantID: tid, SubjectHum: subj, ActorHum: admin, Kind: "role_changed", Detail: "tester", CreatedAt: base.Add(-72 * time.Hour)},
		{TenantID: tid, SubjectHum: subj, Kind: "sign_in", Detail: "google", IP: "203.0.113.0/24", UA: "Chrome on macOS", CreatedAt: base.Add(-100 * 24 * time.Hour)}, // aged auth row
		{TenantID: tid, SubjectHum: subj, Kind: "sign_out", CreatedAt: base.Add(-time.Hour)},
	}
	for _, e := range rows {
		if err := pg.AppendMemberActivity(ctx, e); err != nil {
			t.Fatal(err)
		}
	}
	// another subject's row must not leak into subj's list
	if err := pg.AppendMemberActivity(ctx, MemberActivity{TenantID: tid, SubjectHum: admin, Kind: "sign_in", Detail: "password", CreatedAt: base}); err != nil {
		t.Fatal(err)
	}

	list, err := pg.ListMemberActivity(ctx, tid, subj)
	if err != nil || len(list) != 3 {
		t.Fatalf("ListMemberActivity = %d rows %v, want 3", len(list), err)
	}
	// newest first (activity_id DESC == insert order reversed)
	if list[0].Kind != "sign_out" || list[2].Kind != "sign_in" {
		t.Errorf("order: got %q..%q, want sign_out..sign_in", list[0].Kind, list[2].Kind)
	}
	var signin *MemberActivity
	for i := range list {
		if list[i].Kind == "sign_in" {
			signin = &list[i]
		}
	}
	if signin == nil || signin.Detail != "google" || signin.IP != "203.0.113.0/24" || signin.UA == "" {
		t.Errorf("sign_in row lost its method/ip/ua: %+v", signin)
	}

	// the retention sweep prunes only the aged AUTH row (the 100-day sign_in);
	// the 72h role_changed (membership) and the 1h sign_out stay.
	n, err := pg.SweepMemberActivity(ctx, base.Add(-90*24*time.Hour))
	if err != nil || n < 1 {
		t.Fatalf("SweepMemberActivity = %d %v, want >=1", n, err)
	}
	after, _ := pg.ListMemberActivity(ctx, tid, subj)
	if len(after) != 2 {
		t.Fatalf("after sweep = %d rows, want 2 (aged sign_in pruned)", len(after))
	}
	for _, a := range after {
		if a.Kind == "sign_in" {
			t.Error("sweep did not prune the aged sign_in")
		}
	}
}
