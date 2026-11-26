package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// Postgres side of payments.go (rdb 0003 + 0011).

// sqlState is the Postgres SQLSTATE in err's chain ("" when there is none).
// The interface form matches *pgconn.PgError however it is wrapped.
func sqlState(err error) string {
	var pe interface{ SQLState() string }
	if errors.As(err, &pe) {
		return pe.SQLState()
	}
	return ""
}

// isUniqueViolation reports a unique_violation (SQLSTATE 23505).
func isUniqueViolation(err error) bool { return sqlState(err) == "23505" }

func (s *Postgres) HoldCheckout(ctx context.Context, c Checkout, now time.Time, hold time.Duration) error {
	if err := normalizeCheckout(&c); err != nil {
		return err
	}
	// asOperator: the slug hold checks tenants and cancels stale holds for a
	// tenant that does not exist yet.
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		var one int
		err := tx.QueryRow(ctx, `SELECT 1 FROM tenants WHERE tenant_id = $1`, c.TenantID).Scan(&one)
		if err == nil {
			return ErrConflict
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE payment_checkouts SET status = 'cancelled'
			WHERE tenant_id = $1 AND status = 'pending' AND created_at <= $2`,
			c.TenantID, now.Add(-hold)); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO payment_checkouts (intent_id, tenant_id, plan_id, provider, provider_ref,
				amount_cents, currency, status, email, root_pubkey, claim_hash, created_at,
				seats_users, seats_bots, org, app, buyer_locale)
			VALUES ($1, $2, $3, $4, NULLIF($5, ''), $6, $7, 'pending', $8, $9, $10, $11,
				$12, $13, NULLIF($14, ''), NULLIF($15, ''), NULLIF($16, ''))`,
			c.ID, c.TenantID, c.PlanID, c.Provider, c.ProviderRef, c.AmountCents, c.Currency, c.Email,
			[]byte(c.RootPubKey), c.ClaimHash, now, c.SeatsUsers, c.SeatsBots, c.Org, c.App, c.Locale)
		if isUniqueViolation(err) {
			return ErrConflict
		}
		return err
	})
}

const pgCheckoutCols = `intent_id, tenant_id, plan_id, provider, COALESCE(provider_ref, ''), amount_cents, currency,
	status, COALESCE(email, ''), root_pubkey, claim_hash, mail_claim_hash, claim_expires_at, created_at, paid_at, claimed_at,
	seats_users, seats_bots, COALESCE(org, ''), COALESCE(app, ''), COALESCE(buyer_locale, '')`

func scanCheckout(row pgx.Row) (Checkout, error) {
	var c Checkout
	var root []byte
	var paid, claimed, expires *time.Time
	err := row.Scan(&c.ID, &c.TenantID, &c.PlanID, &c.Provider, &c.ProviderRef, &c.AmountCents, &c.Currency,
		&c.Status, &c.Email, &root, &c.ClaimHash, &c.MailClaimHash, &expires, &c.CreatedAt, &paid, &claimed,
		&c.SeatsUsers, &c.SeatsBots, &c.Org, &c.App, &c.Locale)
	if errors.Is(err, pgx.ErrNoRows) {
		return Checkout{}, ErrNotFound
	}
	if err != nil {
		return Checkout{}, err
	}
	c.RootPubKey = root
	if paid != nil {
		c.PaidAt = *paid
	}
	if claimed != nil {
		c.ClaimedAt = *claimed
	}
	if expires != nil {
		c.ClaimExpires = *expires
	}
	return c, nil
}

func (s *Postgres) GetCheckout(ctx context.Context, id string) (Checkout, error) {
	return s.checkoutAsOperator(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts WHERE intent_id = $1`, id)
}

// checkoutAsOperator reads one checkout by a key that is not the tenant (the
// intent id or the provider ref): the tenant is what the row tells us.
func (s *Postgres) checkoutAsOperator(ctx context.Context, sql string, args ...any) (Checkout, error) {
	var c Checkout
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) {
		c, err = scanCheckout(tx.QueryRow(ctx, sql, args...))
		return err
	})
	return c, err
}

func (s *Postgres) CheckoutByProviderRef(ctx context.Context, provider, ref string) (Checkout, error) {
	if ref == "" {
		return Checkout{}, ErrNotFound
	}
	return s.checkoutAsOperator(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts
		WHERE provider = $1 AND provider_ref = $2 ORDER BY created_at DESC LIMIT 1`, provider, ref)
}

