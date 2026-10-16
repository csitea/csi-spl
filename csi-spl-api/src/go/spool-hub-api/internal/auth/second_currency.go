package auth

import (
	"context"
	"encoding/json"
	"regexp"
	"slices"
	"strings"
)

// A person's second currency for costs, PER TENANT (SPL-2108). Owner HUM-10,
// t1 1b6f871f msg 44fef397: "In the settings of the system, the user should
// be able to configure another currency, and the default for this other
// currency should be euros. This should be in the personal settings". Kept
// ONLY in the membership override (rdb 0078, like time_zone): no humans
// column. Null / never picked = DefaultSecondCurrency. A pick must be a
// currency the hub holds rates for (rdb 0200 fx_rates), so the cost table can
// convert to it; the hub's cost read (GET /v1/tenant/costs) uses it.

// DefaultSecondCurrency is the second currency nobody picked (the owner's
// default). store.DefaultSecondCurrency is the same value.
const DefaultSecondCurrency = "EUR"

var currencyRe = regexp.MustCompile(`^[A-Z]{3}$`)

// CurrencyLister is the optional source of the currencies a second currency
// may be (the quotes of the hub's rates). ok false = the store keeps no rates,
// and the pick is checked for its ISO 4217 shape only.
type CurrencyLister interface {
	FXCurrencies(ctx context.Context) (codes []string, ok bool, err error)
}

const secondCurrencyHint = "second_currency must be an ISO 4217 code the hub has exchange rates for (e.g. EUR) or null"

// parseSecondCurrency reads PUT preferences' second_currency: present = has,
// null or "" clears it (back to EUR). The code is upper-cased. A refusal is
// (code, detail); whether the hub has rates for it is checkSecondCurrency's.
func parseSecondCurrency(raw json.RawMessage) (v string, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return "", false, "", ""
	}
	if s == "null" {
		return "", true, "", ""
	}
	if json.Unmarshal(raw, &v) != nil {
		return "", true, "unsupported_second_currency", secondCurrencyHint
	}
	v = strings.ToUpper(strings.TrimSpace(v))
	if v != "" && !currencyRe.MatchString(v) {
		return "", true, "unsupported_second_currency", secondCurrencyHint
	}
	return v, true, "", ""
}

// checkSecondCurrency refuses a pick the hub holds no rates for (the default
// EUR always passes: the cost read answers null until its rates arrive). A
// failed list read is a 503, never a silent accept.
func (h *Handler) checkSecondCurrency(ctx context.Context, v string) (status int, code, detail string) {
	if v == "" || v == DefaultSecondCurrency {
		return 0, "", ""
	}
	l, ok := h.prefs.(CurrencyLister)
	if !ok {
		return 0, "", ""
	}
	codes, has, err := l.FXCurrencies(ctx)
	switch {
	case err != nil:
		h.log.Error().Err(err).Msg("auth.preferences fx currencies read")
		return 503, ErrCodeUnavailable, "the currencies were not read"
	case has && !slices.Contains(codes, v):
		return 400, "unsupported_second_currency", secondCurrencyHint + "; the hub has rates for: " + strings.Join(codes, ", ")
	}
	return 0, "", ""
}

// secondCurrency is the session human's second currency for the active
// tenant, DefaultSecondCurrency when never picked. Like timeZone it reads the
// overlaid snapshot, so it costs no store round trip.
func (h *Handler) secondCurrency(ctx context.Context, s Session) string {
	if s.HumanID == "" || h.prefs == nil {
		return DefaultSecondCurrency
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && snap.SecondCurrency != "" {
		return snap.SecondCurrency
	}
	return DefaultSecondCurrency
}
