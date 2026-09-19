package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// memPayments is the Memory side of payments.go, guarded by Memory.mu.
type memPayments struct {
	checkouts map[string]*Checkout
	seen      map[[2]string]bool
	periods   map[string][]SeatPeriod // tenant -> seat months, oldest first
}

func (p *memPayments) init() {
	if p.checkouts == nil {
		p.checkouts = map[string]*Checkout{}
		p.seen = map[[2]string]bool{}
		p.periods = map[string][]SeatPeriod{}
	}
}

func cloneCheckout(c *Checkout) Checkout {
	out := *c
	out.RootPubKey = append([]byte(nil), c.RootPubKey...)
	out.ClaimHash = append([]byte(nil), c.ClaimHash...)
	if c.MailClaimHash != nil {
		out.MailClaimHash = append([]byte(nil), c.MailClaimHash...)
	}
	return out
}

func (s *Memory) HoldCheckout(_ context.Context, c Checkout, now time.Time, hold time.Duration) error {
	if err := normalizeCheckout(&c); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	if _, ok := s.tenants[c.TenantID]; ok {
		return ErrConflict
	}
	if _, ok := s.pay.checkouts[c.ID]; ok {
		return ErrConflict
	}
	for _, o := range s.pay.checkouts {
		if o.TenantID != c.TenantID || o.Status != CheckoutPending {
			continue
		}
		if now.Sub(o.CreatedAt) < hold {
			return ErrConflict
		}
		o.Status = CheckoutCancelled
	}
	c.Status, c.CreatedAt = CheckoutPending, now
	s.pay.checkouts[c.ID] = &c
	return nil
}

func (s *Memory) GetCheckout(_ context.Context, id string) (Checkout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	c, ok := s.pay.checkouts[id]
	if !ok {
		return Checkout{}, ErrNotFound
	}
	return cloneCheckout(c), nil
}

func (s *Memory) ApplyPayment(_ context.Context, ev PaymentEvent, now time.Time) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	key := [2]string{ev.Provider, ev.EventID}
	if s.pay.seen[key] {
		return PayOutcomeDuplicate, nil
	}
	s.pay.seen[key] = true
	if ev.Kind == PayEventIgnore {
		return PayOutcomeIgnored, nil
	}
	c, ok := s.pay.checkouts[ev.CheckoutID]
	if !ok {
		return PayOutcomeNoMatch, nil
	}
	switch ev.Kind {
	case PayEventPaid:
		if c.Status == CheckoutPaid {
			return PayOutcomeAlreadyPaid, nil
		}
		t, existed := s.tenants[c.TenantID]
		if existed {
			if !bytes.Equal(t.RootPubKey, c.RootPubKey) {
				return PayOutcomeConflict, nil
			}
			t.BillingStatus = billing.StatusActive
		} else {
			t = Tenant{ID: c.TenantID, RootPubKey: append([]byte(nil), c.RootPubKey...),
				BillingStatus: billing.StatusActive, PlanID: c.PlanID}
		}
		// one "transaction": the line items apply to a copy, nothing is
		// written unless they all succeed
		if err := s.applySeatsLocked(&t, c, ev.Env, now); err != nil {
			delete(s.pay.seen, key)
			return "", err
		}
		s.tenants[c.TenantID] = t
		if !existed {
			s.ch.seedLocked(c.TenantID, now.UTC())
		}
		c.Status, c.PaidAt = CheckoutPaid, now
		return PayOutcomePaid, nil
	case PayEventFailed:
		if c.Status == CheckoutPending {
			c.Status = CheckoutFailed
		}
		return PayOutcomeFailed, nil
	case PayEventRefund, PayEventCancel:
		status, err := billing.MapEvent(ev.Kind)
		if err != nil {
			delete(s.pay.seen, key)
			return "", err
		}
		if t, ok := s.tenants[c.TenantID]; ok && bytes.Equal(t.RootPubKey, c.RootPubKey) {
			t.BillingStatus = status
			s.tenants[c.TenantID] = t
		}
		return PayOutcomeRefund, nil
	}
	delete(s.pay.seen, key)
	return "", errUnknownPayEvent(ev.Kind)
}

func (s *Memory) SetClaimLink(_ context.Context, id string, mailClaimHash []byte, expires time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	c, ok := s.pay.checkouts[id]
	if !ok {
		return ErrNotFound
	}
	c.MailClaimHash, c.ClaimExpires = append([]byte(nil), mailClaimHash...), expires
	return nil
}

