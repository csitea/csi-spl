package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The hardware history of the fleet's boxes (rdb 0117, owner t1 8c4fcc46):
// one load + memory sample per box per lane-map tick (300 s).
//
// Box side, over the authenticated hello on a one-shot role=cli session (the
// `spool lane` path; the writing box comes from the session, never the frame):
//
//	lane_op box_stats_put   append one sample {box, load1, load5, load15, cpus,
//	                        mem_total_kb, mem_avail_kb, swap_used_kb, agents_live}
//	lane_op box_stats_list  {box?, since?} -> {since, rows, hours}
//
// Browser side (the chart lane), audit.read (the operators: biz_owner,
// product_owner, admin; not a biz_customer):
//
//	GET /v1/tenant/box-stats?box=<box>&since=<RFC 3339 | 20h | 7d>
//
// hours is one row per (box, UTC hour): load1 and used memory as avg and
// peak. at is the hub's clock; a box's own clock is never trusted.

const boxStatsSinceDefault = 24 * time.Hour

func (s *Server) routeBoxStats(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/box-stats", s.handleBoxStats)
	mux.HandleFunc("OPTIONS /v1/tenant/box-stats", s.preflight)
}

// sweepBoxStats is the 30-day retention, on the hub's retention sweep.
func (s *Server) sweepBoxStats(ctx context.Context) {
	bs, ok := s.o.Store.(store.BoxStats)
	if !ok {
		return
	}
	n, err := bs.PruneBoxStats(ctx, s.o.Now().Add(-store.BoxStatsRetention))
	if err != nil {
		s.o.Log.Error().Err(err).Msg("box_stats retention sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("pruned", n).Msg("box_stats retention sweep")
	}
}

// boxStatsBody is the read answer, on HTTP and on the box frame.
type boxStatsBody struct {
	Box   string              `json:"box,omitempty"`
	Since string              `json:"since"`
	Rows  []store.BoxStat     `json:"rows"`
	Hours []store.BoxStatHour `json:"hours"`
}

// boxStatsSince reads since: an RFC 3339 instant, a Go duration back from now
// (20h, 90m) or whole days (7d); "" = 24 h. Never before the retention.
func boxStatsSince(v string, now time.Time) (time.Time, bool) {
	since := now.Add(-boxStatsSinceDefault)
	if v != "" {
		if at, err := time.Parse(time.RFC3339, v); err == nil {
			since = at
		} else if d, err := time.ParseDuration(v); err == nil && d > 0 {
			since = now.Add(-d)
		} else if n, err := strconv.Atoi(strings.TrimSuffix(v, "d")); err == nil && strings.HasSuffix(v, "d") && n > 0 && n <= 366 {
			since = now.Add(-time.Duration(n) * 24 * time.Hour)
		} else {
			return since, false
		}
	}
	if floor := now.Add(-store.BoxStatsRetention); since.Before(floor) {
		since = floor
	}
	return since, true
}

func (s *Server) readBoxStats(ctx context.Context, bs store.BoxStats, tenant, box, sinceArg string) (boxStatsBody, *issueErr) {
	if box != "" && !store.FleetNameRe.MatchString(box) {
		return boxStatsBody{}, &issueErr{http.StatusBadRequest, "bad_query", "box must be a box id ([a-z0-9-], up to 32)"}
	}
	since, ok := boxStatsSince(sinceArg, s.o.Now())
	if !ok {
		return boxStatsBody{}, &issueErr{http.StatusBadRequest, "bad_query", "since is an RFC 3339 time, a duration back from now (20h) or days (7d)"}
	}
	rows, err := bs.ListBoxStats(ctx, tenant, box, since)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("box stats list")
		return boxStatsBody{}, &issueErr{http.StatusInternalServerError, "internal", "box stats unavailable"}
	}
	return boxStatsBody{Box: box, Since: since.UTC().Format(time.RFC3339), Rows: rows, Hours: store.BoxStatHours(rows)}, nil
}

// GET /v1/tenant/box-stats?box=&since=
func (s *Server) handleBoxStats(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.AuditRead)
	if !ok {
		return
	}
	bs, ok := s.o.Store.(store.BoxStats)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no box stats")
		return
	}
	q := r.URL.Query()
	out, ae := s.readBoxStats(r.Context(), bs, t.ID, q.Get("box"), q.Get("since"))
	if ae != nil {
		writeErr(w, ae.status, ae.token, ae.detail)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// isBoxStatsLaneOp routes a lane frame to onBoxStatsLane.
func isBoxStatsLaneOp(op string) bool { return strings.HasPrefix(op, "box_stats_") }

// onBoxStatsLane answers a box_stats lane frame; the reply rides the lane
// field of a lane frame, as the lane map's does.
func (s *Server) onBoxStatsLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxStatsFrame(ctx, x, f)
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

func (s *Server) boxStatsFrame(ctx context.Context, x *session, f wire.Frame) (any, *issueErr) {
	bs, ok := s.o.Store.(store.BoxStats)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no box stats"}
	}
	switch f.LaneOp {
	case "box_stats_put":
		var b store.BoxStat
		dec := json.NewDecoder(bytes.NewReader(f.Lane))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&b); err != nil {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be one box stat object"}
		}
		b.At, b.WriterBox = s.o.Now(), x.box
		if why := store.CheckBoxStat(b); why != "" {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", why}
		}
		if err := bs.AppendBoxStat(ctx, x.tenant, b); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box stat append")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "box stat not stored"}
		}
		return map[string]any{"ok": true, "box": b.Box, "at": b.At.UTC().Format(time.RFC3339), "writer_box": b.WriterBox}, nil
	case "box_stats_list":
		var q struct {
			Box   string `json:"box"`
			Since string `json:"since"`
		}
		if len(f.Lane) > 0 {
			if err := json.Unmarshal(f.Lane, &q); err != nil {
				return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be {box, since}"}
			}
		}
		out, ae := s.readBoxStats(ctx, bs, x.tenant, q.Box, q.Since)
		if ae != nil {
			ae.token = "bad_frame"
			if ae.status != http.StatusBadRequest {
				ae.token = "internal"
			}
			return nil, ae
		}
		return out, nil
	}
	return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be box_stats_put or box_stats_list"}
}
