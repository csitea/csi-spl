package hub

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4018: `spool ask list --all` on prd answered 1644 asks, ~1.56 MB in
// one frame, past the CLI's 1 MiB read limit (hubclient maxFrameBytes): the
// client closed the socket and every ask-book read fell back to the local
// journal. A list with page set answers at most askPageBytes of rows and
// names the next page; the CLI reads every page (action.Ask).

// askPageBytes bounds one page's rows, far below the CLI's 1 MiB frame limit.
const askPageBytes = 256 << 10

// askCursorRe is a page cursor: the sort key of the last row sent, in the
// order the store sorts a list (open first, then created_at, then ask_id).
var askCursorRe = regexp.MustCompile(`^([01])\.(-?[0-9]{1,20})\.([0-9a-f-]{36})$`)

type askKey struct {
	closed  int
	created int64
	id      string
}

func askKeyOf(a store.FleetAsk) askKey {
	k := askKey{created: a.CreatedAt.UnixNano(), id: a.AskID}
	if !a.Open() {
		k.closed = 1
	}
	return k
}

func (k askKey) String() string { return fmt.Sprintf("%d.%d.%s", k.closed, k.created, k.id) }

func (k askKey) after(c askKey) bool {
	if k.closed != c.closed {
		return k.closed > c.closed
	}
	if k.created != c.created {
		return k.created > c.created
	}
	return k.id > c.id
}

func parseAskCursor(s string) (askKey, bool) {
	m := askCursorRe.FindStringSubmatch(s)
	if m == nil {
		return askKey{}, false
	}
	n, err := strconv.ParseInt(m[2], 10, 64)
	if err != nil {
		return askKey{}, false
	}
	c := askKey{created: n, id: m[3]}
	if m[1] == "1" {
		c.closed = 1
	}
	return c, true
}

// askPage answers the rows of as (store order) after the cursor, up to
// askPageBytes, and the cursor of the next page ("" when none is left). A
// row that closes between two pages moves past the cursor and comes again
// (the CLI keeps its last copy); every row is answered at least once.
func askPage(as []store.FleetAsk, after string) ([]AskRow, string, *issueErr) {
	var cur askKey
	if after != "" {
		var ok bool
		if cur, ok = parseAskCursor(after); !ok {
			return nil, "", &issueErr{http.StatusBadRequest, "bad_frame", "after must be the next of a list page"}
		}
	}
	out, size, last := []AskRow{}, 0, askKey{}
	for _, a := range as {
		k := askKeyOf(a)
		if after != "" && !k.after(cur) {
			continue
		}
		r := askRow(a)
		raw, err := json.Marshal(r)
		if err != nil {
			return nil, "", &issueErr{http.StatusInternalServerError, "internal", "reply does not encode"}
		}
		if len(out) > 0 && size+len(raw) > askPageBytes {
			return out, last.String(), nil
		}
		out, size, last = append(out, r), size+len(raw)+1, k
	}
	return out, "", nil
}
