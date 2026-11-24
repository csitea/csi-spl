package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 181 row B9 (SPL-6344): a private workspace's cancel and its 30-day
// purge. Memory always, Postgres with a DSN (hub-pg.tst.sh,
// PRE_PUSH_TIER=full). Synthetic ids only.

// seedWorkspaceCancel writes one cancellation row for tenant, raw, in the
// operator scope (crosstenant_test.go: a tenant read-only table).
func seedWorkspaceCancel(ctx context.Context, pg *Postgres, tenant string) error {
	c := newWorkspaceCancel(tenant, "ops", "op@example.com", time.Now())
	return pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, cancelPutSQL, tenant, c.CancelledAt, c.PurgeAfter, c.ActorTenant, c.ActorHum)
		return err
	})
}

// privateWorkspace is a tenant on the private_vm plan with one box pinned
// dedicated and one open join token.
func privateWorkspace(t *testing.T, s Store, now time.Time) (tenant, vm string) {
	t.Helper()
	ctx := context.Background()
	tenant = newTenant(t, s)
	if err := s.(PricePlans).PutPricePlan(ctx, tenant, PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	if err := s.(BoxJoinSwitch).SetBoxJoinEnabled(ctx, tenant, true); err != nil {
		t.Fatal(err)
	}
	js := s.(JoinTokens)
	vm = "vm-" + uid("")[:8]
	jt := opJoinToken(tenant, vm, now)
	if err := js.CreateJoinToken(ctx, jt); err != nil {
		t.Fatal(err)
	}
	if _, err := js.RedeemJoinToken(ctx, tenant, jt.Hash, vm, pubkey(), BoxModeDedicated, now); err != nil {
		t.Fatalf("redeem: %v", err)
	}
	if err := js.CreateJoinToken(ctx, opJoinToken(tenant, "", now)); err != nil {
		t.Fatal(err)
	}
	return tenant, vm
}

// TestCancelWorkspace: the cancel revokes the workspace's pin and its open
// join token, turns its joins off and writes one audit row; a replay
// changes nothing. CONTROL: a workspace off the private_vm plan and one
// that does not exist are refused and keep their pin, switch and audit.
func TestCancelWorkspace(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			wc, ow := s.(WorkspaceCancels), s.(OperatorWorkspaces)
			a, vm := privateWorkspace(t, s, now)
			shared := newTenant(t, s)
			if err := s.(BoxJoinSwitch).SetBoxJoinEnabled(ctx, shared, true); err != nil {
				t.Fatal(err)
			}
			if _, _, err := wc.CancelWorkspace(ctx, shared, "ops", "op@example.com", now); !errors.Is(err, ErrNotPrivateWorkspace) {
				t.Fatalf("shared workspace: %v, want ErrNotPrivateWorkspace", err)
			}
			if on, _ := s.(BoxJoinSwitch).BoxJoinEnabled(ctx, shared); !on {
				t.Error("CONTROL: a refused cancel turned the shared workspace's joins off")
			}
			if _, _, err := wc.CancelWorkspace(ctx, "t-none-"+uid("")[:8], "ops", "op@example.com", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no workspace: %v, want ErrNotFound", err)
			}
			if _, err := wc.WorkspaceCancellation(ctx, a); !errors.Is(err, ErrNotFound) {
				t.Fatalf("before the cancel: %v, want ErrNotFound", err)
			}
			c, created, err := wc.CancelWorkspace(ctx, a, "ops", "op@example.com", now)
			if err != nil || !created || !slices.Equal(c.RevokedBoxes, []string{vm}) || c.RevokedTokens != 1 ||
				!c.PurgeAfter.Equal(now.AddDate(0, 0, CancelPurgeDays)) {
				t.Fatalf("cancel: %+v created=%v %v", c, created, err)
			}
			if _, err := s.GetPin(ctx, a, vm); !errors.Is(err, ErrNotFound) {
				t.Errorf("the pin of %s after the cancel: %v, want revoked (ErrNotFound)", vm, err)
			}
			if toks, _ := s.(JoinTokens).ListJoinTokens(ctx, a, now); len(toks) != 2 || toks[0].State() == "open" || toks[1].State() == "open" {
				t.Errorf("join tokens after the cancel: %+v, want none open", toks)
			}
			if on, _ := s.(BoxJoinSwitch).BoxJoinEnabled(ctx, a); on {
				t.Error("box_join_enabled is still on after the cancel")
			}
			got, err := wc.WorkspaceCancellation(ctx, a)
			if err != nil || !got.CancelledAt.Equal(now) || got.PurgedAt != nil || got.ActorHum != "op@example.com" {
				t.Fatalf("read: %+v %v", got, err)
			}
			again, created, err := wc.CancelWorkspace(ctx, a, "ops", "other@example.com", now.Add(time.Hour))
			if err != nil || created || !again.CancelledAt.Equal(now) || again.ActorHum != "op@example.com" {
				t.Fatalf("replay: %+v created=%v %v, want the first row", again, created, err)
			}
			trail, err := ow.OperatorAuditOf(ctx, a, 10)
			if err != nil || len(trail) != 1 || trail[0].Action != AuditCancelWorkspace || trail[0].ActorHum != "op@example.com" {
				t.Fatalf("audit: %+v %v, want one cancel_workspace row", trail, err)
			}
		})
	}
}

