package store

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5"
)

// Generic workspace settings (spec 098, rdb 0136 tenants.settings jsonb).
// A setting that is not worth a column lives as one key of the settings
// object. The hub owns every key: its kind, its default and its check sit in
// this registry, so adding a setting is a RegisterTenantSetting call and no
// DDL. The database keeps only the keys an admin set; an absent key reads as
// its default.
//
// Performance (owner, t1 29b19f85 msg 505e7698): the object rides the cached
// tenant row (getTenant -> hot cache) and is decoded once per cache fill,
// never per message. No query filters on a key. A write is one UPDATE with
// `settings || $set - $unset`: no read-modify-write, so two admins setting
// two keys at once both land. A key that becomes hot (filtered, indexed or
// read on a request path outside the tenant row) is promoted to a column
// (spec 098 section 7).

// SettingKind is the JSON type a key holds.
type SettingKind int

const (
	SettingBool SettingKind = iota + 1
	SettingInt
	SettingString
)

func (k SettingKind) String() string {
	switch k {
	case SettingBool:
		return "bool"
	case SettingInt:
		return "int"
	case SettingString:
		return "string"
	default:
		return "unknown"
	}
}

// TenantSettingDef is one registered key.
type TenantSettingDef struct {
	Key     string      // dotted lower-case words: "area.name"
	Kind    SettingKind // the stored JSON type
	Default any         // bool | int | string, by Kind; must pass the check
	Min     int         // SettingInt: inclusive range (Min == Max == 0 = any int)
	Max     int
	MaxLen  int      // SettingString: at most this many runes (0 = MaxTenantSettingString)
	OneOf   []string // SettingString: when set, the only allowed values
}

// MaxTenantSettingString bounds a string value with no MaxLen of its own.
const MaxTenantSettingString = 200

