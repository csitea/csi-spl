package spool

import (
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 121 T302, the seat side: a usage report is the sum of the model's own
// records of the turn, in either provider shape; a streamed record written
// twice counts once; a turn with no record, or with two models, has NO
// report (the hub then writes it unmetered), never a zero one.
func TestUsageReportFrom(t *testing.T) {
	const turn = "11111111-1111-4111-8111-111111111111"
	for _, c := range []struct {
		name, provider, in string
		want               wire.UsageReport
	}{
		{"anthropic, transcript lines, a repeated id once", "anthropic", `
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"id":"msg_1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":900,"cache_creation_input_tokens":40}}}
{"type":"assistant","message":{"id":"msg_1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":900,"cache_creation_input_tokens":40}}}
{"type":"assistant","message":{"id":"msg_2","model":"claude-x","usage":{"input_tokens":3,"output_tokens":7}}}`,
			wire.UsageReport{TurnID: turn, Provider: "anthropic", Model: "claude-x", TokensIn: 13, TokensOut: 12, CacheRead: 900, CacheWrite: 40}},
		{"anthropic, one bare response", "anthropic",
			`{"id":"msg_9","model":"claude-y","usage":{"input_tokens":0,"output_tokens":0}}`,
			wire.UsageReport{TurnID: turn, Provider: "anthropic", Model: "claude-y"}},
		{"openai-compatible, cached tokens split out of the prompt", "mistral",
			`{"id":"c1","model":"mistral-small","usage":{"prompt_tokens":1000,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":600}}}
{"id":"c2","model":"mistral-small","usage":{"prompt_tokens":20,"completion_tokens":2}}`,
			wire.UsageReport{TurnID: turn, Provider: "mistral", Model: "mistral-small", TokensIn: 420, TokensOut: 52, CacheRead: 600}},
	} {
		got, err := UsageReportFrom(turn, c.provider, strings.NewReader(c.in))
		if err != nil || *got != c.want {
			t.Errorf("%s: %+v (%v), want %+v", c.name, got, err, c.want)
		}
	}

	for _, c := range []struct{ name, provider, in string }{
		{"no usage record at all", "anthropic", `{"type":"user","message":{"role":"user","content":"hi"}}`},
		{"empty", "anthropic", ``},
	} {
		if got, err := UsageReportFrom(turn, c.provider, strings.NewReader(c.in)); !errors.Is(err, ErrNoUsage) || got != nil {
			t.Errorf("%s: %+v (%v), want no report, ErrNoUsage (never a zero report)", c.name, got, err)
		}
	}
	for _, c := range []struct{ name, provider, in string }{
		{"two models", "anthropic", `{"id":"a","model":"m1","usage":{"input_tokens":1,"output_tokens":1}}
{"id":"b","model":"m2","usage":{"input_tokens":1,"output_tokens":1}}`},
		{"no model", "anthropic", `{"id":"a","usage":{"input_tokens":1,"output_tokens":1}}`},
		{"unknown usage shape", "anthropic", `{"id":"a","model":"m","usage":{"tokens":1}}`},
		{"more cached than prompt", "openai", `{"id":"a","model":"m","usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":2}}}`},
		{"negative count", "anthropic", `{"id":"a","model":"m","usage":{"input_tokens":-1,"output_tokens":1}}`},
		{"bad provider id", "Anthropic", `{"id":"a","model":"m","usage":{"input_tokens":1,"output_tokens":1}}`},
		{"not json", "anthropic", `{"id":`},
	} {
		if got, err := UsageReportFrom(turn, c.provider, strings.NewReader(c.in)); err == nil || got != nil {
			t.Errorf("%s: %+v, want an error and no report", c.name, got)
		}
	}
}
