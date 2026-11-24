package hub

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 186 7.1.2: the select phase's resolver, shared by every bulk action
// on topics. The hub alone turns ticks and title patterns into an explicit
// list of topics (4.2): the WUI never decides which titles a pattern matches.

const (
	selectPatternsMax  = 10
	selectPatternBytes = 256
	selectAll          = "*" // the trimmed line: every topic in scope
	tokenBadPattern    = "topic_select_bad_pattern"
	actionMulticast    = "multicast"
)

// selectActions is the permission each bulk action needs for a topic to be
// in scope (4.2 Scope). Spec 153 adds its own (8.3).
var selectActions = map[string]string{actionMulticast: rbac.NotesSend}

// selectedTopic is one resolved topic, as topic_selected names it.
type selectedTopic struct {
	TaskID  string `json:"task_id"`
	Channel string `json:"channel"`
	Title   string `json:"title"`
}

// topicSelector is a parsed topic_select: the action, the ticked task ids
// (lower case), whether a line was `*`, and the compiled patterns.
type topicSelector struct {
	action string
	ticks  map[string]bool
	all    bool
	res    []*regexp.Regexp
}

func badJSON(detail string) *frameRefusal {
	return &frameRefusal{"bad_json", http.StatusBadRequest, detail}
}

// parseTopicSelector checks a frame's action, ticks and patterns. Each line
// is trimmed first (so " * " is `*`), an empty one is dropped, any other is
// an RE2 pattern matched case-insensitively and unanchored. A line that does
// not compile refuses with topic_select_bad_pattern, naming it.
func parseTopicSelector(action string, taskIDs, patterns []string) (topicSelector, *frameRefusal) {
	sel := topicSelector{action: action, ticks: map[string]bool{}}
	switch {
	case selectActions[action] == "":
		return sel, badJSON(fmt.Sprintf("unknown action %q", action))
	case len(taskIDs) == 0 && len(patterns) == 0:
		return sel, badJSON("task_ids and patterns are both empty")
	case len(patterns) > selectPatternsMax:
		return sel, badJSON(fmt.Sprintf("at most %d patterns", selectPatternsMax))
	}
	for _, id := range taskIDs {
		id = strings.ToLower(strings.TrimSpace(id))
		if !uuidRe.MatchString(id) {
			return sel, badJSON("task_ids must be UUIDs")
		}
		sel.ticks[id] = true
	}
	for i, p := range patterns {
		if len(p) > selectPatternBytes {
			return sel, badJSON(fmt.Sprintf("pattern %d is over %d bytes", i+1, selectPatternBytes))
		}
		switch p = strings.TrimSpace(p); p {
		case "":
			continue
		case selectAll:
			sel.all = true
			continue
		}
		re, err := regexp.Compile("(?i)" + p)
		if err != nil {
			return sel, &frameRefusal{tokenBadPattern, http.StatusBadRequest, fmt.Sprintf("line %d: %s: %v", i+1, p, err)}
		}
		sel.res = append(sel.res, re)
	}
	return sel, nil
}

// keeps reports whether a topic in scope is selected: ticked, `*`, or a
// pattern matching its title.
func (sel topicSelector) keeps(task, title string) bool {
	if sel.all || sel.ticks[task] {
		return true
	}
	for _, re := range sel.res {
		if re.MatchString(title) {
			return true
		}
	}
	return false
}

// rowTitle is a topic's title: the subject of its first message (3.4).
func rowTitle(row store.TopicRow) string {
	var first struct {
		Body string `json:"body"`
	}
	if json.Unmarshal(row.FirstMsg, &first) != nil {
		return ""
	}
	return subject(first.Body)
}

// resolveTopicSelector is sel's explicit list for member in tenant. Scope
// (4.2): the channel topics of channels member may read, not archived, not
// an issue's (NoIssues, nor the issues channel), not hidden by the box owner
// lock (row B5, the lobby exempt: checked on the store row before its title
// is read), and none at all when member's role lacks the action's
// permission. Ticks alone read only those topics; `*` or a pattern pages
// the whole scope, viewLimitMax a page, to the end.
func (s *Server) resolveTopicSelector(ctx context.Context, tenant, member string, sel topicSelector) ([]selectedTopic, error) {
	out := []selectedTopic{}
	if !s.allowed(ctx, member, tenant, selectActions[sel.action]) {
		return out, nil
	}
	chans, err := s.readerChannels(ctx, tenant, member)
	if err != nil {
		return nil, err
	}
	lv, err := s.lockViewFor(ctx, tenant, member)
	if err != nil {
		return nil, err
	}
	q := store.TopicQuery{Reader: member, ReaderChannels: chans, NoIssues: true, Lobby: s.o.LobbyTaskID,
		Limit: viewLimitMax, Now: s.o.Now()}
	keep := func(row store.TopicRow) {
		if row.Channel == "" || row.Channel == store.ChannelIssues || s.lockHidesRow(lv, row) {
			return
		}
		if title := rowTitle(row); sel.keeps(row.TaskID, title) {
			out = append(out, selectedTopic{TaskID: row.TaskID, Channel: row.Channel, Title: title})
		}
	}
	if sel.all || len(sel.res) > 0 {
		err = s.pageTopics(ctx, tenant, q, keep)
	} else {
		err = s.tickedTopics(ctx, tenant, q, sel.ticks, keep)
	}
	if err != nil {
		return nil, err
	}
	return out, nil
}

// lockHidesRow is keepTopics' loop on a store row: a seat of a box locked to
// someone else hides the topic, the lobby excepted.
func (s *Server) lockHidesRow(lv lockView, row store.TopicRow) bool {
	if !lv.any() || (s.o.LobbyTaskID != "" && row.TaskID == s.o.LobbyTaskID) {
		return false
	}
	for _, p := range row.Parties {
		if lv.hidesSeat(p) {
			return true
		}
	}
	return false
}

// pageTopics walks q newest first, a page of q.Limit at a time, to the end.
func (s *Server) pageTopics(ctx context.Context, tenant string, q store.TopicQuery, keep func(store.TopicRow)) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		rows, err := s.o.Store.ViewTopics(ctx, tenant, q)
		if err != nil {
			return err
		}
		for _, row := range rows {
			keep(row)
		}
		if len(rows) < q.Limit {
			return nil
		}
		last := rows[len(rows)-1]
		q.BeforeAt, q.BeforeTask = last.LastAt, last.TaskID
	}
}

// tickedTopics reads only the ticked topics (TopicQuery.TaskIDs), q.Limit
// ids a read; each passes every other filter of q or is left out. A tick
// that is not a UUID names no topic and is never read: Postgres casts the
// list to uuid[] and would fail the whole read.
func (s *Server) tickedTopics(ctx context.Context, tenant string, q store.TopicQuery, ticks map[string]bool, keep func(store.TopicRow)) error {
	ids := make([]string, 0, len(ticks))
	for id := range ticks {
		if uuidRe.MatchString(id) {
			ids = append(ids, id)
		}
	}
	for len(ids) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := min(len(ids), q.Limit)
		q.TaskIDs, ids = ids[:n], ids[n:]
		rows, err := s.o.Store.ViewTopics(ctx, tenant, q)
		if err != nil {
			return err
		}
		for _, row := range rows {
			keep(row)
		}
	}
	return nil
}