func claimMatches(c *Checkout, h []byte) bool {
	return len(h) == 32 && ((len(c.ClaimHash) == 32 && bytes.Equal(c.ClaimHash, h)) ||
		(len(c.MailClaimHash) == 32 && bytes.Equal(c.MailClaimHash, h)))
}

func (s *Memory) ClaimCheckout(_ context.Context, id string, claimHash []byte, now time.Time, newPub ed25519.PublicKey) (Checkout, error) {
	if len(newPub) != ed25519.PublicKeySize {
		return Checkout{}, fmt.Errorf("claim: new root pubkey must be %d bytes", ed25519.PublicKeySize)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	c, ok := s.pay.checkouts[id]
	if !ok {
		return Checkout{}, ErrNotFound
	}
	if !c.ClaimedAt.IsZero() {
		// status already shows claimed=true: no secret in saying so
		return Checkout{}, ErrClaimed
	}
	if !claimMatches(c, claimHash) {
		return Checkout{}, ErrNotFound
	}
	if c.Status != CheckoutPaid {
		return Checkout{}, ErrNotPaid
	}
	if !c.ClaimExpires.IsZero() && !now.Before(c.ClaimExpires) {
		return Checkout{}, ErrClaimExpired
	}
	t, ok := s.tenants[c.TenantID]
	if !ok || !bytes.Equal(t.RootPubKey, c.RootPubKey) {
		return Checkout{}, ErrConflict
	}
	t.RootPubKey = append([]byte(nil), newPub...)
	s.tenants[c.TenantID] = t
	c.RootPubKey = append([]byte(nil), newPub...)
	c.ClaimHash, c.MailClaimHash, c.ClaimedAt = nil, nil, now
	return cloneCheckout(c), nil
}

func (s *Memory) CheckoutByProviderRef(_ context.Context, provider, ref string) (Checkout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	if ref == "" {
		return Checkout{}, ErrNotFound
	}
	for _, c := range s.pay.checkouts {
		if c.Provider == provider && c.ProviderRef == ref {
			return cloneCheckout(c), nil
		}
	}
	return Checkout{}, ErrNotFound
}

// applySeatsLocked is the Memory side of the paid transition's M4 line items
// (009 T002/T004/T005): the caps and the month's seat period when the
// checkout bought seats, and the project_id stamp at now's UTC minute for a
// dedicated SKU whose tenant has none yet. It mutates t only; the period is
// recorded last, after everything that can fail.
func (s *Memory) applySeatsLocked(t *Tenant, c *Checkout, env string, now time.Time) error {
	if c.Org != "" && t.ProjectID == "" {
		if _, err := stampWith(func(id string) error {
			if s.projectHeldLocked(t.ID, id) {
				return ErrConflict
			}
			t.Org, t.App, t.ProjectID, t.BoughtAt = c.Org, c.App, id, now.UTC()
			return nil
		}, c.Org, c.App, env, now); err != nil {
			return err
		}
	}
	if c.SeatsUsers == 0 && c.SeatsBots == 0 {
		return nil
	}
	t.SeatsUsers, t.SeatsBots = c.SeatsUsers, c.SeatsBots
	p := SeatPeriod{TenantID: t.ID, PeriodStart: PeriodStart(now), SeatsUsers: c.SeatsUsers, SeatsBots: c.SeatsBots,
		CheckoutID: c.ID, AmountCents: c.AmountCents, PaidAt: now.UTC()}
	ps := s.pay.periods[t.ID]
	for i := range ps {
		if ps[i].PeriodStart.Equal(p.PeriodStart) {
			ps[i] = mergePeriod(ps[i], p)
			return nil
		}
	}
	s.pay.periods[t.ID] = append(ps, p)
	return nil
}

// mergePeriod: a second paid checkout in the same month keeps the larger
// seat counts and the latest checkout (Postgres: ON CONFLICT ... GREATEST).
func mergePeriod(old, p SeatPeriod) SeatPeriod {
	p.SeatsUsers, p.SeatsBots = max(old.SeatsUsers, p.SeatsUsers), max(old.SeatsBots, p.SeatsBots)
	return p
}

func (s *Memory) SeatPeriods(_ context.Context, tenantID string) ([]SeatPeriod, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	return append([]SeatPeriod(nil), s.pay.periods[tenantID]...), nil
}
