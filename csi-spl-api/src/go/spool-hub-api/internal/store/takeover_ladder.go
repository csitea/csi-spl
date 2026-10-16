package store

import (
	"fmt"
	"slices"
	"strings"
)

// The takeover ladder (SPL-2115, owner t1 35beee77 msgs d83369df, 97b09186,
// 20161759): per task kind, the order in which the vendors take over a task
// on the same working branch after the one before them failed, and how many
// failures each vendor is allowed before the next one takes over. A
// workspace setting: "those should be on each workspace's settings".
//
// It lives in tenants.settings (spec 098, rdb 0136, no migration) as two
// registered keys per kind:
//
//	takeover.<kind>.order         "mistral,agy,claude" (comma-separated vendors)
//	takeover.<kind>.max_failures  2 (TakeoverMaxFailuresMin..Max)
//
// An unset key reads as the default below. GET / PUT /v1/takeover-ladder is
// the structured door (hub/takeover_ladder.go); the engine that uses the
// ladder (M1b) reads TakeoverLadderOf(t.Settings).

// TakeoverTaskKinds are the ladder's kinds, in the order the WUI shows them
// (the lane mix's names, SplitTaskKinds without orchestration).
var TakeoverTaskKinds = []string{"specs_and_docs", "tests", "simple_coding", "complex_coding", "i18n", "secret"}

// takeoverSecretBanned never serve the secret kind (the data rule, owner
// msgs 803c3b38, 26117740, 474f32a0).
var takeoverSecretBanned = []string{"agy", "qwen"}

// The bounds of max_failures.
const (
	TakeoverMaxFailuresMin = 1
	TakeoverMaxFailuresMax = 10
)

// TakeoverRung is one kind's ladder.
type TakeoverRung struct {
	Kind        string
	Order       []string // distinct vendors of AgentKinds; the first takes the task first
	MaxFailures int      // failures a vendor is allowed before the next takes over
	Set         bool     // false: both keys read as the default
}

// TakeoverOrderKey is the kind's registered order key.
func TakeoverOrderKey(kind string) string { return "takeover." + kind + ".order" }

// TakeoverFailuresKey is the kind's registered max_failures key.
func TakeoverFailuresKey(kind string) string { return "takeover." + kind + ".max_failures" }

// DefaultTakeoverLadder is the owner's ladder (d83369df: "after Mistral,
// AGI ... If it fails also, then Claude"; 97b09186: coding two failures,
// documentation one), in TakeoverTaskKinds order, each Set false.
func DefaultTakeoverLadder() []TakeoverRung {
	coding := func(kind string) TakeoverRung {
		return TakeoverRung{Kind: kind, Order: []string{"mistral", "agy", "claude"}, MaxFailures: 2}
	}
	return []TakeoverRung{
		{Kind: "specs_and_docs", Order: []string{"agy", "claude"}, MaxFailures: 1},
		coding("tests"),
		coding("simple_coding"),
		coding("complex_coding"),
		{Kind: "i18n", Order: []string{"agy", "claude"}, MaxFailures: 1},
		{Kind: "secret", Order: []string{"claude", "mistral"}, MaxFailures: 2},
	}
}