// TestPurgeCancelledWorkspace: the hub data stays 30 days after the
// cancel (Q-12 C), is held while an invoice is unpaid (Q-17 B), then goes;
// the cancellation row, the audit and the paid invoice outlive it (rdb
// 0320, owner msg f872a556). CONTROL: a day before
// purge_after nothing goes, and a workspace that is not cancelled stays.
func TestPurgeCancelledWorkspace(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			wc, ow := s.(WorkspaceCancels), s.(OperatorWorkspaces)
			a, _ := privateWorkspace(t, s, now)
			kept, _ := privateWorkspace(t, s, now)
			month := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			issued, _, err := s.(Invoices).IssueInvoice(ctx, a, month, 1, 0, now)
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := wc.CancelWorkspace(ctx, a, "ops", "op@example.com", now); err != nil {
				t.Fatal(err)
			}
			mine := func(r PurgeResult) (purged, held bool) {
				return slices.Contains(r.Purged, a), slices.Contains(r.Held, a)
			}
			r, err := wc.PurgeDueWorkspaces(ctx, now.AddDate(0, 0, CancelPurgeDays-1))
			if p, h := mine(r); err != nil || p || h {
				t.Fatalf("day 29: %+v %v, want nothing", r, err)
			}
			r, err = wc.PurgeDueWorkspaces(ctx, now.AddDate(0, 0, CancelPurgeDays))
			if p, h := mine(r); err != nil || p || !h {
				t.Fatalf("day 30, invoice unpaid: %+v %v, want held", r, err)
			}
			if _, err := s.GetTenant(ctx, a); err != nil {
				t.Fatalf("a held workspace is gone: %v", err)
			}
			if err := s.(Invoices).MarkInvoicePaid(ctx, a, month, now); err != nil {
				t.Fatal(err)
			}
			at := now.AddDate(0, 0, CancelPurgeDays).Add(time.Hour)
			r, err = wc.PurgeDueWorkspaces(ctx, at)
			if p, _ := mine(r); err != nil || !p {
				t.Fatalf("day 30, paid: %+v %v, want purged", r, err)
			}
			if _, err := s.GetTenant(ctx, a); !errors.Is(err, ErrNotFound) {
				t.Fatalf("the purged workspace: %v, want ErrNotFound", err)
			}
			if _, err := s.(PricePlans).PricePlan(ctx, a); !errors.Is(err, ErrNoPricePlan) {
				t.Errorf("the purged workspace's plan: %v, want gone", err)
			}
			if _, err := s.GetTenant(ctx, kept); err != nil {
				t.Errorf("CONTROL: a workspace that is not cancelled: %v", err)
			}
			checkInvoiceKept(t, s, a, kept, issued)
			r, err = wc.PurgeDueWorkspaces(ctx, at.Add(time.Hour))
			if p, h := mine(r); err != nil || p || h {
				t.Fatalf("second purge: %+v %v, want nothing", r, err)
			}
			trail, err := ow.OperatorAuditOf(ctx, a, 10)
			if err != nil || len(trail) != 2 {
				t.Fatalf("audit after the purge: %+v %v, want cancel + purge", trail, err)
			}
			if !slices.ContainsFunc(trail, func(x OperatorAudit) bool { return x.Action == AuditPurgeWorkspace }) {
				t.Fatalf("audit after the purge: %+v, want a purge_workspace row", trail)
			}
		})
	}
}

// checkInvoiceKept: the purged workspace a's paid invoice is still there,
// with its tenant id and amount, in a's own scope; on Postgres the operator
// scope reads it and the other workspace's scope does not (RLS, rdb 0315).
func checkInvoiceKept(t *testing.T, s Store, a, other string, issued Invoice) {
	t.Helper()
	ctx := context.Background()
	got, err := s.(Invoices).Invoice(ctx, a, issued.Month)
	if err != nil || got.Tenant != a || got.TotalMicros != issued.TotalMicros || got.PaidAt == nil {
		t.Fatalf("the purged workspace's paid invoice: %+v %v, want it kept (tenant %s, total %s, paid)",
			got, err, a, issued.TotalMicros)
	}
	pg, ok := s.(*Postgres)
	if !ok {
		return
	}
	var op Invoice
	if err := pg.asOperator(ctx, func(tx pgx.Tx) (err error) {
		op, err = scanInvoice(tx.QueryRow(ctx, invoiceReadSQL, a, issued.Month))
		return err
	}); err != nil || op.Tenant != a || op.TotalMicros != issued.TotalMicros {
		t.Fatalf("operator read of the purged workspace's invoice: %+v %v", op, err)
	}
	err = pg.inTenant(ctx, other, func(tx pgx.Tx) error {
		_, err := scanInvoice(tx.QueryRow(ctx, invoiceReadSQL, a, issued.Month))
		return err
	})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("workspace %s read %s's invoice: %v, want no row (RLS)", other, a, err)
	}
}
