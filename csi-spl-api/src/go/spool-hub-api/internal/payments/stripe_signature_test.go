package payments

import (
	"testing"
	"time"
)

// TestVerifyStripeHeaderParts pins the header parse: a part with no "=" is
// skipped, unknown keys are ignored, and t / v1 are both required.
func TestVerifyStripeHeaderParts(t *testing.T) {
	const body, secret = `{"id":"evt_1"}`, "whsec_test"
	now := time.Unix(1700000000, 0)
	good := SignStripe(body, secret, now)
	for header, ok := range map[string]bool{
		good:                       true,
		"junk, " + good:            true,
		good + ",v0=abc,novalue":   true,
		" " + good + " ":           true,
		"t=1700000000":             false,
		"t1700000000,v1=00":        false,
		"t=1700000000,v1=deadbeef": false,
		"t=1700000000,v1":          false,
	} {
		if err := VerifyStripe(header, body, secret, now); (err == nil) != ok {
			t.Errorf("VerifyStripe(%q) = %v, want ok=%v", header, err, ok)
		}
	}
}
