package hub

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/view/topics?since=<cursor>[&rx=<msg_id>~<n>...] - reconnect
// catch-up as a delta (db payload audit round 2, R2-2).
//
// A tab that lost its socket used to re-read its whole channel page. With
// since= (the cursor of the newest message it holds) the list answers only
// the topics that changed after it - a new message, an edit, a kind change,
// a move, an archive, a reaction - each with the usual per_topic page, and
// `delta: true`. rx= is a held message's reaction count, so a reaction
// REMOVED in the gap (no row is left behind) is a change too
// (store/view_changes.go). gone_tasks are topics archived since (they leave
// every list) and gone_msgs are lobby rows archived since and rows moved out
// of the listed channel: the browser drops them.
//
// Every since= answer carries `sync`, a cursor at the hub's clock when it
// read: the browser's next since= is the later of it and its newest row, so a
// change it has caught up is not sent again on the next reconnect.
//
// The hub answers the ordinary full page, with `delta: false`, when it
// cannot vouch for the delta: since is older than deltaMaxAge, the gap holds
// more changes than one answer should carry, or the store has no change
// read. A hub that predates since= ignores it and answers the full page
// without the flag; the browser treats both alike.

const (
	// deltaMaxAge: a longer gap reads the whole page.
	deltaMaxAge = 24 * time.Hour
	// deltaSkew widens since: received_at is stamped before its row commits,
	// so a row stamped just before the newest one the browser holds may have
	// committed after the browser read. Rows re-sent twice merge by msg_id.
	deltaSkew = 30 * time.Second
	// deltaMaxChanges caps the change read; a full answer means "too many".
	deltaMaxChanges = 500
	// deltaMaxHeld caps rx= (the browser sends at most this many).
	deltaMaxHeld = 200
)

// topicsDelta is a parsed since= request.
type topicsDelta struct {
	at   time.Time
	held map[string]int
}

// deltaAnswer is what the change read decided: the topics to list and the
// rows the browser drops.
type deltaAnswer struct {
	tasks     []string
	goneTasks []string
	goneMsgs  []string
}

// parseTopicsDelta reads since= and rx=. nil = no since=; ok false = it
// answered 400.
func parseTopicsDelta(w http.ResponseWriter, r *http.Request) (*topicsDelta, bool) {
	q := r.URL.Query()
	c := q.Get("since")
	if c == "" {
		return nil, true
	}
	at, _, err := decCursor(c)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_cursor", "since is not a cursor from this API")
		return nil, false
	}
	if q.Get("before") != "" {
		writeErr(w, http.StatusBadRequest, "bad_cursor", "since is the first page only: drop before")
		return nil, false
	}
	d := &topicsDelta{at: at, held: map[string]int{}}
	if len(q["rx"]) > deltaMaxHeld {
		writeErr(w, http.StatusBadRequest, "bad_json", "at most "+strconv.Itoa(deltaMaxHeld)+" rx")
		return nil, false
	}
	for _, v := range q["rx"] {
		id, n, ok := strings.Cut(v, "~")
		k, err := strconv.Atoi(n)
		if !ok || !uuidRe.MatchString(id) || err != nil || k < 0 {
			writeErr(w, http.StatusBadRequest, "bad_json", "rx must be <msg-id>~<reaction count>")
			return nil, false
		}
		d.held[strings.ToLower(id)] = k
	}
	return d, true
}

// readDelta runs the change read for sq. nil = answer the full page.
func (s *Server) readDelta(ctx context.Context, tenant string, sq store.TopicQuery, d *topicsDelta) (*deltaAnswer, error) {
	ch, ok := s.o.Store.(store.ViewChanger)
	if !ok || sq.Now.Sub(d.at) > deltaMaxAge {
		return nil, nil
	}
	cs, err := ch.ViewChanges(ctx, tenant, store.ChangeQuery{Since: d.at.Add(-deltaSkew), Held: d.held,
		Max: deltaMaxChanges, Now: sq.Now})
	if err != nil || len(cs) >= deltaMaxChanges {
		return nil, err
	}
	a := &deltaAnswer{}
	tasks, goneT, goneM := map[string]bool{}, map[string]bool{}, map[string]bool{}
	add := func(set map[string]bool, list *[]string, id string) {
		if id != "" && !set[id] {
			set[id] = true
			*list = append(*list, id)
		}
	}
	for _, c := range cs {
		add(tasks, &a.tasks, c.TaskID)
		add(tasks, &a.tasks, c.HomeTask)
		switch {
		case c.Kind == store.ChangeArchive && inListScope(sq, c) && c.TaskID == sq.Lobby:
			add(goneM, &a.goneMsgs, c.MsgID)
		case c.Kind == store.ChangeArchive && inListScope(sq, c):
			add(goneT, &a.goneTasks, c.TaskID)
		case c.Kind == store.ChangeMove && sq.Channel != "" && c.Channel != sq.Channel &&
			(c.HomeChan == sq.Channel || readerSees(sq, c.Channel, c.FromID, c.ToID)):
			add(goneM, &a.goneMsgs, c.MsgID)
		}
	}
	if len(a.tasks) > viewLimitMax {
		return nil, nil
	}
	return a, nil
}

// inListScope: c is a row the list sq could have shown (its channel filter
// and the reader door), so naming it as gone tells the reader nothing new.
func inListScope(sq store.TopicQuery, c store.TopicChange) bool {
	if (sq.Channel != "" && c.Channel != sq.Channel) || (sq.DM && c.Channel != "") {
		return false
	}
	return readerSees(sq, c.Channel, c.FromID, c.ToID)
}

// readerSees is the read door (rdb 0028) for one row: a public channel, a
// channel the reader is in, or a DM they are an end of.
func readerSees(sq store.TopicQuery, channel, from, to string) bool {
	if sq.Reader == "" {
		return true
	}
	if channel == "" {
		return from == sq.Reader || to == sq.Reader
	}
	if store.ChannelPublic(channel) {
		return true
	}
	for _, c := range sq.ReaderChannels {
		if c == channel {
			return true
		}
	}
	return false
}