// ParseTakeoverOrder reads "mistral, agy,claude" into its vendors.
func ParseTakeoverOrder(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// CheckTakeoverOrder is nil when order is a valid ladder for kind: at least
// one vendor, each of AgentKinds, none twice, and no agy or qwen in secret.
// The error text names the rule.
func CheckTakeoverOrder(kind string, order []string) error {
	if len(order) == 0 {
		return fmt.Errorf("%s: name at least one vendor", kind)
	}
	for i, v := range order {
		if !slices.Contains(AgentKinds, v) {
			return fmt.Errorf("%s: vendor %q is not one of %s", kind, v, strings.Join(AgentKinds, ", "))
		}
		if slices.Contains(order[:i], v) {
			return fmt.Errorf("%s: %s is named twice", kind, v)
		}
		if kind == "secret" && slices.Contains(takeoverSecretBanned, v) {
			return fmt.Errorf("secret: %s never takes secret work (the data rule)", v)
		}
	}
	return nil
}

func init() {
	for _, d := range DefaultTakeoverLadder() {
		kind := d.Kind
		RegisterTenantSetting(TenantSettingDef{Key: TakeoverOrderKey(kind), Kind: SettingString,
			Default: strings.Join(d.Order, ","), MaxLen: 64,
			Valid:     func(s string) bool { return CheckTakeoverOrder(kind, ParseTakeoverOrder(s)) == nil },
			ValidHint: takeoverOrderHint(kind)})
		RegisterTenantSetting(TenantSettingDef{Key: TakeoverFailuresKey(kind), Kind: SettingInt,
			Default: d.MaxFailures, Min: TakeoverMaxFailuresMin, Max: TakeoverMaxFailuresMax})
	}
}

func takeoverOrderHint(kind string) string {
	h := "distinct vendors of " + strings.Join(AgentKinds, ", ") + ", comma-separated"
	if kind == "secret" {
		h += ", never agy or qwen"
	}
	return h
}

// TakeoverLadderOf is every kind's ladder in force, in TakeoverTaskKinds
// order: the stored keys, else the default. A stored value the current check
// refuses already reads as the default (decodeTenantSettings).
func TakeoverLadderOf(v TenantSettingValues) []TakeoverRung {
	out := DefaultTakeoverLadder()
	for i, d := range out {
		_, setO := v[TakeoverOrderKey(d.Kind)]
		_, setF := v[TakeoverFailuresKey(d.Kind)]
		out[i].Order = ParseTakeoverOrder(v.String(TakeoverOrderKey(d.Kind)))
		out[i].MaxFailures = v.Int(TakeoverFailuresKey(d.Kind))
		out[i].Set = setO || setF
	}
	return out
}

// TakeoverLadderPatch is the settings patch that stores rungs (each whole:
// both keys) and resets kinds (both keys back to the default). An unknown
// kind, a kind named twice, a bad order or a max_failures out of range is
// ErrBadTenantSetting naming the rule, before anything is written.
func TakeoverLadderPatch(set []TakeoverRung, reset []string) (TenantSettingsPatch, error) {
	p := TenantSettingsPatch{Set: map[string]any{}}
	seen := map[string]bool{}
	name := func(kind string) error {
		if !slices.Contains(TakeoverTaskKinds, kind) {
			return fmt.Errorf("%w: kind %q is not one of %s", ErrBadTenantSetting, kind, strings.Join(TakeoverTaskKinds, ", "))
		}
		if seen[kind] {
			return fmt.Errorf("%w: %s is named twice", ErrBadTenantSetting, kind)
		}
		seen[kind] = true
		return nil
	}
	for _, r := range set {
		if err := name(r.Kind); err != nil {
			return p, err
		}
		if err := CheckTakeoverOrder(r.Kind, r.Order); err != nil {
			return p, fmt.Errorf("%w: %s", ErrBadTenantSetting, err.Error())
		}
		if r.MaxFailures < TakeoverMaxFailuresMin || r.MaxFailures > TakeoverMaxFailuresMax {
			return p, fmt.Errorf("%w: %s: max_failures is %d, want %d..%d", ErrBadTenantSetting,
				r.Kind, r.MaxFailures, TakeoverMaxFailuresMin, TakeoverMaxFailuresMax)
		}
		p.Set[TakeoverOrderKey(r.Kind)] = strings.Join(r.Order, ",")
		p.Set[TakeoverFailuresKey(r.Kind)] = r.MaxFailures
	}
	for _, kind := range reset {
		if err := name(kind); err != nil {
			return p, err
		}
		p.Unset = append(p.Unset, TakeoverOrderKey(kind), TakeoverFailuresKey(kind))
	}
	if len(seen) == 0 {
		return p, fmt.Errorf("%w: name at least one of %s", ErrBadTenantSetting, strings.Join(TakeoverTaskKinds, ", "))
	}
	return p, p.Check()
}
