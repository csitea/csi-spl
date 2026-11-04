// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/channelmove"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The hub's half of a channel move (spec 169 T7, sections 8.1, 8.2):
//
//	POST /v1/operator/channel-moves {op, env, src, channel, dst, mode, to_name, move_id, go_msg_id, step, detail}
//
// The body is the seam of do_spl_channel_workspace_move, one request for each
// op: plan (reads, changes nothing, C1), journal, step and mark (channel_move_steps.go).
//
//   - Who: the env service account's Google ID token on the operator
//     allow-list (operatorAuth), as handleOperatorChannelCreate.
//   - A step or a mark also needs the owner's GO (8.1, C15), checked by
//     channelMoveGo before anything changes.
//   - Plan's refusals all go in .refuse (Stops): the shell counts .refuse,
//     .shared and .missing_desks together, so sending a stop in two of them
//     prints and counts it twice.
//   - The log line names no channel and no slug (C13): the hub-wide log may
//     not name what left <SRC>.

const channelMoveBodyMax = 64 << 10

// Refusal tokens of the endpoint.
const (
	tokenGoRequired = "go_required"
	tokenNotBuilt   = "not_built"
	// tokenMovedCheckFailed: the redirect was not read, so the post is refused
	// rather than risk a new <SRC> topic with a moved id. 503: a box retries it.
	tokenMovedCheckFailed = "moved_check_failed"
)

// channelMoveRequest is the seam's request. Env is the shell's own: the URL
// already chose the hub, so it is not read.
type channelMoveRequest struct {
	Op      string          `json:"op"`
	Env     string          `json:"env"`
	Src     string          `json:"src"`
	Channel string          `json:"channel"`
	Dst     string          `json:"dst"`
	Mode    string          `json:"mode"`
	ToName  string          `json:"to_name"`
	MoveID  *string         `json:"move_id"`
	GoMsgID *string         `json:"go_msg_id"`
	Step    *string         `json:"step"`
	Detail  json.RawMessage `json:"detail"`

	in channelMoveInputs // Detail, read for plan and step (T7d)
}

// channelMoveSeat is one row of .seats.
type channelMoveSeat struct {
	Agent string `json:"agent"`
	Box   string `json:"box"`
}

// channelMoveKept is one row of the kept list (5.6). GoneBy says what ends the
// copy; the retentions themselves are read and printed by the shell (T9b).
type channelMoveKept struct {
	Store  string `json:"store"`
	GoneBy string `json:"gone_by"`
}

// channelMoveKeptList is section 5.6, without the hours rows, which the owner
// decides per member and the plan lists as stops (5.1a).
var channelMoveKeptList = []channelMoveKept{
	{"daily DB dumps", "their retention"},
	{"off-project copy of the dumps", "its retention"},
	{"Cloud SQL automated backups", "their retention"},
	{"Qto daily export", "its retention"},
	{"box-state copy", "its retention"},
	{"hub logs", "the log bucket's retention"},
	{"mail and notifications already sent", "never"},
	{"git history", "never"},
	{"box spool archives, transcripts, worktrees", "spec 167's cleanup, if the channel also leaves its box"},
}

// channelMoveMention is one row of .mentions (5.4).
type channelMoveMention struct {
	MsgID   string `json:"msg_id,omitempty"`
	TaskID  string `json:"task_id,omitempty"`
	Channel string `json:"channel,omitempty"`
	Author  string `json:"author,omitempty"`
	DocID   string `json:"doc_id,omitempty"`
	ItemID  string `json:"item_id,omitempty"`
	Line    string `json:"line"`
}

// channelMovePlanAnswer is what the shell's _spl_cwm_plan prints.
type channelMovePlanAnswer struct {
	Counts      map[string]int       `json:"counts"`
	Seats       []channelMoveSeat    `json:"seats"`
	Mentions    []channelMoveMention `json:"mentions"`
	MembersLost []string             `json:"members_lost"`
	Kept        []channelMoveKept    `json:"kept"`
	Refuse      []string             `json:"refuse"`
	SharedFiles []string             `json:"shared_files"`
}

func (s *Server) routeChannelMove(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/channel-moves", s.handleChannelMove)
}

