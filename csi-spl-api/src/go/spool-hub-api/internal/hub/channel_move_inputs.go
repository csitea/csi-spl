// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"bytes"
	"encoding/json"
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// channelMoveInputs are the owner's decisions and the caller a plan or a step
// carries in its detail (spec 169 T7d, sections 5.1a, 5.1b, 8.4):
//
//   - keep: the HUM ids the owner adds to <DST> (Q5); their hours rows move.
//   - keep_emails: the channel invites that move (5.1b); P4 deletes the others.
//   - leave_hours: the HUM ids whose hours rows stay in <SRC> (Q5, Q8), which
//     clears their hours stops in plan, P2 and P4.
//   - rule_doc: the Qto doc uuid of column 3 of the box rule row (F14), which
//     only the box reads.
//   - caller: MOVE_CALLER, <agent id>[@<box>], the <DST> orchestrator seat P2b
//     probes to; P2 checks that seat. Absent, P2 checks any orchestrator seat,
//     as before T7d.
//
// An absent value is the safe side: no one kept, every hours stop stands. A mark
// carries its own detail (the probes) and reads none of this.
type channelMoveInputs struct {
	Keep       []string `json:"keep"`
	KeepEmails []string `json:"keep_emails"`
	LeaveHours []string `json:"leave_hours"`
	RuleDoc    string   `json:"rule_doc"`
	Caller     string   `json:"caller"`
}

// channelMoveReadInputs reads q.Detail into q.in; it writes the 400.
func channelMoveReadInputs(w http.ResponseWriter, q *channelMoveRequest) bool {
	if q.Op != "plan" && q.Op != "step" {
		return true
	}
	in, why := parseChannelMoveInputs(q.Detail)
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_detail", why)
		return false
	}
	q.in = in
	return true
}

func parseChannelMoveInputs(raw json.RawMessage) (channelMoveInputs, string) {
	var in channelMoveInputs
	if len(bytes.TrimSpace(raw)) > 0 {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&in); err != nil {
			return in, "detail must be {keep, keep_emails, leave_hours, rule_doc, caller}"
		}
	}
	in.Keep, in.LeaveHours, in.KeepEmails = channelMoveSet(in.Keep), channelMoveSet(in.LeaveHours), channelMoveSet(in.KeepEmails)
	in.RuleDoc, in.Caller = strings.ToLower(strings.TrimSpace(in.RuleDoc)), strings.TrimSpace(in.Caller)
	for _, h := range append(slices.Clone(in.Keep), in.LeaveHours...) {
		if !humanIDRe.MatchString(h) {
			return in, "keep and leave_hours are HUM ids, got " + h
		}
	}
	for _, e := range in.KeepEmails {
		if !strings.Contains(e, "@") || strings.ContainsAny(e, " \t\n") {
			return in, "keep_emails are email addresses, got " + e
		}
	}
	if in.RuleDoc != "" && !msg.IsUUID(in.RuleDoc) {
		return in, "rule_doc must be a Qto doc uuid"
	}
	if in.Caller != "" && !agentid.IsAgent(channelMoveCallerAgent(in.Caller)) {
		return in, "caller must be an agent seat, <agent id>[@<box>], got " + in.Caller
	}
	return in, ""
}

// channelMoveSet trims, sorts and dedupes; nil when empty, so P2's record and
// P4's request compare equal.
func channelMoveSet(l []string) []string {
	var out []string
	for _, s := range l {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// channelMoveCallerAgent and channelMoveCallerBox split <agent id>[@<box>].
func channelMoveCallerAgent(c string) string {
	a, _, _ := strings.Cut(c, "@")
	return a
}

func channelMoveCallerBox(c string) string {
	_, b, _ := strings.Cut(c, "@")
	return b
}

// sameDecisions: what P4 applies is what P2 checked. The caller is P2's only.
func (in channelMoveInputs) sameDecisions(o channelMoveInputs) bool {
	return slices.Equal(in.Keep, o.Keep) && slices.Equal(in.KeepEmails, o.KeepEmails) &&
		slices.Equal(in.LeaveHours, o.LeaveHours) && in.RuleDoc == o.RuleDoc
}

// channelMoveStops are plan's stops less the hours stops of the members the owner
// said to leave in <SRC>: what P4's own check (the store's mvStops) refuses on.
func channelMoveStops(p store.ChannelMovePlan, in channelMoveInputs) []string {
	p.Hours = slices.DeleteFunc(slices.Clone(p.Hours), func(h store.HoursStop) bool {
		return slices.Contains(in.LeaveHours, h.Member)
	})
	return p.Stops()
}
