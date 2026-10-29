package store

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"time"
	"unicode/utf8"
)

// The marketing metrics store (spec 163 v0.2 section 1, G1 + G2, build row
// B1, SPL-4250; rdb 0244_marketing_metrics.sql). G1 keeps the raw numbers a
// platform reports, a re-fetch adds a row and the read takes the newest per
// key; G2 keeps per metric the formula and its parameters, a changed
// definition is a new version. Both tables are append-only tenant tables
// under RLS; the hub lets a workspace's owner and admins read them (Q8).
// The connectors that write samples are later rows (B3..B16); B1 builds the
// store, the read and the empty Reporting tab.

// The attribution the owner decided (Q7, msg 449350b3: "A — Last touch, 28
// days"), rdb 0244's column defaults; a definition that names none gets it.
const (
	MarketingAttributionLastTouch  = "last_touch"
	MarketingAttributionWindowDays = 28
)

// MarketingObjectTypes is rdb 0244's object_type CHECK, in the spec's order.
var MarketingObjectTypes = []string{"post", "page", "campaign", "site", "landing_page", "query", "email"}

// MarketingMetricSample is one G1 row. Value is the platform's number as
// decimal text, unchanged (numeric in Postgres, never a float). PostID names
// a marketing_posts row or is "".
type MarketingMetricSample struct {
	ID          int64     `json:"id"`
	Tenant      string    `json:"-"`
	Source      string    `json:"source"`
	ObjectType  string    `json:"object_type"`
	ObjectRef   string    `json:"object_ref"`
	PostID      string    `json:"post_id"`
	Metric      string    `json:"metric"`
	Value       string    `json:"value"`
	Unit        string    `json:"unit"`
	PeriodStart time.Time `json:"period_start"`
	PeriodEnd   time.Time `json:"period_end"`
	FetchedAt   time.Time `json:"fetched_at"`
	RunID       string    `json:"run_id"`
}

// MarketingMetricDefinition is one G2 version. SignedOffBy is a HUM id or ""
// (then SignedOffAt is nil): not agreed yet.
type MarketingMetricDefinition struct {
	Tenant                string            `json:"-"`
	Metric                string            `json:"metric"`
	Version               int               `json:"version"`
	Formula               string            `json:"formula"`
	AttributionRule       string            `json:"attribution_rule"`
	AttributionWindowDays int               `json:"attribution_window_days"`
	Params                map[string]string `json:"params"`
	SignedOffBy           string            `json:"signed_off_by"`
	SignedOffAt           *time.Time        `json:"signed_off_at"`
	CreatedBy             string            `json:"created_by"`
	CreatedAt             time.Time         `json:"created_at"`
}

// MarketingMetricsRead is what the Reporting tab reads: the newest sample
// per key and the newest version of each metric's definition.
type MarketingMetricsRead struct {
	Samples     []MarketingMetricSample
	Definitions []MarketingMetricDefinition
}

// MarketingMetrics is the G1 + G2 store. Memory and Postgres implement it.
type MarketingMetrics interface {
	// AddMarketingMetricSample stores one sample of tenant (FetchedAt zero =
	// now) and answers it with its id.
	AddMarketingMetricSample(ctx context.Context, tenant string, m MarketingMetricSample, now time.Time) (MarketingMetricSample, error)
	// AddMarketingMetricDefinition stores the next version of d.Metric for
	// tenant (version = the newest + 1, from 1) and answers it.
	AddMarketingMetricDefinition(ctx context.Context, tenant string, d MarketingMetricDefinition, now time.Time) (MarketingMetricDefinition, error)
	// ReadMarketingMetrics answers tenant's newest sample per key, ordered by
	// (source, object_type, object_ref, metric, period_start), and the newest
	// definition of each metric, ordered by metric.
	ReadMarketingMetrics(ctx context.Context, tenant string) (MarketingMetricsRead, error)
}

var (
	_ MarketingMetrics = (*Memory)(nil)
	_ MarketingMetrics = (*Postgres)(nil)
)

// rdb 0244's text checks.
var (
	mktSourceRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
	mktMetricRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)
	mktUnitRe   = regexp.MustCompile(`^[a-z][a-z0-9_]{0,15}$`)
	mktValueRe  = regexp.MustCompile(`^-?[0-9]{1,30}(\.[0-9]{1,30})?$`)
	mktHumanRe  = regexp.MustCompile(`^HUM-[0-9]+$`)
	mktPostIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

