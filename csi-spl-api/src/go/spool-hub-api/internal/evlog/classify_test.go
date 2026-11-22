// SPDX-License-Identifier: AGPL-3.0-only

package evlog

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// Synthetic fixtures only, written from the field names of spec 162 10.4.3
// and 10.4.4 (no cloud read): one entry per built rule plus the skips.
func fixtureEntries(t *testing.T) []Entry {
	t.Helper()
	raw, err := os.ReadFile("testdata/entries.json")
	if err != nil {
		t.Fatal(err)
	}
	es, err := ParseEntries(raw)
	if err != nil {
		t.Fatal(err)
	}
	return es
}

// C37: each built rule maps its entry to its kind; a hub ERROR line (rule 2)
// and a request 5xx with a hub trace (rule 4) are skipped, as are a 404, the
// Mine batch's unwritten line (it names no group) and an INFO line.
func TestClassifyRules(t *testing.T) {
	es := fixtureEntries(t)
	traces := HubTraces(es)
	want := []struct {
		ok         bool
		rule       int
		kind, anch string
	}{
		{true, RuleUnwritten, "error.http_server", ""},
		{false, 0, "", ""}, // rule 2: the hub's own http 5xx line
		{false, 0, "", ""}, // rule 2: the Mine batch's line, no fp
		{false, 0, "", ""}, // rule 4: request 5xx with a hub trace
		{true, RuleRequest, KindCloudRunRequest, "503"},
		{false, 0, "", ""}, // a 404 is not an error
		{true, RuleOther, KindCloudLogOther, KindCloudLogOther},
		{false, 0, "", ""}, // INFO
	}
	if len(es) != len(want) {
		t.Fatalf("%d fixtures, %d wants", len(es), len(want))
	}
	for i, w := range want {
		c, ok := Classify(es[i], traces)
		if ok != w.ok || c.Rule != w.rule {
			t.Errorf("entry %d: ok %v rule %d, want ok %v rule %d", i, ok, c.Rule, w.ok, w.rule)
			continue
		}
		switch {
		case !ok:
		case c.Group != nil:
			g := c.Group
			if g.Kind != w.kind || g.Fingerprint != "0123456789abcdef" || g.N != 7 || g.Level != LevelError ||
				!g.FirstAt.Equal(time.Date(2026, 11, 20, 9, 59, 0, 0, time.UTC)) || g.Message != "error.http_server" {
				t.Errorf("entry %d: rule 1 group %+v", i, g)
			}
		default:
			s := c.Sighting
			if s.Kind != w.kind || s.Anchor != w.anch || s.Level != LevelError || c.OriginRef != "cloud-run/spool-hub-00042-abc" {
				t.Errorf("entry %d: sighting %+v origin %q", i, s, c.OriginRef)
			}
		}
	}
}

// R5: rules 3 and 5 (Cloud Run's out-of-memory / exit / probe lines and
// split panic dumps) are not built until row T7 reads their strings on dev.
// Their lines are not lost: at ERROR they fall to rule 6, below it they are
// skipped. When T7 adds a rule, this test changes with it.
func TestClassifyRulesNotBuilt(t *testing.T) {
	if !slices.Equal(RulesBuilt, []int{1, 2, 4, 6}) {
		t.Fatalf("RulesBuilt = %v; rules 3 and 5 wait on T7 (spec 162 R5)", RulesBuilt)
	}
	sys := "projects/p-dev/logs/run.googleapis.com%2Fvarlog%2Fsystem"
	for _, e := range []Entry{
		{LogName: sys, Severity: "ERROR", TextPayload: "Memory limit exceeded"},
		{LogName: "projects/p-dev/logs/run.googleapis.com%2Fstderr", Severity: "ERROR", TextPayload: "panic: boom"},
	} {
		c, ok := Classify(e, nil)
		if !ok || c.Rule != RuleOther || c.Sighting.Kind != KindCloudLogOther {
			t.Errorf("%q: rule %d kind %q, want rule 6 error.cloudlog_other", e.TextPayload, c.Rule, c.Sighting.Kind)
		}
	}
	if _, ok := Classify(Entry{LogName: sys, Severity: "INFO", TextPayload: "Container started"}, nil); ok {
		t.Error("an INFO varlog/system line was taken")
	}
}

