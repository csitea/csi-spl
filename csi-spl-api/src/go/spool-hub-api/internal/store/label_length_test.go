package store

import (
	"strings"
	"testing"
)

// SPL-5583 (the SPL-5488 follow-up): the hr source/account, Netvisor
// forecast label, human key label and fleet plan label limits count
// characters, as their rdb length() CHECKs do (0280, 0255, 0018, 0205), not
// UTF-8 bytes. A Cyrillic letter is 2 bytes, so a byte count refused a
// Cyrillic label at half its documented length.
func TestLabelLimitsCountCharacters(t *testing.T) {
	cyr := func(n int) string { return strings.Repeat("Я", n) }
	asc := func(n int) string { return strings.Repeat("a", n) }
	hrSource := func(s string) bool {
		e := costEntry("op", "hr", "label", 10, "EUR", "2026-10")
		e.Source = s
		return CheckCostEntry(e) == ""
	}
	hrAccount := func(s string) bool {
		e := costEntry("op", "hr", "label", 10, "EUR", "2026-10")
		e.Account = s
		return CheckCostEntry(e) == ""
	}
	forecast := func(s string) bool {
		return normNetvisorItem(&NetvisorForecastItem{Category: "receivable", Sign: 1, Amount: "1.00", Label: s}) == nil
	}
	humanKey := func(s string) bool {
		k := humanKeyRow("h1", KeySourceUploaded)
		k.Label = s
		return checkHumanKey(k) == nil
	}
	planLabel := func(s string) bool {
		it := paidItem("op", "mistral", "subscription", 1, 594, "EUR", "2026-07-01", "2027-01-01")
		it.PlanLabel = s
		return CheckFleetPaidItem(it) == ""
	}
	for _, c := range []struct {
		name  string
		max   int
		check func(string) bool
	}{
		{"cost entry hr source", 200, hrSource},
		{"cost entry hr account", 20, hrAccount},
		{"netvisor forecast label", 200, forecast},
		{"human key label", 80, humanKey},
		{"fleet paid plan label", 100, planLabel},
	} {
		for _, v := range []struct {
			name string
			s    string
			ok   bool
		}{
			{"cyrillic at limit", cyr(c.max), true},
			{"cyrillic over limit", cyr(c.max + 1), false},
			{"ascii at limit", asc(c.max), true},
			{"ascii over limit", asc(c.max + 1), false},
		} {
			if got := c.check(v.s); got != v.ok {
				t.Errorf("%s: %s (%d chars, %d bytes): accepted=%v, want %v", c.name, v.name, len([]rune(v.s)), len(v.s), got, v.ok)
			}
		}
	}
}
