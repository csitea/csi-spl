// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// PlanChannelMove is `plan` of spec 169 (row T4, sections 4, 5.4, 5.5, 5.1a):
// it computes a channel's set in <SRC>, the shared items that make the move
// refuse (Q6 = A), the mentions outside the set (Q4 = A, listed only), the
// channel's people who are not <DST> members (W1, Q5), the hours stops, and
// (row T4b) the set's boxes not pinned in <DST> (R1) and the seated agents
// with no <DST> desk (W2), (row T4d) every seat, and changes nothing (C1).
// Postgres reads <SRC> in one READ ONLY tenant transaction, so a write anywhere
// in it is refused by the server.
//
// The catalogue (channelmove.Catalogue and channelmove.Binds, row T1) comes
// in the request: channelmove's own tests import this package, so this
// package cannot import channelmove.
type ChannelMovePlanner interface {
	PlanChannelMove(ctx context.Context, req ChannelMovePlanRequest) (ChannelMovePlan, error)
}

var (
	_ ChannelMovePlanner = (*Postgres)(nil)
	_ ChannelMovePlanner = (*Memory)(nil)
)

// MoveTable is one channelmove.Entry: Class is its string value ("moved",
// "rewritten", "recomputed", "refuse", "not-channel"), Set and Refs its
// predicates over the table's columns and the @binds, with no tenant term.
type MoveTable struct {
	Table, Class, Set, Refs string
}

// Move classes PlanChannelMove reads (channelmove.Class values).
const (
	MoveClassMoved  = "moved"
	MoveClassRefuse = "refuse"
)

// ChannelMovePlanRequest names the move. Src and Dst are tenant ids.
type ChannelMovePlanRequest struct {
	Src, Channel, Dst string
	// RuleDoc is the Qto doc id in column 3 of the channel's box rule row
	// (F14, on the box, not in the hub); "" = none.
	RuleDoc string
	// Keep are the HUM ids the owner adds to <DST> (Q5): their hours rows
	// move and they are not listed as leaving.
	Keep      []string
	Tables    []MoveTable       // channelmove.Catalogue
	BindTypes map[string]string // channelmove.Binds

	// noSharedCheck drops the shared-item rule: the red control of C7 only.
	noSharedCheck bool
	// noPinCheck drops R1: the red control of C22 only.
	noPinCheck bool
	// noDeskCheck drops W2: the red control of C23 only.
	noDeskCheck bool
}

// ChannelMoveBinds are the frozen id lists of the set (channelmove.Binds,
// spec 169 section 8.3), each sorted.
type ChannelMoveBinds struct {
	Channel   string
	Tasks     []string // M2 every task id (a row's msg_id is a task too: walkTopic)
	Msgs      []string // M2 every msg id
	MarkKeys  []string // 'ch:<channel>', 't:<task>', 'f:<msg>'
	Events    []string // calendar_events of the set's topics
	Jobs      []string // hours_jobs of the set's topics
	Targets   []string // hours targets 'ch:', 't:', 'cal:', 'job:'
	Numbers   []int    // M7 issue numbers
	IssueKeys []string // <prefix>-<number>
	Docs      []string // M8 docs (shared ones left out: they are listed in Shared)
	Nodes     []string // workspace_doc_node ids of Docs
	IDs       []string // every id above as text (5.2)
	IDLikes   []string // '%<id>%' of each of IDs
}

// MoveCount is what one catalogue table holds of the set in <SRC>: Set rows
// the move carries (or, for a refuse table, rows that stop it), Refs rows
// outside the set that point into it.
type MoveCount struct {
	Table string
	Class string
	Set   int
	Refs  int
}

// SharedItem is a thing the set uses that something staying in <SRC> also
// uses (5.5); one of them makes the move refuse (Q6 = A).
type SharedItem struct {
	Kind string // issue | epic | spec_sync | doc | table
	ID   string // the issue key, doc id, spec_path#spec_task_id or table name
	Why  string
}

// Mention is a staying post or Qto item that names the channel or an id of
// the set (5.4): listed, never edited (Q4 = A).
type Mention struct {
	MsgID, TaskID, Channel, Author string // a post
	DocID, ItemID                  string // a Qto item
	Line                           string // the line that names it
}

// HoursStop is one member's hours rows that stop the move (5.1a).
type HoursStop struct {
	Member string
	Rows   int
	Reason string // "Q5": the member does not come to <DST>; "Q8": inside a frozen or approved sheet
}

// MoveSeat is one agent seated in the channel, on its box (M5). The tags are
// the names the shell reads: .seats[].agent, .seats[].box.
type MoveSeat struct {
	Agent string `json:"agent"`
	Box   string `json:"box"`
}

