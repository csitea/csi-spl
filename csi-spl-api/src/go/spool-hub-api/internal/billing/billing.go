// Package billing maps payment.md events onto tenants.billing_status and
// decides which hub verbs an unpaid or over-quota tenant may still run.
//
// This is the 006 T012–T013 gate, not a payment-provider copy: no checkout,
// no webhook HTTP, no card data, no vendor name in this package.
package billing

import (
	"context"
	"fmt"
	"time"
)

// tenants.billing_status CHECK values (0001_hub_core.sql + 0004_tenant_manual.sql).
// internal = our own fleet, never billed; manual = an owner-made renter
// tenant (do_spl_tenant_create), billed out of band until M2 checkout.
const (
	StatusActive   = "active"
	StatusGrace    = "grace"
	StatusUnpaid   = "unpaid"
	StatusInternal = "internal"
	StatusManual   = "manual"
)

// Hub error tokens (003 contracts/error-envelope.md).
const (
	TokenUnpaid = "unpaid"
	TokenQuota  = "quota"
)

// HTTP statuses (006 contracts/http-rental.md).
const (
	HTTPUnpaid = 402
	HTTPQuota  = 429
	// HTTPSeatQuota: a NEW M4 seat over the tenant's cap (specs/009 D-3,
	// 003 error-envelope). Token TokenQuota, like the message quota.
	HTTPSeatQuota = 402
)

// MapEvent is the payment.md table: a paid/unpaid/refund event becomes a
// tenant billing_status. Unknown events fail closed.
func MapEvent(event string) (string, error) {
	switch event {
	case "paid":
		return StatusActive, nil
	case "unpaid", "failed":
		// grace and unpaid refuse writes the same way. The timed grace
		// window is not implemented.
		return StatusGrace, nil
	case "refund", "cancel":
		return StatusUnpaid, nil
	default:
		return "", fmt.Errorf("billing: unknown payment event %q", event)
	}
}

// StatusSetter is the one store method Apply needs.
type StatusSetter interface {
	SetBillingStatus(ctx context.Context, tenantID, status string) error
}

// Apply maps a payment event onto the tenant's billing_status and writes it.
// It is the operator path (spool hub-tenant-billing) until M2 webhooks call
// it too (006 T013b / FR-012). Unknown events write nothing.
func Apply(ctx context.Context, st StatusSetter, tenantID, event string) (string, error) {
	status, err := MapEvent(event)
	if err != nil {
		return "", err
	}
	if err := st.SetBillingStatus(ctx, tenantID, status); err != nil {
		return "", err
	}
	return status, nil
}

// ValidStatus reports a tenants.billing_status CHECK value.
func ValidStatus(s string) bool {
	switch s {
	case StatusActive, StatusGrace, StatusUnpaid, StatusInternal, StatusManual:
		return true
	}
	return false
}

// AllowsWrite is send, pin, revoke, and PUT /v1/files. Recv, GET file, GET
// pins, and WS hello stay up in grace (T013).
func AllowsWrite(status string) bool {
	switch status {
	case StatusActive, StatusInternal, StatusManual, "":
		return true
	default:
		return false
	}
}

// PeriodStart is the UTC month-start used for messages-per-month quota.
func PeriodStart(now time.Time) time.Time {
	u := now.UTC()
	return time.Date(u.Year(), u.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// Quota is one plan tier (cnf). Zero on a field means unlimited.
type Quota struct {
	MessagesPerMonth int
	Pins             int
	FileBytes        int64
}

// Usage is the tenant's current consumption against Quota.
type Usage struct {
	MessagesThisPeriod int
	Pins               int
	FileBytes          int64
}

// Over reports whether adding extra would exceed a set quota. Empty = ok.
func (q Quota) Over(u Usage, extraMessages, extraPins int, extraBytes int64) string {
	if q.MessagesPerMonth > 0 && u.MessagesThisPeriod+extraMessages > q.MessagesPerMonth {
		return TokenQuota
	}
	if q.Pins > 0 && u.Pins+extraPins > q.Pins {
		return TokenQuota
	}
	if q.FileBytes > 0 && u.FileBytes+extraBytes > q.FileBytes {
		return TokenQuota
	}
	return ""
}
