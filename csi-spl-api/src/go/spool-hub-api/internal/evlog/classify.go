// SPDX-License-Identifier: AGPL-3.0-only

package evlog

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Source (b) of the backend error log (spec 162 10.4.4): the box reader
// reads the hub's Cloud Logging entries (gcloud logging read
// --format=json) and Classify turns each into a sighting or, for the hub's
// own unwritten line, a whole group. The rules, in order:
//
//  1. a hub line naming a group it could not write (EvlogUnwrittenMsg with
//     fp, kind, n, first_at, last_at): that group, as the hub would have
//     written it;
//  2. any other hub line (jsonPayload.service = spool): skipped, the hub
//     wrote it itself;
//  3. a varlog/system line (out of memory, exit, probe): NOT BUILT (R5);
//  4. a request log entry at status >= 500 whose trace has no hub line:
//     error.cloudrun_request, anchored on the status; with a hub line it is
//     the hub's own 5xx, skipped;
//  5. a non-JSON panic dump: NOT BUILT (R5);
//  6. anything else at severity >= ERROR: error.cloudlog_other.
//
// Rules 3 and 5 match Cloud Run strings not yet read on dev; R5 drops a
// rule that is not read rather than guess it. Row T7 records those strings
// and adds both. Until then such a line at ERROR falls to rule 6, so it is
// still counted, under error.cloudlog_other.

// Kinds of source (b) (spec 162 10.3), the ones Classify writes.
const (
	KindCloudRunRequest = "error.cloudrun_request"
	KindCloudLogOther   = "error.cloudlog_other"
)

// Classify rule numbers (10.4.4).
const (
	RuleUnwritten = 1
	RuleHubLine   = 2
	RuleRequest   = 4
	RuleOther     = 6
)

// RulesBuilt is every rule Classify applies; 3 and 5 wait on T7 (R5).
var RulesBuilt = []int{RuleUnwritten, RuleHubLine, RuleRequest, RuleOther}

// UnwrittenMsg is the hub's EvlogUnwrittenMsg (hub/evlog.go): one ERROR
// line per group its flush could not write.
const UnwrittenMsg = "event log write failed"

// HubService is the service tag of every hub line (logging.New).
const HubService = "spool"

// MaxOriginRunes is rdb 0240's origin_ref cap.
const MaxOriginRunes = 120

// requestsLog ends the logName of Cloud Run's request log.
const requestsLog = "/logs/run.googleapis.com%2Frequests"

// Entry is the part of one Cloud Logging entry Classify reads. Nothing
// else of the entry is taken (10.6: no URL, header or body).
type Entry struct {
	LogName     string         `json:"logName"`
	Severity    string         `json:"severity"`
	Timestamp   time.Time      `json:"timestamp"`
	Trace       string         `json:"trace"`
	TextPayload string         `json:"textPayload"`
	JSONPayload map[string]any `json:"jsonPayload"`
	HTTPRequest *struct {
		Status int `json:"status"`
	} `json:"httpRequest"`
	Resource struct {
		Labels struct {
			RevisionName string `json:"revision_name"`
		} `json:"labels"`
	} `json:"resource"`
}

// Classified is what one entry became: a Sighting (rules 4, 6) or a whole
// Group (rule 1), plus the row's origin.
type Classified struct {
	Rule      int
	Sighting  Sighting
	Group     *Group
	OriginRef string
}

// ParseEntries reads gcloud's JSON array of entries.
func ParseEntries(raw []byte) ([]Entry, error) {
	var es []Entry
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, nil
	}
	if err := json.Unmarshal(raw, &es); err != nil {
		return nil, fmt.Errorf("evlog: entries are not a gcloud JSON array: %w", err)
	}
	return es, nil
}

// HubTraces is the trace of every hub line in es: a request 5xx with one of
// them is the hub's own (rule 4).
func HubTraces(es []Entry) map[string]bool {
	out := map[string]bool{}
	for _, e := range es {
		if e.hubLine() && e.Trace != "" {
			out[e.Trace] = true
		}
	}
	return out
}

// Classify maps one entry to its kind by the rules above; false = not an
// error, or the hub wrote it itself. hubTraces is HubTraces of the window.
func Classify(e Entry, hubTraces map[string]bool) (Classified, bool) {
	if e.hubLine() {
		g, ok := unwrittenGroup(e.JSONPayload)
		if !ok {
			return Classified{}, false // rule 2
		}
		return Classified{Rule: RuleUnwritten, Group: &g}, true
	}
	origin := ""
	if rev := e.Resource.Labels.RevisionName; rev != "" {
		// the revision alone through Redact: with its prefix, a long
		// name would be one run of 24+ token characters, a <blob>
		origin = cutRunes("cloud-run/"+Redact(rev), MaxOriginRunes)
	}
	if e.HTTPRequest != nil && strings.HasSuffix(e.LogName, requestsLog) {
		st := e.HTTPRequest.Status
		if st < 500 || (e.Trace != "" && hubTraces[e.Trace]) {
			return Classified{}, false // rule 4: not an error, or the hub's own 5xx
		}
		return Classified{Rule: RuleRequest, OriginRef: origin, Sighting: Sighting{
			Kind: KindCloudRunRequest, Level: LevelError, At: e.Timestamp,
			Message: fmt.Sprintf("cloud run answered %d", st), Anchor: strconv.Itoa(st),
		}}, true
	}
	if !severeEnough(e.Severity) {
		return Classified{}, false
	}
	return Classified{Rule: RuleOther, OriginRef: origin, Sighting: Sighting{
		Kind: KindCloudLogOther, Level: LevelError, At: e.Timestamp,
		Message: e.text(), Anchor: KindCloudLogOther,
	}}, true
}