// ChannelMovePlan is plan's answer. Refused() says whether the move may go on.
type ChannelMovePlan struct {
	Src, Channel, Dst string
	Binds             ChannelMoveBinds
	Counts            []MoveCount
	Shared            []SharedItem
	// SharedFiles are blob file ids a staying post also lists: copied, never
	// deleted in <SRC> (T6, C6). Listed, they do not refuse the move.
	SharedFiles []string
	Mentions    []Mention
	Leaving     []string // channel humans neither <DST> members nor kept (W1, Q5)
	Hours       []HoursStop
	// MissingPins are the from_box values of the set's rows with no live pin
	// in <DST>: the rows could be stored there but not re-verified (R1).
	MissingPins []string
	// Seats are every seat of the channel, with a <DST> desk or without one,
	// sorted and once each (T4d): the boxes T9c names and the desks T7's probes
	// reach. [] on a channel with none, never null. The same M5 rows as
	// MissingDesks. plan takes no mode, so a copy lists them too (section 7:
	// a copy carries no seat; the caller decides).
	Seats []MoveSeat `json:"seats"`
	// MissingDesks are the seats with no desk on their box in <DST> (W2). The
	// seats are M5's rows only: the F14 box rule rows live on the box, and the
	// hub cannot read them.
	MissingDesks []MoveSeat
}

// Refused reports anything that stops the move: a shared item, an hours stop,
// a box not pinned in <DST> or a seat with no <DST> desk.
func (p ChannelMovePlan) Refused() bool {
	return len(p.Shared) > 0 || len(p.Hours) > 0 || len(p.MissingPins) > 0 || len(p.MissingDesks) > 0
}

// Stops are the printable reasons the move refuses, one per line, in the
// spec's words for hours (5.1a).
func (p ChannelMovePlan) Stops() []string {
	var out []string
	for _, s := range p.Shared {
		out = append(out, fmt.Sprintf("shared %s %s: %s", s.Kind, s.ID, s.Why))
	}
	for _, h := range p.Hours {
		if h.Reason == "Q5" {
			out = append(out, fmt.Sprintf("hours: %s %d rows not coming to %s (Q5)", h.Member, h.Rows, p.Dst))
		} else {
			out = append(out, fmt.Sprintf("hours: %s %d rows inside a frozen or approved sheet (Q8)", h.Member, h.Rows))
		}
	}
	for _, b := range p.MissingPins {
		out = append(out, fmt.Sprintf("box %s is not pinned in %s (R1)", b, p.Dst))
	}
	for _, d := range p.MissingDesks {
		out = append(out, fmt.Sprintf("seat %s on %s has no desk in %s (W2)", d.Agent, d.Box, p.Dst))
	}
	return out
}

// ErrMoveRequest refuses a request plan cannot run: no channel, the same
// workspace on both sides, or a predicate naming a bind with no type.
var ErrMoveRequest = errors.New("channel move: bad request")

func mpCheckRequest(req ChannelMovePlanRequest) error {
	if err := checkTenant(req.Src); err != nil {
		return err
	}
	if err := checkTenant(req.Dst); err != nil {
		return err
	}
	if strings.TrimSpace(req.Channel) == "" || req.Src == req.Dst {
		return fmt.Errorf("%w: channel %q from %q to %q", ErrMoveRequest, req.Channel, req.Src, req.Dst)
	}
	for _, t := range req.Tables {
		for _, p := range []string{t.Set, t.Refs} {
			for _, m := range moveBindRe.FindAllStringSubmatch(p, -1) {
				if _, ok := req.BindTypes[m[1]]; !ok {
					return fmt.Errorf("%w: %s names @%s, which has no bind type", ErrMoveRequest, t.Table, m[1])
				}
			}
		}
	}
	return nil
}

var moveBindRe = regexp.MustCompile(`@([a-z_]+)`)

// finish fills the binds derived from the ones the drivers read, and sorts.
func (b *ChannelMoveBinds) mpFinish() {
	for _, l := range [][]string{b.Tasks, b.Msgs, b.Events, b.Jobs, b.Docs, b.Nodes, b.IssueKeys} {
		sort.Strings(l)
	}
	sort.Ints(b.Numbers)
	b.MarkKeys = []string{"ch:" + b.Channel}
	b.Targets = []string{"ch:" + b.Channel}
	for _, t := range b.Tasks {
		b.MarkKeys = append(b.MarkKeys, "t:"+t)
		b.Targets = append(b.Targets, "t:"+t)
	}
	for _, m := range b.Msgs {
		b.MarkKeys = append(b.MarkKeys, "f:"+m)
	}
	for _, e := range b.Events {
		b.Targets = append(b.Targets, "cal:"+e)
	}
	for _, j := range b.Jobs {
		b.Targets = append(b.Targets, "job:"+j)
	}
	seen := map[string]bool{}
	b.IDs, b.IDLikes = nil, nil
	add := func(ids ...string) {
		for _, id := range ids {
			if id != "" && !seen[id] {
				seen[id] = true
				b.IDs = append(b.IDs, id)
				b.IDLikes = append(b.IDLikes, "%"+id+"%")
			}
		}
	}
	add(b.Channel)
	add(b.Tasks...)
	add(b.Msgs...)
	add(b.Events...)
	add(b.Jobs...)
	add(b.IssueKeys...)
	add(b.Docs...)
}

