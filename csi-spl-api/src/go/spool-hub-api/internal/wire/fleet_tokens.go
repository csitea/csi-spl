package wire

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Live token burn of the fleet's agent lanes (spec 140 sections 3.4, 3.5,
// rdb 0199). A box's collector counts each lane's tokens per UTC minute from
// its transcripts and pushes them over the box's authenticated live
// connection as one lane frame:
//
//	{"type":"lane","msg_id":"<uuid>","lane_op":"fleet_tokens_push",
//	 "lane":{"samples":[FleetTokenSample, ...]}}
//
// The hub answers on the same msg_id with a lane frame whose lane is a
// FleetTokensAckFrame. The writing box is the session's, never the frame's.
// The Monitoring page reads FleetTokenSummaryResponse from
// GET /v1/operator/fleet-tokens.

// FleetBurnPushOp is the lane_op of the push.
const FleetBurnPushOp = "fleet_tokens_push"

// FleetTokenVendors are the agent kinds a sample may name (rdb 0199 CHECK).
var FleetTokenVendors = []string{"claude", "mistral", "grok", "agy", "qwen"}

// FleetBurnVendorUnmetered is the kind whose lanes report no tokens (spec
// 140 2.3.4): its samples say a lane is live, never how much it burned.
const FleetBurnVendorUnmetered = "qwen"

// Push limits.
const (
	// FleetTokenSamplesMax is the most samples one push carries: 40 lanes
	// times 30 minutes of backlog with room to spare.
	FleetTokenSamplesMax = 2000
	// fleetTokenCountMax bounds one minute's count of one kind (1e12: no
	// lane burns a trillion tokens in a minute; a bigger number is a bug).
	fleetTokenCountMax = 1_000_000_000_000
)

// FleetTokenSample is one agent lane's burn in one UTC minute. Model is null
// when the collector could not read it (and for agy). IsMetered absent reads
// as true; an unmetered sample carries zero counts.
type FleetTokenSample struct {
	AgentID    string    `json:"agent_id"`
	Vendor     string    `json:"vendor"`
	Model      *string   `json:"model"`
	Minute     time.Time `json:"minute"`
	TokensIn   int64     `json:"tokens_in"`
	TokensOut  int64     `json:"tokens_out"`
	CacheRead  int64     `json:"cache_read"`
	CacheWrite int64     `json:"cache_write"`
	IsMetered  bool      `json:"is_metered"`
}

// Total is every token of the sample, cache reads included (the dashboard's
// tokens/min).
func (s FleetTokenSample) Total() int64 { return s.TokensIn + s.TokensOut + s.CacheRead + s.CacheWrite }

// ModelName is Model or "".
func (s FleetTokenSample) ModelName() string {
	if s.Model == nil {
		return ""
	}
	return *s.Model
}

// FleetTokensPushFrame is the lane payload of a push.
type FleetTokensPushFrame struct {
	Samples []FleetTokenSample `json:"samples"`
}

// FleetTokensAckFrame is the hub's answer: the samples it wrote (inserted or
// overwrote: a re-sent minute counts once more, never adds a row).
type FleetTokensAckFrame struct {
	Type     string `json:"type"`
	LaneOp   string `json:"lane_op"`
	Inserted int    `json:"inserted"`
	At       string `json:"at"`
}

// ErrBadSamples wraps every refusal of DecodeFleetTokensPush.
var ErrBadSamples = errors.New("bad_samples")

// rawFleetTokenSample is the strict decode: pointers say which required
// field is absent, unknown fields are refused.
type rawFleetTokenSample struct {
	AgentID    *string    `json:"agent_id"`
	Vendor     *string    `json:"vendor"`
	Model      *string    `json:"model"`
	Minute     *time.Time `json:"minute"`
	TokensIn   int64      `json:"tokens_in"`
	TokensOut  int64      `json:"tokens_out"`
	CacheRead  int64      `json:"cache_read"`
	CacheWrite int64      `json:"cache_write"`
	IsMetered  *bool      `json:"is_metered"`
}