// Rule 1 reads the line the hub really writes (hub/evlog.go writeGroup):
// zerolog's own message key collides with the group's "message" field, so
// the decoded line keeps only one of the two. The group is found by its
// fields either way; a "group_message" field wins when the line has one.
func TestClassifyHubUnwrittenLine(t *testing.T) {
	first := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	var buf bytes.Buffer
	hub := zerolog.New(&buf).With().Str("service", HubService).Logger()
	hub.Error().
		Str("fp", "fedcba9876543210").Str("kind", "error.panic").Int("n", 3).
		Time("first_at", first).Time("last_at", first.Add(time.Minute)).Str("message", "panic: <s>").
		Str("error", "store down").Msg(UnwrittenMsg)
	if n := strings.Count(buf.String(), `"message":`); n != 2 {
		t.Fatalf("the hub line carries %d message keys, want the 2 that collide: %s", n, buf.String())
	}
	var p map[string]any
	if err := json.Unmarshal(buf.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	c, ok := Classify(Entry{Severity: "ERROR", JSONPayload: p}, nil)
	if !ok || c.Group == nil || c.Group.Fingerprint != "fedcba9876543210" || c.Group.N != 3 || c.Group.Kind != "error.panic" {
		t.Fatalf("hub line %s: ok %v %+v", buf.String(), ok, c.Group)
	}
	p["group_message"] = "panic: <s>"
	if c, _ := Classify(Entry{JSONPayload: p}, nil); c.Group.Message != "panic: <s>" {
		t.Errorf("group_message not taken: %q", c.Group.Message)
	}
	for _, bad := range []string{`"fp":"xyz"`, `"n":0`, `"kind":"Bad"`} {
		q := map[string]any{}
		for k, v := range p {
			q[k] = v
		}
		kv := strings.SplitN(bad, ":", 2)
		var v any
		json.Unmarshal([]byte(kv[1]), &v) //nolint:errcheck
		q[strings.Trim(kv[0], `"`)] = v
		if _, ok := Classify(Entry{JSONPayload: q}, nil); ok {
			t.Errorf("%s: a malformed group line was taken", bad)
		}
	}
}

// The reader's frame holds at most CapReader groups, the last one the
// evlog.overflow row counting the groups dropped (10.4.5); rule 1 groups
// of one fingerprint add up.
func TestBatchCap(t *testing.T) {
	at := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	b := NewBatch(5)
	g := Group{Kind: "error.log", Level: LevelError, Message: "x", Fingerprint: "00000000000000aa", FirstAt: at, LastAt: at, N: 2}
	b.Add(Classified{Rule: RuleUnwritten, Group: &g})
	b.Add(Classified{Rule: RuleUnwritten, Group: &g})
	for i := 0; i < 8; i++ {
		b.Add(Classified{Rule: RuleOther, OriginRef: "cloud-run/r1", Sighting: Sighting{
			Kind: KindCloudLogOther, Level: LevelError, Message: fmt.Sprintf("boom %c", 'a'+i), Anchor: KindCloudLogOther, At: at}})
	}
	out, origin := b.Take(at)
	if len(out) != 5 || out[0].N != 4 || out[4].Kind != KindOverflow || out[4].N != 5 {
		t.Fatalf("take = %+v", out)
	}
	if origin[out[1].Fingerprint] != "cloud-run/r1" {
		t.Errorf("origin = %v", origin)
	}
	if again, _ := b.Take(at); len(again) != 0 {
		t.Errorf("take did not empty the batch: %+v", again)
	}
}