func (s *Postgres) ApplyPayment(ctx context.Context, ev PaymentEvent, now time.Time) (string, error) {
	defer s.hot.forget() // creates / reactivates / refunds a tenant row
	var outcome string
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) {
		outcome, err = applyPaymentTx(ctx, tx, ev, now)
		return err
	})
	if err != nil {
		return "", err
	}
	return outcome, nil
}

// applyPaymentTx records the event id once (a replay is a duplicate), finds
// the checkout it names and applies the event to it.
func applyPaymentTx(ctx context.Context, tx pgx.Tx, ev PaymentEvent, now time.Time) (string, error) {
	tag, err := tx.Exec(ctx, `INSERT INTO webhook_events_seen (provider, event_id, received_at)
		VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, ev.Provider, ev.EventID, now)
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() == 0 {
		return PayOutcomeDuplicate, nil
	}
	if ev.Kind == PayEventIgnore {
		return PayOutcomeIgnored, nil
	}
	c, err := scanCheckout(tx.QueryRow(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts
		WHERE intent_id = $1 FOR UPDATE`, ev.CheckoutID))
	if errors.Is(err, ErrNotFound) {
		return PayOutcomeNoMatch, nil
	}
	if err != nil {
		return "", err
	}
	switch ev.Kind {
	case PayEventPaid:
		return paidTx(ctx, tx, c, ev, now)
	case PayEventFailed:
		if _, err := tx.Exec(ctx, `UPDATE payment_checkouts SET status = 'failed'
			WHERE intent_id = $1 AND status = 'pending'`, c.ID); err != nil {
			return "", err
		}
		return PayOutcomeFailed, nil
	case PayEventRefund, PayEventCancel:
		status, err := billing.MapEvent(ev.Kind)
		if err != nil {
			return "", err
		}
		if _, err := tx.Exec(ctx, `UPDATE tenants SET billing_status = $3
			WHERE tenant_id = $1 AND root_pubkey = $2`, c.TenantID, []byte(c.RootPubKey), status); err != nil {
			return "", err
		}
		return PayOutcomeRefund, nil
	}
	return "", errUnknownPayEvent(ev.Kind)
}

