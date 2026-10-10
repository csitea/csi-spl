package spool

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The seat's half of metering (specs/121 section 7, T302): the usage report
// a reply carries for the turn it closes, built from the model's OWN usage
// records - never estimated. A record is one response object of the
// provider's API, or one line of it in a JSONL stream. Two shapes are read:
//
//   - Anthropic messages: {"id", "model", "usage": {"input_tokens",
//     "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"}},
//     bare or wrapped as {"message": {...}} (a transcript line).
//   - OpenAI-compatible chat completions (OpenAI, Mistral, ...): {"id",
//     "model", "usage": {"prompt_tokens", "completion_tokens",
//     "prompt_tokens_details": {"cached_tokens"}}}. Cached tokens are part of
//     prompt_tokens there, so tokens_in is prompt_tokens minus them.
//
// A turn of several calls sums its records; a record id seen twice (a
// streamed response written once per content block) counts once. A turn
// that ran more than one model, or whose records carry no usage, has no
// report: the seat sends none and the hub writes the turn unmetered, which
// is a visible gap, never a zero.

// ErrNoUsage: the records hold no usage of the turn.
var ErrNoUsage = errors.New("spool: no usage record")

// usageRecord is the union of the two shapes; Message is the transcript wrap.
type usageRecord struct {
	ID      string       `json:"id"`
	Model   string       `json:"model"`
	Usage   *usageCounts `json:"usage"`
	Message *usageRecord `json:"message"`
}

type usageCounts struct {
	InputTokens         *int64 `json:"input_tokens"`
	OutputTokens        int64  `json:"output_tokens"`
	CacheRead           int64  `json:"cache_read_input_tokens"`
	CacheCreation       int64  `json:"cache_creation_input_tokens"`
	PromptTokens        *int64 `json:"prompt_tokens"`
	CompletionTokens    int64  `json:"completion_tokens"`
	PromptTokensDetails *struct {
		CachedTokens int64 `json:"cached_tokens"`
	} `json:"prompt_tokens_details"`
}

// add folds one record's counts into r.
func (c *usageCounts) add(r *wire.UsageReport) error {
	switch {
	case c.InputTokens != nil:
		r.TokensIn += *c.InputTokens
		r.TokensOut += c.OutputTokens
		r.CacheRead += c.CacheRead
		r.CacheWrite += c.CacheCreation
	case c.PromptTokens != nil:
		cached := int64(0)
		if c.PromptTokensDetails != nil {
			cached = c.PromptTokensDetails.CachedTokens
		}
		if cached > *c.PromptTokens {
			return fmt.Errorf("usage record: %d cached of %d prompt tokens", cached, *c.PromptTokens)
		}
		r.TokensIn += *c.PromptTokens - cached
		r.TokensOut += c.CompletionTokens
		r.CacheRead += cached
	default:
		return fmt.Errorf("usage record: neither input_tokens nor prompt_tokens")
	}
	return nil
}

// UsageReportFrom builds turn's report from the model's own usage records:
// one JSON object or a JSONL stream of them in r, from provider. Records
// without a usage object (a user line, a tool result) are skipped.
// ErrNoUsage: none had one. The report passes wire.UsageReport.Check.
func UsageReportFrom(turn, provider string, r io.Reader) (*wire.UsageReport, error) {
	rep := &wire.UsageReport{TurnID: turn, Provider: provider}
	seen := map[string]bool{}
	dec := json.NewDecoder(bufio.NewReader(r))
	n := 0
	for {
		var rec usageRecord
		err := dec.Decode(&rec)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("usage record %d: %w", n+1, err)
		}
		n++
		if rec.Message != nil && rec.Usage == nil {
			rec = *rec.Message
		}
		if rec.Usage == nil {
			continue
		}
		if rec.ID != "" {
			if seen[rec.ID] {
				continue
			}
			seen[rec.ID] = true
		}
		model := strings.TrimSpace(rec.Model)
		switch {
		case model == "":
			return nil, fmt.Errorf("usage record %d names no model", n)
		case rep.Model != "" && rep.Model != model:
			return nil, fmt.Errorf("the turn ran %s and %s: one report holds one model", rep.Model, model)
		}
		rep.Model = model
		if err := rec.Usage.add(rep); err != nil {
			return nil, err
		}
	}
	if rep.Model == "" {
		return nil, ErrNoUsage
	}
	if err := rep.Check(); err != nil {
		return nil, err
	}
	return rep, nil
}
