package billing

import "testing"

func TestMapEvent(t *testing.T) {
	cases := []struct {
		event, want string
	}{
		{"paid", StatusActive},
		{"unpaid", StatusGrace},
		{"failed", StatusGrace},
		{"refund", StatusUnpaid},
		{"cancel", StatusUnpaid},
	}
	for _, c := range cases {
		got, err := MapEvent(c.event)
		if err != nil || got != c.want {
			t.Fatalf("MapEvent(%q) = %q %v, want %q", c.event, got, err, c.want)
		}
	}
	if _, err := MapEvent("unknown"); err == nil {
		t.Fatal("unknown event must fail closed")
	}
}

func TestAllowsWrite(t *testing.T) {
	if !AllowsWrite(StatusActive) || !AllowsWrite(StatusInternal) || !AllowsWrite("") {
		t.Fatal("active/internal must allow send/pin")
	}
	if AllowsWrite(StatusGrace) || AllowsWrite(StatusUnpaid) {
		t.Fatal("grace/unpaid must refuse send/pin")
	}
}

func TestQuotaOver(t *testing.T) {
	q := Quota{MessagesPerMonth: 2, Pins: 1, FileBytes: 10}
	if tok := q.Over(Usage{MessagesThisPeriod: 1}, 1, 0, 0); tok != "" {
		t.Fatalf("under message quota: %q", tok)
	}
	if tok := q.Over(Usage{MessagesThisPeriod: 2}, 1, 0, 0); tok != TokenQuota {
		t.Fatalf("over message quota: %q", tok)
	}
	if tok := q.Over(Usage{Pins: 1}, 0, 1, 0); tok != TokenQuota {
		t.Fatalf("over pin quota: %q", tok)
	}
	if tok := q.Over(Usage{Pins: 1}, 0, 0, 0); tok != "" {
		t.Fatalf("re-pin at cap must not count as extra: %q", tok)
	}
	if tok := q.Over(Usage{FileBytes: 8}, 0, 0, 3); tok != TokenQuota {
		t.Fatalf("over file quota: %q", tok)
	}
	unlimited := Quota{}
	if tok := unlimited.Over(Usage{MessagesThisPeriod: 1e6, Pins: 1e6, FileBytes: 1 << 40}, 1, 1, 1); tok != "" {
		t.Fatalf("zero quota is unlimited: %q", tok)
	}
}