// paidTx creates the tenant active, or re-activates the row that already
// exists with the checkout's own root key (another key is a conflict), marks
// the checkout paid and applies its seats.
func paidTx(ctx context.Context, tx pgx.Tx, c Checkout, ev PaymentEvent, now time.Time) (string, error) {
	if c.Status == CheckoutPaid {
		return PayOutcomeAlreadyPaid, nil
	}
	made, err := insertTenantTx(ctx, tx, tenantInsert{c.TenantID, c.RootPubKey, c.PlanID, true})
	if err != nil {
		return "", err
	}
	if !made {
		var root []byte
		err := tx.QueryRow(ctx, `SELECT root_pubkey FROM tenants WHERE tenant_id = $1 FOR UPDATE`,
			c.TenantID).Scan(&root)
		if errors.Is(err, pgx.ErrNoRows) {
			return PayOutcomeConflict, nil // no row and none inserted: the id was purged
		}
		if err != nil {
			return "", err
		}
		if !bytes.Equal(root, c.RootPubKey) {
			return PayOutcomeConflict, nil
		}
		if _, err := tx.Exec(ctx, `UPDATE tenants SET billing_status = $2 WHERE tenant_id = $1`,
			c.TenantID, billing.StatusActive); err != nil {
			return "", err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE payment_checkouts SET status = 'paid', paid_at = $2
		WHERE intent_id = $1`, c.ID, now); err != nil {
		return "", err
	}
	if err := applySeatsTx(ctx, tx, c, ev.Env, now); err != nil {
		return "", err
	}
	if err := paidInviteTx(ctx, tx, c, now); err != nil {
		return "", err
	}
	return PayOutcomePaid, nil
}

// tenantInsert is the row insertTenantTx writes. fleetSeating is
// tenants.fleet_seating (rdb 0230): the paid transition sets it true, like
// every other create (spec 158 M24, OD1); the order submit keeps the column
// default false until its own row says otherwise.
type tenantInsert struct {
	tenant       string
	root         ed25519.PublicKey
	plan         string
	fleetSeating bool
}

// insertTenantTx is the tenant creation shared by the paid transition and the
// private-workspace order submit: the row, active, with root as its root key.
// made is false when the tenant already existed or its id was purged (nothing
// written): a purged id is retired, as in CreateTenant (rdb 0322).
func insertTenantTx(ctx context.Context, tx pgx.Tx, in tenantInsert) (made bool, err error) {
	tag, err := tx.Exec(ctx, `INSERT INTO tenants (tenant_id, root_pubkey, billing_status, plan_id, fleet_seating)
		SELECT $1, $2, $3, $4, $5
		WHERE NOT EXISTS (SELECT 1 FROM workspace_cancellations WHERE tenant_id = $1 AND purged_at IS NOT NULL)
		ON CONFLICT (tenant_id) DO NOTHING`,
		in.tenant, []byte(in.root), billing.StatusActive, in.plan, in.fleetSeating)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// paidInviteTx seats the buyer (047 W1): a biz_owner invite for the checkout
// email, unless the tenant already has a member or that address an invite.
func paidInviteTx(ctx context.Context, tx pgx.Tx, c Checkout, now time.Time) error {
	in, err := paidOwnerInvite(c, now)
	if err != nil {
		return err
	}
	return ownerInviteTx(ctx, tx, in, now)
}

// ownerInviteTx writes in unless the tenant has a member or the address an
// invite.
func ownerInviteTx(ctx context.Context, tx pgx.Tx, in Invite, now time.Time) error {
	_, err := tx.Exec(ctx, `INSERT INTO tenant_invites (tenant_id, email, role, invited_by, created_at, expires_at)
		SELECT $1, $2, $3, $4, $5, $6
		WHERE NOT EXISTS (SELECT 1 FROM tenant_memberships WHERE tenant_id = $1)
		ON CONFLICT (tenant_id, email) DO NOTHING`,
		in.TenantID, in.Email, in.Role, in.InvitedBy, now, in.ExpiresAt)
	return err
}

func (s *Postgres) SetClaimLink(ctx context.Context, id string, mailClaimHash []byte, expires time.Time) error {
	var tag pgconn.CommandTag
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) { // keyed by intent id, not tenant
		tag, err = tx.Exec(ctx, `UPDATE payment_checkouts SET mail_claim_hash = $2, claim_expires_at = $3
			WHERE intent_id = $1`, id, mailClaimHash, expires)
		return err
	})
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) ClaimCheckout(ctx context.Context, id string, claimHash []byte, now time.Time, newPub ed25519.PublicKey) (Checkout, error) {
	if len(newPub) != ed25519.PublicKeySize {
		return Checkout{}, fmt.Errorf("claim: new root pubkey must be %d bytes", ed25519.PublicKeySize)
	}
	defer s.hot.forget() // rotates the tenant root key
	var out Checkout
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		c, err := scanCheckout(tx.QueryRow(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts
			WHERE intent_id = $1 FOR UPDATE`, id))
		if err != nil {
			return err
		}
		if !c.ClaimedAt.IsZero() {
			return ErrClaimed // status already shows claimed=true
		}
		if len(claimHash) != 32 || !(bytes.Equal(c.ClaimHash, claimHash) || (len(c.MailClaimHash) == 32 && bytes.Equal(c.MailClaimHash, claimHash))) {
			return ErrNotFound
		}
		if c.Status != CheckoutPaid {
			return ErrNotPaid
		}
		if !c.ClaimExpires.IsZero() && !now.Before(c.ClaimExpires) {
			return ErrClaimExpired
		}
		tag, err := tx.Exec(ctx, `UPDATE tenants SET root_pubkey = $3 WHERE tenant_id = $1 AND root_pubkey = $2`,
			c.TenantID, []byte(c.RootPubKey), []byte(newPub))
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrConflict
		}
		if _, err := tx.Exec(ctx, `UPDATE payment_checkouts SET root_pubkey = $2, claimed_at = $3,
			claim_hash = NULL, mail_claim_hash = NULL WHERE intent_id = $1`, id, []byte(newPub), now); err != nil {
			return err
		}
		c.RootPubKey, c.ClaimedAt, c.ClaimHash, c.MailClaimHash = newPub, now, nil, nil
		out = c
		return nil
	})
	return out, err
}

