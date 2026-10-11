package hub

import (
	"context"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The folded Flow (spec 130 sections 2 and 6, lane L1): GET
// /v1/view/flow?fold=day and the agent's flow_read frame answer the same
// lines. A line is one topic on one UTC day, or the releases of one UTC day.

// flowLineIDs is how many author ids a line names before "+N".
const flowLineIDs = 2

// wireFlowLine is one folded line on the wire (spec 130 section 2).
type wireFlowLine struct {
	Kind   string `json:"kind"`
	Day    string `json:"day"`
	Count  int    `json:"count"`
	At     string `json:"at"`
	Unread bool   `json:"unread"`
	// Link is where the line opens: /t/<task_id>#<msg_id>, or for a release
	// /releases/<sha>. Mark is the read_marks key opening it writes
	// (t:<task_id> or f:rel:<version>), at the line's newest event.
	Link string `json:"link"`
	Mark string `json:"mark"`
	// A topic line.
	TaskID       string   `json:"task_id,omitempty"`
	MsgID        string   `json:"msg_id,omitempty"`
	Channel      *string  `json:"channel,omitempty"`
	ParentTaskID string   `json:"parent_task_id,omitempty"`
	Title        string   `json:"title,omitempty"`
	Text         string   `json:"text,omitempty"`
	IDs          []string `json:"ids,omitempty"`
	IDsMore      int      `json:"ids_more,omitempty"`
	Issue        int      `json:"issue,omitempty"` // the topic's issue number; a blocked line opens it
	Hidden       bool     `json:"hidden,omitempty"`
	// A release line.
	VersionFrom string `json:"version_from,omitempty"`
	VersionTo   string `json:"version_to,omitempty"`
	Versions    int    `json:"versions,omitempty"`
	SHA         string `json:"sha,omitempty"`
}

func wireLine(l store.FlowLine) wireFlowLine {
	w := wireFlowLine{Kind: l.Kind, Day: l.Day, Count: l.Count, At: rfc(l.At), Unread: l.Unread}
	if l.Kind == store.FlowRelease {
		w.Link, w.Mark = "/releases/"+l.SHA, store.FlowReleaseMarkKey(l.VersionTo)
		w.VersionFrom, w.VersionTo, w.Versions, w.SHA = l.VersionFrom, l.VersionTo, l.Versions, l.SHA
		return w
	}
	w.Link, w.Mark = "/t/"+l.TaskID+"#"+l.MsgID, store.ThreadMarkKey(l.TaskID)
	w.TaskID, w.MsgID, w.ParentTaskID, w.Issue = l.TaskID, l.MsgID, l.ParentTaskID, l.Issue
	w.Title, w.Text = flowText(l.Title), flowText(l.Text)
	if l.Channel != "" {
		ch := l.Channel
		w.Channel = &ch
	}
	w.IDs = l.From[:min(len(l.From), flowLineIDs)]
	w.IDsMore = len(l.From) - len(w.IDs)
	return w
}

// flowFoldBody is the folded page's JSON body for member of tenant: the
// lines, the next cursor ("" = none) and the counts. A moderator's hidden
// newest line is marked; for anyone else its text is not shown.
func (s *Server) flowFoldBody(ctx context.Context, fe store.FlowFolder, q store.FlowQuery) (map[string]any, error) {
	f, err := fe.FlowFoldRead(ctx, q)
	if err != nil {
		return nil, err
	}
	mod, err := s.moderation(ctx, q.Tenant, q.Member)
	if err != nil {
		return nil, err
	}
	lines := make([]wireFlowLine, 0, len(f.Lines))
	for _, l := range f.Lines {
		w := wireLine(l)
		if l.MsgID != "" && mod.drops(l.MsgID) {
			w.Text = ""
		}
		w.Hidden = l.MsgID != "" && mod.marks(l.MsgID)
		lines = append(lines, w)
	}
	next := ""
	if f.More {
		next = encCursor(f.NextAt, f.NextID)
	}
	return map[string]any{"counts": f.Counts, "unread": f.Unread, "keys": wireFlowKeys(f.Keys), "lines": lines, "next": next}, nil
}

// writeFlowFold answers GET /v1/view/flow?fold=day.
func (s *Server) writeFlowFold(w http.ResponseWriter, r *http.Request, q store.FlowQuery, member string) {
	fe, ok := s.o.Store.(store.FlowFolder)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return
	}
	body, err := s.flowFoldBody(r.Context(), fe, q)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", q.Tenant).Msg("flow fold read")
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return
	}
	writeJSON(w, http.StatusOK, body)
}
