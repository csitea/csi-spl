package mail

import (
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// Spec 181 row B12: the day-15 reminder names the workspace, the month, the
// amount in EUR and both dates, in every locale; no link, and it never says
// the workspace stops.
func TestInvoiceReminderEveryLocale(t *testing.T) {
	d := InvoiceReminderData{TenantID: "t1", Month: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), Currency: "EUR",
		TotalMicros: "40304999.500000", IssuedOn: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC),
		DueOn: time.Date(2026, 11, 17, 0, 0, 0, 0, time.UTC)}
	subjects := map[string]string{}
	for _, loc := range i18n.Supported {
		m, err := InvoiceReminder("owner@example.com", loc, d)
		if err != nil || m.Locale != loc || m.Template != TemplateInvoiceReminder {
			t.Fatalf("%s: %+v %v", loc, m, err)
		}
		for _, want := range []string{"t1", "2026-10", "40.30 EUR", "2026-11-03", "2026-11-17"} {
			if !strings.Contains(m.TextBody, want) {
				t.Errorf("%s: body lacks %q:\n%s", loc, want, m.TextBody)
			}
		}
		if !strings.Contains(m.Subject, "t1") || !strings.Contains(m.Subject, "2026-10") || strings.ContainsAny(m.Subject, "\r\n") {
			t.Errorf("%s: subject %q", loc, m.Subject)
		}
		if strings.Contains(m.Subject+m.TextBody, "{{") || strings.Contains(m.TextBody, "<no value>") ||
			strings.Contains(m.TextBody, "http") {
			t.Errorf("%s: unrendered or a link:\n%s", loc, m.TextBody)
		}
		subjects[m.Subject] = loc
	}
	if len(subjects) != len(i18n.Supported) {
		t.Errorf("%d distinct subjects for %d locales: a locale is left in another language", len(subjects), len(i18n.Supported))
	}
	en, _ := InvoiceReminder("owner@example.com", "en", d)
	if en.Subject != "Reminder: the 2026-10 invoice of the spool hub workspace t1 is unpaid" ||
		!strings.Contains(en.TextBody, "The workspace and its agents keep running.") {
		t.Errorf("en: %q\n%s", en.Subject, en.TextBody)
	}
	if _, err := InvoiceReminder("owner@example.com", "en", InvoiceReminderData{TotalMicros: "n/a"}); err == nil {
		t.Error("a total that is not a decimal rendered")
	}
}
