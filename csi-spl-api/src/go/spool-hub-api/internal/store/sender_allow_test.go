package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-1018 (spec 044 FR-OS-017, rdb 0188): the per-agent sender allow-lists,
// on Memory and Postgres. No list refuses nobody (CONTROL for every refusal
// below); a list refuses whoever it does not name; an empty list refuses
// everyone; a member who leaves the workspace leaves the list but the list
// stays (it does not reopen to everyone); a non-member is refused at write
// and nothing is written; another workspace's agent of the same id is
// untouched; dropping the list lets everyone through again.
func TestSenderAllowLists(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 9, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			sa, ok := st.(SenderAllow)
			h, okH := st.(Humans)
			if !ok || !okH {
				t.Fatalf("%s keeps no sender allow-lists", name)
			}
			tid, other := newTenant(t, st), newTenant(t, st)
			admin, a, b := admitAs(t, h, tid, rbac.Admin), admitAs(t, h, tid, rbac.Developer), admitAs(t, h, tid, rbac.Developer)
			refused := func(tenant, sender string, agents ...string) string {
				t.Helper()
				got, err := sa.SenderRefusedBy(ctx, tenant, sender, agents)
				if err != nil {
					t.Fatal(err)
				}
				return got
			}
			if got := refused(tid, a, "c-007", "c-008"); got != "" {
				t.Fatalf("no list refused %s by %s", a, got)
			}
			if got := refused(tid, a); got != "" {
				t.Fatalf("no agents refused by %s", got)
			}
			if err := sa.SetSenderList(ctx, tid, "c-008", []string{a}, admin, now); err != nil {
				t.Fatal(err)
			}
			if got := refused(tid, b, "c-007", "c-008"); got != "c-008" {
				t.Fatalf("unlisted %s: refused by %q, want c-008", b, got)
			}
			if got := refused(tid, a, "c-007", "c-008"); got != "" {
				t.Fatalf("CONTROL listed %s refused by %s", a, got)
			}
			if got := refused(other, b, "c-008"); got != "" {
				t.Fatalf("another workspace's c-008 refused %s", b)
			}
			// a non-member on the list: refused, the list unchanged
			if err := sa.SetSenderList(ctx, tid, "c-008", []string{a, "HUM-999999"}, admin, now); !errors.Is(err, ErrSenderNotMember) {
				t.Fatalf("non-member: %v, want ErrSenderNotMember", err)
			}
			ls, err := sa.SenderLists(ctx, tid)
			if err != nil || len(ls) != 1 || ls[0].Agent != "c-008" || !slices.Equal(ls[0].Members, []string{a}) ||
				ls[0].UpdatedBy != admin || !ls[0].UpdatedAt.Equal(now) {
				t.Fatalf("lists after a refused write: %+v %v", ls, err)
			}
			// the listed member leaves: the list stays, now empty, refusing all
			if err := h.RemoveMember(ctx, tid, a); err != nil {
				t.Fatal(err)
			}
			if got := refused(tid, b, "c-008"); got != "c-008" {
				t.Fatalf("after the last listed member left, %s is let through", b)
			}
			if ls, _ := sa.SenderLists(ctx, tid); len(ls) != 1 || len(ls[0].Members) != 0 {
				t.Fatalf("after the member left: %+v", ls)
			}
			if err := sa.SetSenderList(ctx, tid, "c-008", nil, admin, now); err != nil {
				t.Fatal(err)
			}
			if got := refused(tid, admin, "c-008"); got != "c-008" {
				t.Fatalf("an empty list let %s through", admin)
			}
			if ok, err := sa.DropSenderList(ctx, tid, "c-008"); !ok || err != nil {
				t.Fatalf("drop: %v %v", ok, err)
			}
			if got := refused(tid, b, "c-008"); got != "" {
				t.Fatalf("dropped list still refuses %s", b)
			}
			if ok, _ := sa.DropSenderList(ctx, tid, "c-008"); ok {
				t.Fatal("a second drop found a list")
			}
		})
	}
}