// applySeatsTx is the Postgres side of the paid transition's M4 line items
// (009 T002/T004/T005), inside ApplyPayment's operator transaction: the
// project_id stamp for a dedicated SKU whose tenant has none (each candidate
// under a savepoint, so a unique clash rolls back only that attempt), then
// the caps and the month's seat period when the checkout bought seats.
func applySeatsTx(ctx context.Context, tx pgx.Tx, c Checkout, env string, now time.Time) error {
	if c.Org != "" {
		if _, err := stampWith(func(id string) error {
			sp, err := tx.Begin(ctx)
			if err != nil {
				return err
			}
			_, err = sp.Exec(ctx, `UPDATE tenants SET org = $2, app = $3, project_id = $4, bought_at = $5
				WHERE tenant_id = $1 AND project_id IS NULL`, c.TenantID, c.Org, c.App, id, now.UTC())
			if err != nil {
				_ = sp.Rollback(ctx)
				if isUniqueViolation(err) {
					return ErrConflict
				}
				return err
			}
			return sp.Commit(ctx)
		}, c.Org, c.App, env, now); err != nil {
			return err
		}
	}
	if c.SeatsUsers == 0 && c.SeatsBots == 0 {
		return nil
	}
	if err := seatCapsTx(ctx, tx, c.TenantID, c.SeatsUsers, c.SeatsBots); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO tenant_seat_periods (tenant_id, period_start, seats_users, seats_bots,
			checkout_id, amount_cents, paid_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (tenant_id, period_start) DO UPDATE SET
			seats_users = GREATEST(tenant_seat_periods.seats_users, EXCLUDED.seats_users),
			seats_bots = GREATEST(tenant_seat_periods.seats_bots, EXCLUDED.seats_bots),
			checkout_id = EXCLUDED.checkout_id, amount_cents = EXCLUDED.amount_cents, paid_at = EXCLUDED.paid_at`,
		c.TenantID, PeriodStart(now), c.SeatsUsers, c.SeatsBots, c.ID, c.AmountCents, now.UTC())
	return err
}

func (s *Postgres) SeatPeriods(ctx context.Context, tenant string) ([]SeatPeriod, error) {
	var out []SeatPeriod
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT tenant_id, period_start, seats_users, seats_bots, checkout_id,
			amount_cents, paid_at FROM tenant_seat_periods WHERE tenant_id = $1 ORDER BY period_start`, tenant)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (SeatPeriod, error) {
			var p SeatPeriod
			err := r.Scan(&p.TenantID, &p.PeriodStart, &p.SeatsUsers, &p.SeatsBots, &p.CheckoutID, &p.AmountCents, &p.PaidAt)
			p.PeriodStart = p.PeriodStart.UTC()
			return p, err
		})
		return err
	})
	return out, err
}

// seatCapsTx sets the tenant's seat caps (009 M4).
func seatCapsTx(ctx context.Context, tx pgx.Tx, tenant string, users, bots int) error {
	_, err := tx.Exec(ctx, `UPDATE tenants SET seats_users = $2, seats_bots = $3 WHERE tenant_id = $1`,
		tenant, users, bots)
	return err
}

const pgOrderCols = `order_id, tenant_id, status, seats_users, email, billing_name, billing_address,
	billing_country, COALESCE(billing_vat_id, ''), COALESCE(buyer_locale, ''), created_at`

func scanOrder(row pgx.Row) (WorkspaceOrder, error) {
	var o WorkspaceOrder
	err := row.Scan(&o.ID, &o.TenantID, &o.Status, &o.SeatsUsers, &o.Email, &o.Billing.Name, &o.Billing.Address,
		&o.Billing.Country, &o.Billing.VATID, &o.Locale, &o.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return WorkspaceOrder{}, ErrNotFound
	}
	return o, err
}

