package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

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
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
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
				amount_cents, currency, status, email, root_pubkey, claim_hash, created_at)
			VALUES ($1, $2, $3, $4, NULLIF($5, ''), $6, $7, 'pending', $8, $9, $10, $11)`,
			c.ID, c.TenantID, c.PlanID, c.Provider, c.ProviderRef, c.AmountCents, c.Currency, c.Email,
			[]byte(c.RootPubKey), c.ClaimHash, now)
		if isUniqueViolation(err) {
			return ErrConflict
		}
		return err
	})
}

const pgCheckoutCols = `intent_id, tenant_id, plan_id, provider, COALESCE(provider_ref, ''), amount_cents, currency,
	status, COALESCE(email, ''), root_pubkey, claim_hash, mail_claim_hash, claim_expires_at, created_at, paid_at, claimed_at`

func scanCheckout(row pgx.Row) (Checkout, error) {
	var c Checkout
	var root []byte
	var paid, claimed, expires *time.Time
	err := row.Scan(&c.ID, &c.TenantID, &c.PlanID, &c.Provider, &c.ProviderRef, &c.AmountCents, &c.Currency,
		&c.Status, &c.Email, &root, &c.ClaimHash, &c.MailClaimHash, &expires, &c.CreatedAt, &paid, &claimed)
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
	return scanCheckout(s.pool.QueryRow(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts WHERE intent_id = $1`, id))
}

func (s *Postgres) CheckoutByProviderRef(ctx context.Context, provider, ref string) (Checkout, error) {
	if ref == "" {
		return Checkout{}, ErrNotFound
	}
	return scanCheckout(s.pool.QueryRow(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts
		WHERE provider = $1 AND provider_ref = $2 ORDER BY created_at DESC LIMIT 1`, provider, ref))
}

func (s *Postgres) ApplyPayment(ctx context.Context, ev PaymentEvent, now time.Time) (string, error) {
	var outcome string
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO webhook_events_seen (provider, event_id, received_at)
			VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, ev.Provider, ev.EventID, now)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			outcome = PayOutcomeDuplicate
			return nil
		}
		if ev.Kind == PayEventIgnore {
			outcome = PayOutcomeIgnored
			return nil
		}
		c, err := scanCheckout(tx.QueryRow(ctx, `SELECT `+pgCheckoutCols+` FROM payment_checkouts
			WHERE intent_id = $1 FOR UPDATE`, ev.CheckoutID))
		if errors.Is(err, ErrNotFound) {
			outcome = PayOutcomeNoMatch
			return nil
		}
		if err != nil {
			return err
		}
		switch ev.Kind {
		case PayEventPaid:
			if c.Status == CheckoutPaid {
				outcome = PayOutcomeAlreadyPaid
				return nil
			}
			tag, err := tx.Exec(ctx, `INSERT INTO tenants (tenant_id, root_pubkey, billing_status, plan_id)
				VALUES ($1, $2, $3, $4) ON CONFLICT (tenant_id) DO NOTHING`,
				c.TenantID, []byte(c.RootPubKey), billing.StatusActive, c.PlanID)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				var root []byte
				if err := tx.QueryRow(ctx, `SELECT root_pubkey FROM tenants WHERE tenant_id = $1 FOR UPDATE`,
					c.TenantID).Scan(&root); err != nil {
					return err
				}
				if !bytes.Equal(root, c.RootPubKey) {
					outcome = PayOutcomeConflict
					return nil
				}
				if _, err := tx.Exec(ctx, `UPDATE tenants SET billing_status = $2 WHERE tenant_id = $1`,
					c.TenantID, billing.StatusActive); err != nil {
					return err
				}
			}
			if _, err := tx.Exec(ctx, `UPDATE payment_checkouts SET status = 'paid', paid_at = $2
				WHERE intent_id = $1`, c.ID, now); err != nil {
				return err
			}
			outcome = PayOutcomePaid
		case PayEventFailed:
			if _, err := tx.Exec(ctx, `UPDATE payment_checkouts SET status = 'failed'
				WHERE intent_id = $1 AND status = 'pending'`, c.ID); err != nil {
				return err
			}
			outcome = PayOutcomeFailed
		case PayEventRefund, PayEventCancel:
			status, err := billing.MapEvent(ev.Kind)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE tenants SET billing_status = $3
				WHERE tenant_id = $1 AND root_pubkey = $2`, c.TenantID, []byte(c.RootPubKey), status); err != nil {
				return err
			}
			outcome = PayOutcomeRefund
		default:
			return errUnknownPayEvent(ev.Kind)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return outcome, nil
}

func (s *Postgres) SetClaimLink(ctx context.Context, id string, mailClaimHash []byte, expires time.Time) error {
	tag, err := s.pool.Exec(ctx, `UPDATE payment_checkouts SET mail_claim_hash = $2, claim_expires_at = $3
		WHERE intent_id = $1`, id, mailClaimHash, expires)
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
	var out Checkout
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
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