var tenantSettingKeyRE = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`)

var tenantSettingRegistry = struct {
	sync.RWMutex
	defs map[string]TenantSettingDef
}{defs: map[string]TenantSettingDef{}}

// RegisterTenantSetting adds a key. Call it from a package init; it panics
// on a bad key, a duplicate or a default its own check refuses, so a wrong
// registration fails every test at start-up.
func RegisterTenantSetting(d TenantSettingDef) {
	if len(d.Key) > 64 || !tenantSettingKeyRE.MatchString(d.Key) {
		panic(fmt.Sprintf("store: tenant setting key %q is not dotted lower-case words", d.Key))
	}
	if d.Kind < SettingBool || d.Kind > SettingString {
		panic(fmt.Sprintf("store: tenant setting %q has no kind", d.Key))
	}
	if _, err := d.normalize(d.Default); err != nil {
		panic(fmt.Sprintf("store: tenant setting %q default: %v", d.Key, err))
	}
	tenantSettingRegistry.Lock()
	defer tenantSettingRegistry.Unlock()
	if _, dup := tenantSettingRegistry.defs[d.Key]; dup {
		panic(fmt.Sprintf("store: tenant setting %q registered twice", d.Key))
	}
	tenantSettingRegistry.defs[d.Key] = d
}

// LookupTenantSetting is the registered key, ok=false when none.
func LookupTenantSetting(key string) (TenantSettingDef, bool) {
	tenantSettingRegistry.RLock()
	defer tenantSettingRegistry.RUnlock()
	d, ok := tenantSettingRegistry.defs[key]
	return d, ok
}

// TenantSettingDefs is every registered key, sorted by key.
func TenantSettingDefs() []TenantSettingDef {
	tenantSettingRegistry.RLock()
	out := make([]TenantSettingDef, 0, len(tenantSettingRegistry.defs))
	for _, d := range tenantSettingRegistry.defs {
		out = append(out, d)
	}
	tenantSettingRegistry.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out
}

// ErrBadTenantSetting: an unknown key, or a value its check refuses. The
// wrapped message names the key and the rule; it holds no stored data.
var ErrBadTenantSetting = errors.New("store: bad workspace setting")

// ErrTenantSettingsUnavailable: the database has no tenants.settings yet
// (rdb 0136 not applied). Reads still answer the defaults.
var ErrTenantSettingsUnavailable = errors.New("store: workspace settings column not migrated")

func (d TenantSettingDef) bad(format string, a ...any) error {
	return fmt.Errorf("%w: %s %s", ErrBadTenantSetting, d.Key, fmt.Sprintf(format, a...))
}

// normalize checks v against d and returns it as bool, int or string. v is a
// Go value or what encoding/json decodes (float64, json.Number).
func (d TenantSettingDef) normalize(v any) (any, error) {
	switch d.Kind {
	case SettingBool:
		b, ok := v.(bool)
		if !ok {
			return nil, d.bad("is true or false")
		}
		return b, nil
	case SettingInt:
		return d.normalizeInt(v)
	case SettingString:
		return d.normalizeString(v)
	}
	return nil, d.bad("has no kind")
}

func (d TenantSettingDef) normalizeInt(v any) (any, error) {
	var n int64
	switch x := v.(type) {
	case int:
		n = int64(x)
	case int64:
		n = x
	case json.Number:
		i, err := x.Int64()
		if err != nil {
			return nil, d.bad("is a whole number")
		}
		n = i
	case float64:
		if x != math.Trunc(x) || math.Abs(x) > 1<<53 {
			return nil, d.bad("is a whole number")
		}
		n = int64(x)
	default:
		return nil, d.bad("is a whole number")
	}
	if (d.Min != 0 || d.Max != 0) && (n < int64(d.Min) || n > int64(d.Max)) {
		return nil, d.bad("is from %d to %d", d.Min, d.Max)
	}
	if n < math.MinInt32 || n > math.MaxInt32 {
		return nil, d.bad("is a 32-bit whole number")
	}
	return int(n), nil
}

func (d TenantSettingDef) normalizeString(v any) (any, error) {
	s, ok := v.(string)
	if !ok {
		return nil, d.bad("is a string")
	}
	limit := d.MaxLen
	if limit <= 0 {
		limit = MaxTenantSettingString
	}
	if len([]rune(s)) > limit || strings.ContainsAny(s, "\r\n\x00") {
		return nil, d.bad("is one line of at most %d characters", limit)
	}
	if len(d.OneOf) > 0 {
		for _, o := range d.OneOf {
			if s == o {
				return s, nil
			}
		}
		return nil, d.bad("is one of %s", strings.Join(d.OneOf, ", "))
	}
	return s, nil
}

// TenantSettingValues is the stored part of tenants.settings, decoded and
// checked: registered keys only, each a bool, int or string. It is shared by
// every copy of a cached Tenant, so it is READ-ONLY: writers build a new map.
type TenantSettingValues map[string]any

// value is the stored value of a registered key, else its default.
func (v TenantSettingValues) value(key string) any {
	if x, ok := v[key]; ok {
		return x
	}
	if d, ok := LookupTenantSetting(key); ok {
		return d.Default
	}
	return nil
}

// Bool is the key's value in force; false for an unregistered or non-bool key.
func (v TenantSettingValues) Bool(key string) bool {
	b, _ := v.value(key).(bool)
	return b
}

// Int is the key's value in force; 0 for an unregistered or non-int key.
func (v TenantSettingValues) Int(key string) int {
	n, _ := v.value(key).(int)
	return n
}

// String is the key's value in force; "" for an unregistered or non-string key.
func (v TenantSettingValues) String(key string) string {
	s, _ := v.value(key).(string)
	return s
}

// Effective is every registered key with the value in force (what GET
// /v1/tenant/settings shows).
func (v TenantSettingValues) Effective() map[string]any {
	defs := TenantSettingDefs()
	out := make(map[string]any, len(defs))
	for _, d := range defs {
		out[d.Key] = v.value(d.Key)
	}
	return out
}

// decodeTenantSettings reads the jsonb text. An empty object, the common
// case, costs no decode. A key that is no longer registered, or a value its
// check now refuses, is skipped so its default applies: a removed or
// tightened setting never breaks the tenant row.
func decodeTenantSettings(raw []byte) TenantSettingValues {
	if len(raw) <= 2 { // "", "{}"
		return nil
	}
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber() // ints stay exact
	if dec.Decode(&m) != nil {
		return nil
	}
	tenantSettingRegistry.RLock()
	defer tenantSettingRegistry.RUnlock()
	out := make(TenantSettingValues, len(m))
	for k, x := range m {
		d, ok := tenantSettingRegistry.defs[k]
		if !ok {
			continue
		}
		if n, err := d.normalize(x); err == nil {
			out[k] = n
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// TenantSettingsPatch sets the keys of Set and removes the keys of Unset (an
// unset key reads as its default again).
type TenantSettingsPatch struct {
	Set   map[string]any
	Unset []string
}

// MaxTenantSettingsPatch bounds the keys one patch touches.
const MaxTenantSettingsPatch = 64

// Check is ErrBadTenantSetting when a key or value would be refused, so a
// caller can refuse before it writes anything else.
func (p TenantSettingsPatch) Check() error {
	_, _, err := p.normalize()
	return err
}

// normalize checks every key and value and returns them normalized.
func (p TenantSettingsPatch) normalize() (set map[string]any, unset []string, err error) {
	if len(p.Set)+len(p.Unset) > MaxTenantSettingsPatch {
		return nil, nil, fmt.Errorf("%w: at most %d keys per change", ErrBadTenantSetting, MaxTenantSettingsPatch)
	}
	set = make(map[string]any, len(p.Set))
	for k, v := range p.Set {
		d, ok := LookupTenantSetting(k)
		if !ok {
			return nil, nil, fmt.Errorf("%w: %s is not a workspace setting", ErrBadTenantSetting, k)
		}
		if set[k], err = d.normalize(v); err != nil {
			return nil, nil, err
		}
	}
	unset = make([]string, 0, len(p.Unset))
	for _, k := range p.Unset {
		if _, ok := LookupTenantSetting(k); !ok {
			return nil, nil, fmt.Errorf("%w: %s is not a workspace setting", ErrBadTenantSetting, k)
		}
		if _, both := set[k]; both {
			return nil, nil, fmt.Errorf("%w: %s is both set and reset", ErrBadTenantSetting, k)
		}
		unset = append(unset, k)
	}
	return set, unset, nil
}

// TenantKV is the write side; the read side is Tenant.Settings (cached) and
// TenantConfig.Settings (fresh).
type TenantKV interface {
	// SetTenantSettings applies p in one statement and returns the stored
	// values after it. ErrBadTenantSetting, ErrNotFound (no tenant),
	// ErrTenantSettingsUnavailable (rdb 0136 not applied).
	SetTenantSettings(ctx context.Context, tenant string, p TenantSettingsPatch) (TenantSettingValues, error)
}

var (
	_ TenantKV = (*Memory)(nil)
	_ TenantKV = (*Postgres)(nil)
)

// ---- Memory -----------------------------------------------------------------

func (s *Memory) SetTenantSettings(_ context.Context, tenant string, p TenantSettingsPatch) (TenantSettingValues, error) {
	set, unset, err := p.normalize()
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return nil, ErrNotFound
	}
	next := make(TenantSettingValues, len(t.Settings)+len(set)) // copy: cached copies share the old map
	for k, v := range t.Settings {
		next[k] = v
	}
	for k, v := range set {
		next[k] = v
	}
	for _, k := range unset {
		delete(next, k)
	}
	if len(next) == 0 {
		next = nil
	}
	t.Settings = next
	s.tenants[tenant] = t
	return next, nil
}

// ---- Postgres ---------------------------------------------------------------

// hasTenantSettings is the probe for rdb 0136 tenants.settings.
func (s *Postgres) hasTenantSettings(ctx context.Context) bool {
	return s.kv.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('tenants') AND attname = 'settings' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, s.now())
}

// tenantSettingsCol is the select-list item: an empty object before rdb
// 0136, so one scan shape serves both.
func tenantSettingsCol(with bool) string {
	if !with {
		return "'{}'::jsonb"
	}
	return "settings"
}

func (s *Postgres) SetTenantSettings(ctx context.Context, tenant string, p TenantSettingsPatch) (TenantSettingValues, error) {
	set, unset, err := p.normalize()
	if err != nil {
		return nil, err
	}
	if !s.hasTenantSettings(ctx) {
		return nil, ErrTenantSettingsUnavailable
	}
	setJSON, err := json.Marshal(set)
	if err != nil {
		return nil, err
	}
	// Settings ride the cached tenant row (getTenant): drop the hot entries
	// so the new values take effect at once.
	defer s.hot.forget()
	var raw []byte
	err = s.queryRowTenant(ctx, tenant, `UPDATE tenants SET settings = (settings || $2::jsonb) - $3::text[]
		WHERE tenant_id = $1 RETURNING settings`, []any{tenant, setJSON, unset}, &raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return decodeTenantSettings(raw), nil
}