func mktSampleErr(why string) error { return errors.New("marketing metric sample: " + why) }

// normMarketingSample fills the defaults and applies rdb 0244's checks, so a
// bad row is refused before the database sees it (and Memory matches).
func normMarketingSample(m MarketingMetricSample, now time.Time) (MarketingMetricSample, error) {
	if m.Unit == "" {
		m.Unit = "count"
	}
	if m.FetchedAt.IsZero() {
		m.FetchedAt = now
	}
	switch {
	case !mktSourceRe.MatchString(m.Source):
		return m, mktSampleErr("source must be a lowercase id of at most 32 characters")
	case !slices.Contains(MarketingObjectTypes, m.ObjectType):
		return m, mktSampleErr("object_type is not one of rdb 0244's")
	case !utf8.ValidString(m.ObjectRef) || utf8.RuneCountInString(m.ObjectRef) > 512:
		return m, mktSampleErr("object_ref is not valid UTF-8 or longer than 512 characters")
	case m.PostID != "" && !mktPostIDRe.MatchString(m.PostID):
		return m, mktSampleErr("post_id must be a lowercase uuid or empty")
	case !mktMetricRe.MatchString(m.Metric):
		return m, mktSampleErr("metric must be a lowercase id of at most 48 characters")
	case !mktValueRe.MatchString(m.Value):
		return m, mktSampleErr("value must be a decimal number")
	case !mktUnitRe.MatchString(m.Unit):
		return m, mktSampleErr("unit must be a lowercase id of at most 16 characters")
	case m.PeriodStart.IsZero() || m.PeriodEnd.Before(m.PeriodStart):
		return m, mktSampleErr("the period must start, and end at or after its start")
	case utf8.RuneCountInString(m.RunID) > 128:
		return m, mktSampleErr("run_id is longer than 128 characters")
	}
	return m, nil
}

// normMarketingDefinition fills the Q7 attribution defaults and applies rdb
// 0244's checks.
func normMarketingDefinition(d MarketingMetricDefinition) (MarketingMetricDefinition, error) {
	if d.AttributionRule == "" {
		d.AttributionRule = MarketingAttributionLastTouch
	}
	if d.AttributionWindowDays == 0 {
		d.AttributionWindowDays = MarketingAttributionWindowDays
	}
	if d.Params == nil {
		d.Params = map[string]string{}
	}
	switch {
	case !mktMetricRe.MatchString(d.Metric):
		return d, errors.New("marketing metric definition: metric must be a lowercase id of at most 48 characters")
	case d.AttributionRule != MarketingAttributionLastTouch:
		return d, errors.New("marketing metric definition: attribution_rule must be last_touch")
	case d.AttributionWindowDays < 1 || d.AttributionWindowDays > 365:
		return d, errors.New("marketing metric definition: attribution_window_days must be 1..365")
	case !utf8.ValidString(d.Formula) || utf8.RuneCountInString(d.Formula) > 2000:
		return d, errors.New("marketing metric definition: formula is not valid UTF-8 or longer than 2000 characters")
	case d.SignedOffBy != "" && !mktHumanRe.MatchString(d.SignedOffBy):
		return d, errors.New("marketing metric definition: signed_off_by must be a HUM id")
	case (d.SignedOffBy == "") != (d.SignedOffAt == nil):
		return d, errors.New("marketing metric definition: signed_off_by and signed_off_at are both set or both empty")
	case utf8.RuneCountInString(d.CreatedBy) > 64:
		return d, errors.New("marketing metric definition: created_by is longer than 64 characters")
	}
	return d, nil
}

// mktSampleKeyLess orders samples by the read's key.
func mktSampleKeyLess(a, b MarketingMetricSample) int {
	for _, c := range [][2]string{{a.Source, b.Source}, {a.ObjectType, b.ObjectType}, {a.ObjectRef, b.ObjectRef}, {a.Metric, b.Metric}} {
		if c[0] != c[1] {
			if c[0] < c[1] {
				return -1
			}
			return 1
		}
	}
	if d := a.PeriodStart.Compare(b.PeriodStart); d != 0 {
		return d
	}
	return a.PeriodEnd.Compare(b.PeriodEnd)
}
