package wire

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// spec 140 T002: the push payload of spec 140 3.4 decodes, round-trips, and
// the minute is truncated to the UTC minute.
func TestFleetTokensPushDecode(t *testing.T) {
	raw := json.RawMessage(`{"samples":[
		{"agent_id":"c-001","vendor":"claude","model":"claude-opus-5-5","minute":"2026-10-15T12:40:37+02:00",
		 "tokens_in":12450,"tokens_out":850,"cache_read":34000,"cache_write":4200,"is_metered":true},
		{"agent_id":"a-204","vendor":"agy","model":null,"minute":"2026-10-15T10:40:00Z",
		 "tokens_in":0,"tokens_out":0,"cache_read":0,"cache_write":0,"is_metered":false},
		{"agent_id":"m-183","vendor":"mistral","minute":"2026-10-15T10:40:00Z","tokens_in":5}]}`)
	p, err := DecodeFleetTokensPush(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Samples) != 3 {
		t.Fatalf("samples %+v", p.Samples)
	}
	c := p.Samples[0]
	if !c.Minute.Equal(time.Date(2026, 10, 15, 10, 40, 0, 0, time.UTC)) || c.ModelName() != "claude-opus-5-5" || c.Total() != 51500 || !c.IsMetered {
		t.Fatalf("claude sample %+v", c)
	}
	if a := p.Samples[1]; a.IsMetered || a.Model != nil || a.Vendor != "agy" {
		t.Fatalf("agy sample %+v", a)
	}
	if m := p.Samples[2]; !m.IsMetered || m.Model != nil {
		t.Fatalf("is_metered absent reads true, model absent reads null: %+v", m)
	}
	enc, _ := json.Marshal(p)
	back, err := DecodeFleetTokensPush(enc)
	if err != nil || len(back.Samples) != 3 || back.Samples[0] != (FleetTokenSample{AgentID: "c-001", Vendor: "claude", Model: back.Samples[0].Model,
		Minute: c.Minute, TokensIn: 12450, TokensOut: 850, CacheRead: 34000, CacheWrite: 4200, IsMetered: true}) {
		t.Fatalf("round trip %s: %+v %v", enc, back, err)
	}
	ack, _ := json.Marshal(FleetTokensAckFrame{Type: "ack", LaneOp: FleetBurnPushOp, Inserted: 2, At: "2026-10-15T10:40:05Z"})
	if string(ack) != `{"type":"ack","lane_op":"fleet_tokens_push","inserted":2,"at":"2026-10-15T10:40:05Z"}` {
		t.Fatalf("ack %s", ack)
	}
}

// spec 140 T002 red control: a sample missing minute, agent_id or vendor,
// or carrying what rdb 0199 would refuse, is refused with ErrBadSamples.
func TestFleetTokensPushStrict(t *testing.T) {
	ok := `"agent_id":"c-1","vendor":"claude","minute":"2026-10-15T10:40:00Z"`
	cases := map[string]string{
		"no minute":         `{"samples":[{"agent_id":"c-1","vendor":"claude","tokens_in":1}]}`,
		"no agent_id":       `{"samples":[{"vendor":"claude","minute":"2026-10-15T10:40:00Z"}]}`,
		"no vendor":         `{"samples":[{"agent_id":"c-1","minute":"2026-10-15T10:40:00Z"}]}`,
		"empty agent_id":    `{"samples":[{"agent_id":"","vendor":"claude","minute":"2026-10-15T10:40:00Z"}]}`,
		"unknown vendor":    `{"samples":[{"agent_id":"c-1","vendor":"gpt","minute":"2026-10-15T10:40:00Z"}]}`,
		"unknown field":     `{"samples":[{` + ok + `,"box_tag":"forged"}]}`,
		"negative count":    `{"samples":[{` + ok + `,"tokens_in":-1}]}`,
		"empty model":       `{"samples":[{` + ok + `,"model":""}]}`,
		"bad minute":        `{"samples":[{"agent_id":"c-1","vendor":"claude","minute":"yesterday"}]}`,
		"metered agy":       `{"samples":[{"agent_id":"a-1","vendor":"agy","minute":"2026-10-15T10:40:00Z"}]}`,
		"unmetered tokens":  `{"samples":[{` + ok + `,"is_metered":false,"tokens_out":3}]}`,
		"duplicate minute":  `{"samples":[{` + ok + `},{"agent_id":"c-1","vendor":"claude","minute":"2026-10-15T10:40:30Z"}]}`,
		"empty samples":     `{"samples":[]}`,
		"not an object":     `"samples"`,
		"top-level unknown": `{"samples":[{` + ok + `}],"box":"x"}`,
	}
	for name, raw := range cases {
		if _, err := DecodeFleetTokensPush(json.RawMessage(raw)); !errors.Is(err, ErrBadSamples) {
			t.Errorf("%s: %v, want ErrBadSamples", name, err)
		}
	}
	many := `{"samples":[` + strings.TrimSuffix(strings.Repeat(`{`+ok+`},`, FleetTokenSamplesMax+1), ",") + `]}`
	if _, err := DecodeFleetTokensPush(json.RawMessage(many)); !errors.Is(err, ErrBadSamples) {
		t.Errorf("%d samples: %v", FleetTokenSamplesMax+1, err)
	}
	// CONTROL: the same fields, all present, pass.
	if _, err := DecodeFleetTokensPush(json.RawMessage(`{"samples":[{` + ok + `}]}`)); err != nil {
		t.Fatalf("CONTROL: %v", err)
	}
}