func (s *Server) handleChannelMove(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var q channelMoveRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, channelMoveBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {op, env, src, channel, dst, mode, to_name, move_id, go_msg_id, step, detail}")
		return
	}
	if !s.channelMoveValid(w, r, &q) || !channelMoveReadInputs(w, &q) {
		return
	}
	switch q.Op {
	case "plan":
		s.channelMovePlan(w, r, op, q)
	case "journal":
		s.channelMoveJournalAnswer(w, r, q)
	case "step", "mark":
		if !s.channelMoveGo(w, r, q) {
			return
		}
		if q.ToName != q.Channel { // never moved under the old name: T5 does not build TO_NAME
			writeErr(w, http.StatusNotImplemented, tokenNotBuilt, "TO_NAME is not built yet: a move keeps the channel's id")
			return
		}
		s.channelMoveDrive(w, r, op, q)
	default:
		writeErr(w, http.StatusBadRequest, "bad_op", "op must be plan, journal, step or mark")
	}
}

// channelMoveValid checks both workspaces and the channel; it writes the error.
// <SRC> is the tenant the Host may name; <DST> only has to exist and not be
// suspended. A default channel is every member's: it never leaves.
func (s *Server) channelMoveValid(w http.ResponseWriter, r *http.Request, q *channelMoveRequest) bool {
	q.Channel = store.NormalizeChannel(strings.TrimSpace(q.Channel))
	q.Dst = strings.ToLower(strings.TrimSpace(q.Dst))
	if q.ToName = strings.TrimSpace(q.ToName); q.ToName == "" {
		q.ToName = q.Channel
	}
	src, ok := s.operatorChannelTenant(w, r, q.Src)
	if !ok {
		return false
	}
	q.Src = src.ID
	switch {
	case !msg.ValidTenantID(q.Dst) || q.Dst == q.Src:
		writeErr(w, http.StatusBadRequest, "bad_tenant", "dst must be another workspace's slug")
	case !store.ValidChannelID(q.Channel) || !store.ValidChannelID(q.ToName):
		writeErr(w, http.StatusBadRequest, "bad_channel", "channel and to_name must match ^[a-z0-9][a-z0-9-]{0,63}$")
	case store.ChannelPublic(q.Channel):
		writeErr(w, http.StatusBadRequest, "bad_channel", "a default channel never moves")
	case q.Mode == "copy":
		writeErr(w, http.StatusNotImplemented, tokenNotBuilt, "copy mode (spec 169 T11) is not built yet")
	case q.Mode != "" && q.Mode != "move":
		writeErr(w, http.StatusBadRequest, "bad_mode", "mode must be move or copy")
	default:
		_, ok = s.loadTenant(w, r, q.Dst)
		return ok
	}
	return false
}

// channelMoveTables is the catalogue as the store takes it (the store cannot
// import channelmove: channelmove's own tests import the store).
func channelMoveTables() []store.MoveTable {
	out := make([]store.MoveTable, len(channelmove.Catalogue))
	for i, e := range channelmove.Catalogue {
		out[i] = store.MoveTable{Table: e.Table, Class: string(e.Class), Set: e.Set, Refs: e.Refs}
	}
	return out
}

// channelMovePlanRequest carries the owner's keep list and the box rule's doc
// (T7d): the set, the leaving list and the Q5 stops depend on them.
func channelMovePlanRequest(q channelMoveRequest) store.ChannelMovePlanRequest {
	return store.ChannelMovePlanRequest{Src: q.Src, Channel: q.Channel, Dst: q.Dst, RuleDoc: q.in.RuleDoc, Keep: q.in.Keep,
		Tables: channelMoveTables(), BindTypes: channelmove.Binds}
}

func (s *Server) channelMovePlan(w http.ResponseWriter, r *http.Request, op string, q channelMoveRequest) {
	pl, ok := s.o.Store.(store.ChannelMovePlanner)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store cannot plan a channel move")
		return
	}
	plan, err := pl.PlanChannelMove(r.Context(), channelMovePlanRequest(q))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+q.Channel+" in "+q.Src)
		return
	case errors.Is(err, store.ErrMoveRequest):
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("operator.channel_move_plan")
		writeErr(w, http.StatusInternalServerError, "internal", "plan unavailable")
		return
	}
	refuse, ok := s.channelMoveRefusals(w, r, q, plan)
	if !ok {
		return
	}
	s.o.Log.Info().Str("operator", op).Msg("operator.channel_move_plan")
	writeJSON(w, http.StatusOK, channelMovePlanOf(plan, refuse))
}