func (e Entry) hubLine() bool {
	s, _ := e.JSONPayload["service"].(string)
	return s == HubService
}

// text is the entry's message: its text payload, else the JSON message.
func (e Entry) text() string {
	if e.TextPayload != "" {
		return e.TextPayload
	}
	m, _ := e.JSONPayload["message"].(string)
	return m
}

// severeEnough is severity >= ERROR in Cloud Logging's order.
func severeEnough(sev string) bool {
	switch strings.ToUpper(sev) {
	case "ERROR", "CRITICAL", "ALERT", "EMERGENCY":
		return true
	}
	return false
}

var (
	fpRe        = regexp.MustCompile(`^[0-9a-f]{16}$`)
	groupKindRe = regexp.MustCompile(`^(error|evlog)\.[a-z_]+$`)
)

// unwrittenGroup is the group a hub EvlogUnwrittenMsg line names (rule 1),
// false when the line names none (any other hub line, or the Mine batch's
// line, which carries no fp). The group's own text is read from
// group_message when the line has one, else from message unless that is
// the line's own UnwrittenMsg, else the kind stands in for it.
func unwrittenGroup(p map[string]any) (Group, bool) {
	fp, _ := p["fp"].(string)
	kind, _ := p["kind"].(string)
	n, _ := p["n"].(float64)
	first, err1 := time.Parse(time.RFC3339Nano, str(p["first_at"]))
	last, err2 := time.Parse(time.RFC3339Nano, str(p["last_at"]))
	if !fpRe.MatchString(fp) || !groupKindRe.MatchString(kind) || n < 1 || n != float64(int(n)) ||
		err1 != nil || err2 != nil || first.After(last) {
		return Group{}, false
	}
	msg := str(p["group_message"])
	if msg == "" {
		if m := str(p["message"]); m != UnwrittenMsg {
			msg = m
		}
	}
	if msg == "" {
		msg = kind
	}
	level := LevelError
	if kind == KindOverflow {
		level = LevelWarn
	}
	return Group{Kind: kind, Level: level, Message: Normalize(msg), Fingerprint: fp,
		FirstAt: first, LastAt: last, N: int(n)}, true
}

func str(v any) string { s, _ := v.(string); return s }

func cutRunes(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	return string([]rune(s)[:max])
}

// Batch groups what Classify returns for one reader frame: sightings into
// Groups, rule 1's whole groups by fingerprint, and at most limit groups in
// all (CapReader), the rest counted into one evlog.overflow group (10.4.5).
type Batch struct {
	limit  int
	groups *Groups
	direct map[string]*Group
	order  []string
	origin map[string]string
	extra  int // rule 1 groups past the limit
}

// NewBatch returns an empty Batch of at most limit groups.
func NewBatch(limit int) *Batch {
	return &Batch{limit: limit, groups: NewGroups(limit), direct: map[string]*Group{}, origin: map[string]string{}}
}

// Add takes one classified entry.
func (b *Batch) Add(c Classified) {
	if c.Group != nil {
		b.addGroup(*c.Group)
		return
	}
	fp, kept := b.groups.Add(c.Sighting)
	if kept && c.OriginRef != "" {
		b.origin[fp] = c.OriginRef
	}
}

func (b *Batch) addGroup(g Group) {
	if d, ok := b.direct[g.Fingerprint]; ok {
		d.N += g.N
		d.FirstAt, d.LastAt = minTime(d.FirstAt, g.FirstAt), maxTime(d.LastAt, g.LastAt)
		d.Message = g.Message
		return
	}
	if len(b.direct) >= b.limit {
		b.extra++
		return
	}
	b.direct[g.Fingerprint] = &g
	b.order = append(b.order, g.Fingerprint)
}

// Take returns the groups (rule 1's first, then the sightings' in the
// order they opened), at most limit of them with the overflow group last,
// and each group's origin by fingerprint.
func (b *Batch) Take(at time.Time) ([]Group, map[string]string) {
	out := make([]Group, 0, len(b.order))
	for _, fp := range b.order {
		out = append(out, *b.direct[fp])
	}
	dropped := b.extra
	for _, g := range b.groups.Take(at) {
		if g.Kind == KindOverflow && g.Fingerprint == OverflowGroup(0, b.limit, at).Fingerprint {
			dropped += g.N
			continue
		}
		out = append(out, g)
	}
	if dropped > 0 || len(out) > b.limit {
		keep := min(len(out), b.limit-1)
		dropped += len(out) - keep
		out = append(out[:keep], OverflowGroup(dropped, b.limit, at))
	}
	origin := b.origin
	b.direct, b.order, b.origin, b.extra = map[string]*Group{}, nil, map[string]string{}, 0
	return out, origin
}