// value is a bind's Go value, by its channelmove.Binds name.
func (b ChannelMoveBinds) mpValue(name string) (any, bool) {
	switch name {
	case "channel":
		return b.Channel, true
	case "numbers":
		return mpNonNilInts(b.Numbers), true
	}
	lists := map[string][]string{
		"tasks": b.Tasks, "msgs": b.Msgs, "mark_keys": b.MarkKeys, "events": b.Events, "jobs": b.Jobs,
		"targets": b.Targets, "issue_keys": b.IssueKeys, "docs": b.Docs, "nodes": b.Nodes, "ids": b.IDs, "id_likes": b.IDLikes,
	}
	l, ok := lists[name]
	return mpNonNil(l), ok
}

func mpNonNil(l []string) []string {
	if l == nil {
		return []string{}
	}
	return l
}

func mpNonNilInts(l []int) []int {
	if l == nil {
		return []int{}
	}
	return l
}

// planIssueKey is an issue's key in <SRC> (F6).
func planIssueKey(prefix string, n int) string { return fmt.Sprintf("%s-%d", prefix, n) }

// mentionMatcher finds, in a staying text, the lines that name the channel
// (#<channel>) or an id of the set.
type mentionMatcher struct {
	tag *regexp.Regexp
	ids map[string]bool
}

var planUUIDRe = regexp.MustCompile(`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)

// planUUIDSQL is planUUIDRe for a Postgres `~` prefilter.
const planUUIDSQL = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`

func mpNewMentionMatcher(b ChannelMoveBinds) mentionMatcher {
	m := mentionMatcher{tag: regexp.MustCompile(`#` + regexp.QuoteMeta(b.Channel) + `($|[^A-Za-z0-9_.-])`), ids: map[string]bool{}}
	for _, l := range [][]string{b.Tasks, b.Msgs} {
		for _, id := range l {
			m.ids[id] = true
		}
	}
	return m
}

// lines answers every line of text that names the set, cut to 200 runes.
func (m mentionMatcher) mpLines(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		hit := m.tag.MatchString(line)
		for _, id := range planUUIDRe.FindAllString(line, -1) {
			hit = hit || m.ids[id]
		}
		if !hit {
			continue
		}
		line = strings.TrimSpace(line)
		if r := []rune(line); len(r) > 200 {
			line = string(r[:200])
		}
		out = append(out, line)
	}
	return out
}

// hoursStops turns per-member row counts into the 5.1a stops: Q5 for a
// member neither in <DST> nor kept, Q8 for rows inside a signed-off sheet.
// A member can hit both; each line is cleared on its own.
func mpHoursStops(total, signed map[string]int, inDst func(string) bool, keep []string) []HoursStop {
	kept := map[string]bool{}
	for _, k := range keep {
		kept[k] = true
	}
	members := make([]string, 0, len(total))
	for m := range total {
		members = append(members, m)
	}
	sort.Strings(members)
	var out []HoursStop
	for _, m := range members {
		if total[m] > 0 && !kept[m] && !inDst(m) {
			out = append(out, HoursStop{Member: m, Rows: total[m], Reason: "Q5"})
		}
		if signed[m] > 0 {
			out = append(out, HoursStop{Member: m, Rows: signed[m], Reason: "Q8"})
		}
	}
	return out
}

// mpMissingPins answers the set's from_box values with no live pin in <DST>
// (R1), sorted and once each. A row with no box has no key to re-verify.
func mpMissingPins(fromBoxes []string, pinned func(string) bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, b := range fromBoxes {
		if b != "" && !seen[b] && !pinned(b) {
			out = append(out, b)
		}
		seen[b] = true
	}
	sort.Strings(out)
	return out
}

// mpSeats answers the seats sorted and once each, [] when there are none, so
// the plan marshals .seats as a list.
func mpSeats(seats []MoveSeat) []MoveSeat {
	seen := map[MoveSeat]bool{}
	out := make([]MoveSeat, 0, len(seats))
	for _, seat := range seats {
		if !seen[seat] {
			out = append(out, seat)
		}
		seen[seat] = true
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Agent != out[j].Agent {
			return out[i].Agent < out[j].Agent
		}
		return out[i].Box < out[j].Box
	})
	return out
}

// mpMissingDesks answers the seats with no desk on their box in <DST> (W2),
// sorted and once each. A desk is the box's live roster row: agent_seats
// outlives the roster (rdb 0107), so its row alone says the agent was there,
// not that the desk still is.
func mpMissingDesks(seats []MoveSeat, hasDesk func(MoveSeat) bool) []MoveSeat {
	var out []MoveSeat
	for _, seat := range mpSeats(seats) {
		if !hasDesk(seat) {
			out = append(out, seat)
		}
	}
	return out
}

// leaving answers the channel's humans who are neither <DST> members nor kept.
func mpLeavingOf(humans []string, inDst func(string) bool, keep []string) []string {
	kept := map[string]bool{}
	for _, k := range keep {
		kept[k] = true
	}
	var out []string
	for _, h := range humans {
		if !kept[h] && !inDst(h) {
			out = append(out, h)
		}
	}
	sort.Strings(out)
	return out
}