// channelMoveRefusals are plan's stops plus P2's name check: the channel's id
// must be free in <DST> (else TO_NAME). Archived rows reserve a name there too.
func (s *Server) channelMoveRefusals(w http.ResponseWriter, r *http.Request, q channelMoveRequest, plan store.ChannelMovePlan) ([]string, bool) {
	refuse := append([]string{}, channelMoveStops(plan, q.in)...)
	taken, err := s.channelMoveNameTaken(r.Context(), q.Dst, q.ToName)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return nil, false
	}
	if taken {
		refuse = append(refuse, channelMoveTakenLine(q))
	}
	return refuse, true
}

func channelMoveTakenLine(q channelMoveRequest) string {
	return "channel " + q.ToName + " exists in " + q.Dst + ": set TO_NAME"
}

// channelMoveNameTaken: a live or an archived row holds the name in dst.
func (s *Server) channelMoveNameTaken(ctx context.Context, dst, name string) (bool, error) {
	_, err := s.o.Store.Channel(ctx, dst, name)
	switch {
	case err == nil:
		return true, nil
	case !errors.Is(err, store.ErrNotFound):
		return false, err
	}
	_, found, err := s.o.Store.ArchivedChannel(ctx, dst, name)
	return found, err
}

// channelMovePlanOf shapes the plan for the shell. Every list is [], never
// null. Seats is every seat (T4d), with a desk or without one: those without
// also come through Stops, and only Stops counts as a refusal.
func channelMovePlanOf(p store.ChannelMovePlan, refuse []string) channelMovePlanAnswer {
	a := channelMovePlanAnswer{Counts: map[string]int{}, Seats: []channelMoveSeat{},
		Mentions: make([]channelMoveMention, 0, len(p.Mentions)), MembersLost: []string{},
		Kept: channelMoveKeptList, Refuse: refuse, SharedFiles: []string{}}
	for _, seat := range p.Seats {
		a.Seats = append(a.Seats, channelMoveSeat{Agent: seat.Agent, Box: seat.Box})
	}
	for _, c := range p.Counts {
		a.Counts[c.Table] = c.Set
		if c.Refs > 0 {
			a.Counts[c.Table+" refs"] = c.Refs
		}
	}
	for _, m := range p.Mentions {
		a.Mentions = append(a.Mentions, channelMoveMention{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel,
			Author: m.Author, DocID: m.DocID, ItemID: m.ItemID, Line: m.Line})
	}
	a.MembersLost = append(a.MembersLost, p.Leaving...)
	a.SharedFiles = append(a.SharedFiles, p.SharedFiles...)
	return a
}

// pollFormLine and pollGoLine are the marker of an answered poll form
// (how-to-post section 7): "Poll: <form msg id>", then "Answer: GO — Go".
// "Chat: wants to discuss" has a Poll line and no Answer line: no GO.
var (
	pollFormLine = regexp.MustCompile(`(?m)^Poll: ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*$`)
	pollGoLine   = regexp.MustCompile(`(?m)^Answer: GO(\s|$)`)
)

// channelMoveGo is the owner's GO (8.1, C15): go_msg_id is a message of the
// operator workspace, written by that workspace's biz owner, answering a
// poll form with GO, and the form names this channel and this target, so a GO
// for another move does not open this one. It writes the refusal. Not checked:
// whether the owner answered again later (re-answering replaces, how-to-post 7).
func (s *Server) channelMoveGo(w http.ResponseWriter, r *http.Request, q channelMoveRequest) bool {
	why := s.channelMoveGoRefusal(r.Context(), q)
	if why == "" {
		return true
	}
	writeErr(w, http.StatusForbidden, tokenGoRequired, why)
	return false
}

