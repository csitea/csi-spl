package store

import (
	"bytes"
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// memPayments is the Memory side of payments.go, guarded by Memory.mu.
type memPayments struct {
	checkouts map[string]*Checkout
	seen      map[[2]string]bool
}

func (p *memPayments) init() {
	if p.checkouts == nil {
		p.checkouts = map[string]*Checkout{}
		p.seen = map[[2]string]bool{}
	}
}

func cloneCheckout(c *Checkout) Checkout {
	out := *c
	out.RootPubKey = append([]byte(nil), c.RootPubKey...)
	out.SealedRootKey = append([]byte(nil), c.SealedRootKey...)
	out.ClaimHash = append([]byte(nil), c.ClaimHash...)
	if len(c.SealedRootKey) == 0 {
		out.SealedRootKey = nil
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
		if t, ok := s.tenants[c.TenantID]; ok {
			if !bytes.Equal(t.RootPubKey, c.RootPubKey) {
				return PayOutcomeConflict, nil
			}
			t.BillingStatus = billing.StatusActive
			s.tenants[c.TenantID] = t
		} else {
			s.tenants[c.TenantID] = Tenant{ID: c.TenantID, RootPubKey: append([]byte(nil), c.RootPubKey...),
				BillingStatus: billing.StatusActive, PlanID: c.PlanID}
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

func (s *Memory) ClaimCheckout(_ context.Context, id string, claimHash []byte, now time.Time) (Checkout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pay.init()
	c, ok := s.pay.checkouts[id]
	if !ok || len(c.ClaimHash) == 0 || !bytes.Equal(c.ClaimHash, claimHash) {
		return Checkout{}, ErrNotFound
	}
	if c.Status != CheckoutPaid {
		return Checkout{}, ErrNotPaid
	}
	if len(c.SealedRootKey) == 0 {
		return Checkout{}, ErrClaimed
	}
	out := cloneCheckout(c)
	c.SealedRootKey, c.ClaimedAt = nil, now
	out.ClaimedAt = now
	return out, nil
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