// DecodeFleetTokensPush reads and checks a push's lane payload: every
// sample names agent_id, vendor and minute, no unknown field, counts in
// range, one sample per (agent_id, minute). The minute is truncated to the
// UTC minute. Every refusal wraps ErrBadSamples and names the sample.
func DecodeFleetTokensPush(raw json.RawMessage) (FleetTokensPushFrame, error) {
	var in struct {
		Samples []rawFleetTokenSample `json:"samples"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return FleetTokensPushFrame{}, fmt.Errorf("%w: lane must be {samples: [...]}: %v", ErrBadSamples, err)
	}
	switch {
	case len(in.Samples) == 0:
		return FleetTokensPushFrame{}, fmt.Errorf("%w: samples is empty", ErrBadSamples)
	case len(in.Samples) > FleetTokenSamplesMax:
		return FleetTokensPushFrame{}, fmt.Errorf("%w: at most %d samples per push", ErrBadSamples, FleetTokenSamplesMax)
	}
	out := FleetTokensPushFrame{Samples: make([]FleetTokenSample, 0, len(in.Samples))}
	seen := make(map[string]bool, len(in.Samples))
	for i, r := range in.Samples {
		s, why := r.check()
		if why != "" {
			return FleetTokensPushFrame{}, fmt.Errorf("%w: sample %d: %s", ErrBadSamples, i, why)
		}
		k := s.AgentID + "\x00" + s.Minute.Format(time.RFC3339)
		if seen[k] {
			return FleetTokensPushFrame{}, fmt.Errorf("%w: sample %d: a second sample of the same agent_id and minute", ErrBadSamples, i)
		}
		seen[k] = true
		out.Samples = append(out.Samples, s)
	}
	return out, nil
}

func (r rawFleetTokenSample) check() (FleetTokenSample, string) {
	switch {
	case r.AgentID == nil:
		return FleetTokenSample{}, "agent_id is required"
	case r.Vendor == nil:
		return FleetTokenSample{}, "vendor is required"
	case r.Minute == nil || r.Minute.IsZero():
		return FleetTokenSample{}, "minute is required (RFC 3339)"
	}
	s := FleetTokenSample{AgentID: *r.AgentID, Vendor: *r.Vendor, Model: r.Model, Minute: r.Minute.UTC().Truncate(time.Minute),
		TokensIn: r.TokensIn, TokensOut: r.TokensOut, CacheRead: r.CacheRead, CacheWrite: r.CacheWrite, IsMetered: r.IsMetered == nil || *r.IsMetered}
	bad := func(n int64) bool { return n < 0 || n > fleetTokenCountMax }
	switch {
	case s.AgentID == "" || len(s.AgentID) > 100 || hasCtl(s.AgentID):
		return s, "agent_id must be one line of 1..100 bytes"
	case !slices.Contains(FleetTokenVendors, s.Vendor):
		return s, "vendor must be one of " + strings.Join(FleetTokenVendors, ", ")
	case s.Model != nil && (*s.Model == "" || len(*s.Model) > 200 || hasCtl(*s.Model)):
		return s, "model must be null or one line of 1..200 bytes"
	case bad(s.TokensIn) || bad(s.TokensOut) || bad(s.CacheRead) || bad(s.CacheWrite):
		return s, "tokens_in, tokens_out, cache_read and cache_write must be 0..1e12"
	case s.Vendor == FleetBurnVendorUnmetered && s.IsMetered:
		return s, "a " + FleetBurnVendorUnmetered + " sample is unmetered (is_metered false)"
	case !s.IsMetered && s.Total() != 0:
		return s, "an unmetered sample carries zero counts"
	}
	return s, ""
}

func hasCtl(s string) bool {
	return strings.ContainsFunc(s, func(r rune) bool { return r < 0x20 || r == 0x7f })
}

// FleetTokenSummaryResponse is GET /v1/operator/fleet-tokens. Every token
// rate and total of an unmetered vendor or agent is null, never 0.
type FleetTokenSummaryResponse struct {
	AsOf     string             `json:"as_of"`
	Window   string             `json:"window"`
	Summary  FleetTokenSummary  `json:"summary"`
	ByVendor []VendorTokenBurn  `json:"by_vendor"`
	ByAgent  []AgentTokenBurn   `json:"by_agent"`
	History  []FleetTokenMinute `json:"history"`
}

// FleetTokenSummary is the fleet's KPI strip. The burn rates are the mean of
// the last FleetTokenBurnMinutes full minutes; "today" is the UTC day.
// FreshTokensPerMin leaves out cache reads (spec 140 4.4: the surge
// thresholds apply to it). Currency is the price rows' (model_prices).
type FleetTokenSummary struct {
	BurnRateTokensPerMin int64   `json:"burn_rate_tokens_per_min"`
	FreshTokensPerMin    int64   `json:"fresh_tokens_per_min"`
	BurnRateCostPerHour  float64 `json:"burn_rate_cost_per_hour"`
	TodayTotalTokens     int64   `json:"today_total_tokens"`
	TodayCacheRead       int64   `json:"today_cache_read"`
	TodayTotalCost       float64 `json:"today_total_cost"`
	Currency             string  `json:"currency"`
	ActiveAgents         int     `json:"active_agents"`
	UnmeteredAgents      int     `json:"unmetered_agents"`
	UnpricedAgents       int     `json:"unpriced_agents"`
}

// VendorTokenBurn is one agent kind. Status is metered, unmetered or idle.
type VendorTokenBurn struct {
	Vendor               string   `json:"vendor"`
	ActiveAgents         int      `json:"active_agents"`
	BurnRateTokensPerMin *int64   `json:"burn_rate_tokens_per_min"`
	FreshTokensPerMin    *int64   `json:"fresh_tokens_per_min"`
	TodayTokensIn        *int64   `json:"today_tokens_in"`
	TodayTokensOut       *int64   `json:"today_tokens_out"`
	TodayCacheRead       *int64   `json:"today_cache_read"`
	TodayCacheWrite      *int64   `json:"today_cache_write"`
	TodayTotalTokens     *int64   `json:"today_total_tokens"`
	TodayCost            *float64 `json:"today_cost"`
	Status               string   `json:"status"`
}

// AgentTokenBurn is one agent lane (agent_id on box). BurnRate1m is the last
// full minute; BurnRateTokensPerMin the mean of the last
// FleetTokenBurnMinutes.
type AgentTokenBurn struct {
	AgentID              string   `json:"agent_id"`
	Vendor               string   `json:"vendor"`
	Model                *string  `json:"model"`
	Box                  string   `json:"box"`
	BurnRate1m           *int64   `json:"burn_rate_1m_tokens_per_min"`
	BurnRateTokensPerMin *int64   `json:"burn_rate_tokens_per_min"`
	FreshTokensPerMin    *int64   `json:"fresh_tokens_per_min"`
	TodayTotalTokens     *int64   `json:"today_total_tokens"`
	TodayCost            *float64 `json:"today_cost"`
	IsMetered            bool     `json:"is_metered"`
	Priced               bool     `json:"priced"`
	LastActive           string   `json:"last_active"`
}

// FleetTokenMinute is one minute of the window, every metered lane summed.
type FleetTokenMinute struct {
	Minute string  `json:"minute"`
	Tokens int64   `json:"tokens"`
	Fresh  int64   `json:"fresh"`
	Cost   float64 `json:"cost"`
}

// FleetTokenBurnMinutes is the burn-rate window: the last 5 full minutes.
const FleetTokenBurnMinutes = 5