// channelMoveGoRefusal says why q's GO does not stand; "" = it does.
func (s *Server) channelMoveGoRefusal(ctx context.Context, q channelMoveRequest) string {
	if q.GoMsgID == nil || !msg.IsUUID(*q.GoMsgID) {
		return "a step of a channel move needs go_msg_id, the msg id of the owner's (GO) poll answer"
	}
	op, err := s.operatorTenant(ctx)
	if err != nil || op == "" {
		return "the operator workspace was not read, so the GO cannot be checked"
	}
	ans, err := s.o.Store.GetMessageClaim(ctx, op, *q.GoMsgID)
	if err != nil {
		return "no message " + *q.GoMsgID + " in the operator workspace"
	}
	if s.channelMoveCopied(ctx, op, *q.GoMsgID) {
		return "message " + *q.GoMsgID + " is a copy or was not read, so it is not the owner's GO"
	}
	if !s.channelMoveOwner(ctx, op, ans.FromID) {
		return "the GO must come from the owner of the operator workspace, not " + ans.FromID
	}
	body := channelMoveBody(ans)
	form := pollFormLine.FindStringSubmatch(body)
	if form == nil || !pollGoLine.MatchString(body) {
		return "message " + *q.GoMsgID + " is not a (GO) poll answer"
	}
	fm, err := s.o.Store.GetMessageClaim(ctx, op, form[1])
	if err != nil || fm.TaskID != ans.TaskID {
		return "the poll form " + form[1] + " is not in the answer's topic"
	}
	if s.channelMoveCopied(ctx, op, form[1]) {
		return "the poll form " + form[1] + " is a copy or was not read"
	}
	if !channelMoveNames(channelMoveBody(fm), q.Src+"/"+q.Channel) || !channelMoveNames(channelMoveBody(fm), q.Dst) {
		return "the poll form " + form[1] + " does not name " + q.Src + "/" + q.Channel + " and " + q.Dst
	}
	return ""
}

// channelMoveCopied says a row may not stand as a GO: it is a copy (rdb 0250), or
// that was not read. A copied post has a human author and box-wui, the shape of a
// member's own post, and only this column tells them apart.
func (s *Server) channelMoveCopied(ctx context.Context, tenant, msgID string) bool {
	mr, ok := s.o.Store.(store.ChannelMoveRedirects)
	if !ok {
		return true
	}
	copied, err := mr.MessageCopied(ctx, tenant, msgID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", msgID).Msg("copied check")
	}
	return copied || err != nil
}

// channelMoveOwner reports the biz owner of the operator workspace.
func (s *Server) channelMoveOwner(ctx context.Context, op, from string) bool {
	h, ok := s.o.Store.(store.Humans)
	if !ok || !humanIDRe.MatchString(from) {
		return false
	}
	role, err := h.MemberRole(ctx, from, op)
	return err == nil && role == rbac.BizOwner
}

// channelMoveBody is a stored message's text, from its signed inner message.
func channelMoveBody(m store.Message) string {
	var inner struct {
		Body string `json:"body"`
	}
	if err := json.Unmarshal(m.Msg, &inner); err != nil {
		return ""
	}
	return inner.Body
}

// channelMoveNames finds word in text as a whole slug: csitea/foo is not named
// by a text about csitea/foo-bar.
func channelMoveNames(text, word string) bool {
	return regexp.MustCompile(`(^|[^a-z0-9-])` + regexp.QuoteMeta(word) + `($|[^a-z0-9-])`).MatchString(text)
}

// The moved-task refusal (W3, W5, C8). A move keeps every task uuid, and a task
// that left has no <SRC> row, so only a post that would open a new topic reads
// channel_move_redirects: boxTopic and wuiChannel know the rest. A live row
// refuses with the destination, an expired one with 404; neither stores a row and
// neither names the channel (C13). The hub cannot carry the post on itself: a box
// key is live in one workspace only (rdb 0154), and a <DST> receiver verifies
// against its own pins, so the re-route of Q2 is the box client's (T7b).

// topicLink is the permalink of a moved task (W5).
func (s *Server) topicLink(r *store.ChannelMoveRedirect) string {
	return GcalWorkspaceURL(s.o.TenantHostPattern, s.o.WUIApexTenant, "")(r.Dst) + "/t/" + r.NewRef
}

