package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The shared memory of the agents (spec 102 v1.0 section 12, rdb 0146). Memory
// frames ride a one-shot role=cli session, as the lane map's do:
//
//	lane_op memory_add   {title, text}  add a lesson, or merge it into the one
//	                                    with the same normalised title
//	lane_op memory_show  {title}        one lesson, body included
//	lane_op memory_index                every lesson: title and one line, never
//	                                    the body (what a seed reads)
//
// Who may: any box pinned in the tenant (the hello proved its key); the
// writing box is recorded from the session, never from the frame.

// MemoryLesson is one lesson on the wire. Body is set by memory_add and
// memory_show only; Line by memory_index only.
type MemoryLesson struct {
	Title     string `json:"title"`
	Line      string `json:"line,omitempty"`
	Body      string `json:"body,omitempty"`
	Merges    int    `json:"merges"`
	WriterBox string `json:"writer_box,omitempty"`
	UpdatedAt string `json:"updated_at"`
}

// memoryIn is the lane payload of memory_add and memory_show.
type memoryIn struct {
	Title string `json:"title"`
	Text  string `json:"text,omitempty"`
}

func memoryLesson(l store.Lesson, body bool) MemoryLesson {
	m := MemoryLesson{Title: l.Title, Merges: l.Merges, UpdatedAt: l.UpdatedAt.UTC().Format(time.RFC3339)}
	if body {
		m.Body, m.WriterBox = l.Body, l.WriterBox
	} else {
		m.Line = store.LessonLine(l.Body)
	}
	return m
}

// isMemoryLaneOp routes a lane frame to onMemoryLane.
func isMemoryLaneOp(op string) bool { return strings.HasPrefix(op, "memory_") }

// onMemoryLane answers a memory lane frame; the reply rides the lane field of
// a lane frame, as the lane map's does.
func (s *Server) onMemoryLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxMemory(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Fleet: f.Fleet, Lane: raw}) //nolint:errcheck
}

func (s *Server) boxMemory(ctx context.Context, x *session, f wire.Frame) (any, *issueErr) {
	sm, ok := s.o.Store.(store.SharedMemory)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no shared memory"}
	}
	if f.LaneOp == "memory_index" {
		ls, err := sm.ListLessons(ctx, x.tenant)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Msg("shared memory index")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "shared memory unavailable"}
		}
		out := []MemoryLesson{}
		for _, l := range ls {
			out = append(out, memoryLesson(l, false))
		}
		return map[string]any{"lessons": out}, nil
	}
	var in memoryIn
	if err := json.Unmarshal(f.Lane, &in); err != nil {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be a {title, text} object"}
	}
	switch f.LaneOp {
	case "memory_add":
		return s.memoryAdd(ctx, x, sm, in)
	case "memory_show":
		l, found, err := sm.GetLesson(ctx, x.tenant, in.Title)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Msg("shared memory show")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "shared memory unavailable"}
		}
		if !found {
			return nil, &issueErr{http.StatusNotFound, "not_found", "no lesson with that title"}
		}
		return map[string]any{"lesson": memoryLesson(l, true)}, nil
	}
	return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be memory_add, memory_show or memory_index"}
}

func (s *Server) memoryAdd(ctx context.Context, x *session, sm store.SharedMemory, in memoryIn) (any, *issueErr) {
	if why := store.CheckLesson(in.Title, in.Text); why != "" {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	l, merged, err := sm.AddLesson(ctx, x.tenant, in.Title, in.Text, x.box, s.o.Now())
	if errors.Is(err, store.ErrLessonFull) {
		return nil, &issueErr{http.StatusConflict, "lesson_full", "the lesson would pass 16000 characters: add it under a narrower title"}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Msg("shared memory add")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "shared memory unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("lesson", l.Key).Bool("merged", merged).
		Msg("shared memory add")
	return map[string]any{"lesson": memoryLesson(l, true), "merged": merged}, nil
}
