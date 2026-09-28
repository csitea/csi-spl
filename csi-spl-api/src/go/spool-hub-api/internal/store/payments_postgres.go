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

func isUniqueViolation(err error) bool {
	var pe interface{ SQLState() string }
	return errors.As(err, &pe) && pe.SQLState() == "23505"
}

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
	tag, err := tx.Exec(ctx, `INSERT INTO tenants (tenant_id, root_pubkey, billing_status, plan_id)
		VALUES ($1, $2, $3, $4) ON CONFLICT (tenant_id) DO NOTHING`,
		c.TenantID, []byte(c.RootPubKey), billing.StatusActive, c.PlanID)
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() == 0 {
		var root []byte
		if err := tx.QueryRow(ctx, `SELECT root_pubkey FROM tenants WHERE tenant_id = $1 FOR UPDATE`,
			c.TenantID).Scan(&root); err != nil {
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
	return PayOutcomePaid, nil
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
	if _, err := tx.Exec(ctx, `UPDATE tenants SET seats_users = $2, seats_bots = $3 WHERE tenant_id = $1`,
		c.TenantID, c.SeatsUsers, c.SeatsBots); err != nil {
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
