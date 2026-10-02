package hub

import (
	"net/http"
	"sort"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Spec 061 section 3.3.1 (FR-015): the hub keys agents on (id, box). Every
// machine numbers c-004..c-999 on its own, so c-004@box-desk and
// c-004@<sat box> are two agents. A reference that names the box picks that
// one; a bare id still works while exactly one box announces it, and is
// refused as ambiguous once two do.

// agentRef is an agent reference resolved against the roster.
type agentRef struct {
	ID, Box string
}

// refErr is a resolve refusal: the HTTP status, the error token, the detail.
type refErr struct {
	status        int
	token, detail string
}

// agentBoxes lists, sorted, the boxes (box-wui excluded) whose roster
// announces id.
func agentBoxes(roster map[string][]string, id string) []string {
	var boxes []string
	for b, agents := range roster {
		if b != WUIBox && contains(agents, id) {
			boxes = append(boxes, b)
		}
	}
	sort.Strings(boxes)
	return boxes
}

// locateAgent resolves "<id>@<box>" or a bare "<id>" to the one agent it
// names: the box must announce the id; a bare id must be announced by exactly
// one box.
func locateAgent(roster map[string][]string, ref string) (agentRef, *refErr) {
	id, box, qualified := strings.Cut(ref, "@")
	if !isAgent(id) || (qualified && !msg.ValidBoxID(box)) {
		return agentRef{}, &refErr{http.StatusBadRequest, "bad_agent", ref + " is not <agent id> or <agent id>@<box>"}
	}
	boxes := agentBoxes(roster, id)
	if qualified {
		if !contains(boxes, box) {
			return agentRef{}, &refErr{http.StatusNotFound, "unknown_agent", id + " is not announced by box " + box + " of this tenant"}
		}
		return agentRef{id, box}, nil
	}
	switch len(boxes) {
	case 0:
		return agentRef{}, &refErr{http.StatusNotFound, "unknown_agent", id + " is not announced by any box of this tenant"}
	case 1:
		return agentRef{id, boxes[0]}, nil
	}
	at := make([]string, len(boxes))
	for i, b := range boxes {
		at[i] = id + "@" + b
	}
	return agentRef{}, &refErr{http.StatusConflict, "ambiguous_agent", id + " is ambiguous: " + strings.Join(at, ", ") + "; add @<box>"}
}