// SubmitWorkspaceOrder (WorkspaceOrders, spec 181 B2): the tenant and its
// order in one operator transaction, since the tenant does not exist yet.
func (s *Postgres) SubmitWorkspaceOrder(ctx context.Context, o WorkspaceOrder, now time.Time) (WorkspaceOrder, bool, error) {
	if err := normalizeOrder(&o, now); err != nil {
		return WorkspaceOrder{}, false, err
	}
	defer s.hot.forget() // creates a tenant row
	var out WorkspaceOrder
	var created bool
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) {
		out, created, err = submitOrderTx(ctx, tx, o, now)
		return err
	})
	return out, created, err
}

// submitOrderTx: a replay first (the stored order), then the tenant made
// exactly as the paid transition makes it, then the rest of 4.1 step 4.
func submitOrderTx(ctx context.Context, tx pgx.Tx, o WorkspaceOrder, now time.Time) (WorkspaceOrder, bool, error) {
	old, err := scanOrder(tx.QueryRow(ctx, `SELECT `+pgOrderCols+` FROM workspace_orders WHERE tenant_id = $1`, o.TenantID))
	if err == nil {
		return orderReplay(old, o)
	}
	if !errors.Is(err, ErrNotFound) {
		return WorkspaceOrder{}, false, err
	}
	made, err := insertTenantTx(ctx, tx, tenantInsert{o.TenantID, o.RootPubKey, PlanKindPrivateVM, false})
	if err != nil {
		return WorkspaceOrder{}, false, err
	}
	if !made {
		// a concurrent submit of the same order committed first: its row
		// answers this one; anything else holding the slug is a conflict
		old, err := scanOrder(tx.QueryRow(ctx, `SELECT `+pgOrderCols+` FROM workspace_orders WHERE tenant_id = $1`, o.TenantID))
		if errors.Is(err, ErrNotFound) {
			return WorkspaceOrder{}, false, ErrConflict
		}
		if err != nil {
			return WorkspaceOrder{}, false, err
		}
		return orderReplay(old, o)
	}
	if err := orderTenantTx(ctx, tx, o, now); err != nil {
		return WorkspaceOrder{}, false, err
	}
	err = tx.QueryRow(ctx, `INSERT INTO workspace_orders (order_id, tenant_id, status, seats_users, email,
			billing_name, billing_address, billing_country, billing_vat_id, buyer_locale, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULLIF($9, ''), NULLIF($10, ''), $11)
		RETURNING created_at`, o.ID, o.TenantID, o.Status, o.SeatsUsers, o.Email, o.Billing.Name, o.Billing.Address,
		o.Billing.Country, o.Billing.VATID, o.Locale, now.UTC()).Scan(&o.CreatedAt)
	if err != nil {
		return WorkspaceOrder{}, false, err
	}
	return o, true, nil
}

// orderTenantTx is the new workspace's setup: seat caps (human members only),
// box_join_enabled on, the private_vm price plan and the biz_owner invite.
func orderTenantTx(ctx context.Context, tx pgx.Tx, o WorkspaceOrder, now time.Time) error {
	if err := seatCapsTx(ctx, tx, o.TenantID, o.SeatsUsers, 0); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE tenants SET box_join_enabled = true WHERE tenant_id = $1`, o.TenantID); err != nil {
		return err
	}
	if err := putPricePlanTx(ctx, tx, o.TenantID, PrivateVMPlan()); err != nil {
		return err
	}
	in, err := ownerInvite(o.TenantID, o.Email, now)
	if err != nil {
		return err
	}
	return ownerInviteTx(ctx, tx, in, now)
}

// WorkspaceOrder (WorkspaceOrders) reads the tenant's order in its scope.
func (s *Postgres) WorkspaceOrder(ctx context.Context, tenant string) (WorkspaceOrder, error) {
	var o WorkspaceOrder
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) (err error) {
		o, err = scanOrder(tx.QueryRow(ctx, `SELECT `+pgOrderCols+` FROM workspace_orders WHERE tenant_id = $1`, tenant))
		return err
	})
	return o, err
}
