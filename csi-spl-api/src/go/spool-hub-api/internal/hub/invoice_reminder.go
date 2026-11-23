package hub

import (
	"context"
	"slices"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The monthly invoice reminder (spec 181 row B12, gap G13): a private
// workspace's invoice is due 14 days net from its issue date (Q-19 A); on
// day 15, when it is still unpaid, every biz owner of the workspace gets one
// reminder mail. That is all that happens: no lease is refused, no seat
// stops, nothing is cancelled; the owner decides each case by hand
// (Q-17 B, the overdue list of row B13).

// invoiceReminderEvery is the tick: hourly is soon enough for a day-15 mail.
const invoiceReminderEvery = time.Hour

// InvoiceReminderMailer mails one invoice reminder to one biz owner (to, in
// locale). nil = no relay: no reminder is claimed, so none is lost.
type InvoiceReminderMailer func(ctx context.Context, to, locale string, inv store.Invoice) error

// runInvoiceReminders sends the due reminders every invoiceReminderEvery
// until ctx ends.
func (s *Server) runInvoiceReminders(ctx context.Context) {
	t := time.NewTicker(invoiceReminderEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.InvoiceRemindersOnce(ctx)
		}
	}
}

// InvoiceRemindersOnce claims every unpaid invoice past its due date that
// has had no reminder and mails each one's biz owners. A claim is made once
// (store.Invoices), so a second tick, or a second hub instance, sends
// nothing more. A reminder that reached nobody is released and tried again
// on the next tick. It answers how many invoices were reminded.
func (s *Server) InvoiceRemindersOnce(ctx context.Context) int {
	inv, ok := s.o.Store.(store.Invoices)
	if !ok || s.o.InvoiceReminderMail == nil {
		return 0
	}
	due, err := inv.ClaimInvoiceReminders(ctx, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("invoice_reminder.claim")
		return 0
	}
	sent := 0
	for _, d := range due {
		if s.mailInvoiceReminder(ctx, d) > 0 {
			sent++
			continue
		}
		if err := inv.ReleaseInvoiceReminder(ctx, d.Tenant, d.Month, *d.RemindedAt); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", d.Tenant).Msg("invoice_reminder.release")
		}
	}
	return sent
}

// mailInvoiceReminder mails d to every active biz owner of its workspace and
// answers how many it reached.
func (s *Server) mailInvoiceReminder(ctx context.Context, d store.Invoice) int {
	month := d.Month.Format("2006-01")
	md, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		return 0
	}
	members, err := md.ListMembers(ctx, d.Tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", d.Tenant).Str("month", month).Msg("invoice_reminder.members")
		return 0
	}
	h, _ := s.o.Store.(store.Humans)
	reached := 0
	for _, m := range members {
		if m.Email == "" || m.Disabled || m.Suspended || !(m.Role == rbac.BizOwner || slices.Contains(m.Roles, rbac.BizOwner)) {
			continue
		}
		locale := ""
		if h != nil {
			locale, _ = h.PreferredLocale(ctx, m.HumanID)
		}
		if err := s.o.InvoiceReminderMail(ctx, m.Email, locale, d); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", d.Tenant).Str("month", month).Str("to", mail.Digest(m.Email)).
				Msg("invoice_reminder.mail_failed")
			continue
		}
		reached++
	}
	s.o.Log.Info().Str("tenant", d.Tenant).Str("month", month).Int("reached", reached).Msg("invoice_reminder.sent")
	return reached
}
