package store

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// rdb 0025 (spec 021 T022): the buyer's locale rides the checkout row on every
// driver, "" means they never said, and a code the hub does not ship is
// refused at the door rather than stored and later spliced into a mail
// template path. On postgres the CHECK constraint says the same thing; this
// test is what proves the Go side agrees with it.
func TestCheckoutKeepsBuyerLocale(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			for _, loc := range []string{"fi", "he", i18n.DefaultLocale, ""} {
				tenant := uid("t")
				c := testCheckout(t, tenant)
				c.Locale = loc
				if err := st.HoldCheckout(ctx, c, now, time.Hour); err != nil {
					t.Fatalf("hold with locale %q: %v", loc, err)
				}
				got, err := st.GetCheckout(ctx, c.ID)
				if err != nil || got.Locale != loc {
					t.Fatalf("locale %q came back %q: %v", loc, got.Locale, err)
				}
			}
			// CONTROL: nothing outside i18n.Supported is stored, whatever
			// shape it has.
			for _, bad := range []string{"zz", "klingon", "EN", "en-US", "../../etc/passwd", " fi"} {
				c := testCheckout(t, uid("t"))
				c.Locale = bad
				if err := st.HoldCheckout(ctx, c, now, time.Hour); err == nil {
					t.Errorf("stored locale %q", bad)
				}
				if _, err := st.GetCheckout(ctx, c.ID); err == nil {
					t.Errorf("locale %q left a checkout row behind", bad)
				}
			}
		})
	}
}