// movedGone is the bare answer about a moved task: no destination.
const movedGone = "this topic is gone from this workspace"

// movedRefusal is the refusal of a post to a moved task; named = the sender may
// learn the destination (a box post, T7b's re-route; a browser post: dstMember).
func (s *Server) movedRefusal(red *store.ChannelMoveRedirect, named bool) *frameRefusal {
	if !named || !red.Live(s.o.Now()) {
		return &frameRefusal{wire.TokenTopicMoved, http.StatusNotFound, movedGone}
	}
	return &frameRefusal{wire.TokenTopicMoved, http.StatusConflict, wire.MovedDetail(red.Dst, s.topicLink(red))}
}

// dstMember reports whether the human hum may be named a move's destination:
// only a <DST> member (W1, Q5). <DST> may be a hidden workspace (11.1), so a
// <SRC> member the move dropped, a reader with no HUM-* and a failed read get
// the bare answer.
func (s *Server) dstMember(ctx context.Context, red *store.ChannelMoveRedirect, hum string) bool {
	h, ok := s.o.Store.(store.Humans)
	if !ok || hum == "" {
		return false
	}
	_, err := h.MemberRole(ctx, hum, red.Dst)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.o.Log.Error().Err(err).Msg("moved destination member check")
	}
	return err == nil
}

// movedCheckFailed is the refusal of a post whose redirect was not read.
func movedCheckFailed() *frameRefusal {
	return &frameRefusal{tokenMovedCheckFailed, http.StatusServiceUnavailable, "the topic could not be checked; try again"}
}

// taskFirstOrMoved is TaskFirstChannel plus the redirect, in the one read.
func (s *Server) taskFirstOrMoved(ctx context.Context, tenant, taskID string) (string, *store.ChannelMoveRedirect, error) {
	mr, ok := s.o.Store.(store.ChannelMoveRedirects)
	if !ok {
		first, err := s.o.Store.TaskFirstChannel(ctx, tenant, taskID)
		return first, nil, err
	}
	st, err := mr.TaskMoveState(ctx, tenant, taskID)
	return st.FirstChannel, st.Moved(), err
}

// browserMovedRefusal: a browser post by member hum with no root found
// (wuiChannel). The lobby task is the hub's own, and a non-uuid id is no task
// (rdb 0249).
func (s *Server) browserMovedRefusal(ctx context.Context, tenant, taskID, hum string) *frameRefusal {
	if !msg.IsUUID(taskID) || (s.o.LobbyTaskID != "" && taskID == s.o.LobbyTaskID) {
		return nil
	}
	_, red, err := s.taskFirstOrMoved(ctx, tenant, taskID)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", taskID).Msg("moved check")
		return movedCheckFailed()
	case red != nil:
		return s.movedRefusal(red, s.dstMember(ctx, red, hum))
	}
	return nil
}

// sendMoved is onSend's check: the level to store the post at, or a refusal.
func (s *Server) sendMoved(ctx context.Context, tenant, taskID string) (int, *frameRefusal) {
	t := s.boxTopic(ctx, tenant, taskID)
	switch {
	case t.err != nil:
		return t.level, movedCheckFailed()
	case t.moved != nil:
		return t.level, s.movedRefusal(t.moved, true)
	}
	return t.level, nil
}

// topicMovedAnswer is hum's read of a task with no rows, about to answer 404:
// true has answered a moved one (W5), naming the destination to a <DST> member
// only (dstMember). Only an empty first page costs this read.
func (s *Server) topicMovedAnswer(w http.ResponseWriter, r *http.Request, tenant, task, hum string) bool {
	_, red, err := s.taskFirstOrMoved(r.Context(), tenant, task)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("moved check")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return true
	case red == nil:
		return false
	case !red.Live(s.o.Now()) || !s.dstMember(r.Context(), red, hum):
		writeErr(w, http.StatusNotFound, wire.TokenTopicMoved, movedGone)
		return true
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"error": wire.TokenTopicMoved, "detail": wire.MovedDetail(red.Dst, s.topicLink(red)),
		"moved_to": s.topicLink(red), "moved_to_tenant": red.Dst})
	return true
}
