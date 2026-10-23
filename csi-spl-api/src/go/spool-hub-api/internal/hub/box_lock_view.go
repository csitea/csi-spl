package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The box owner lock at the view and admin points (spec 025
// box-owner-lock.md section 5.1 paths 4, 4b, 5, 5b, 6, 8, 8b, 8c, 8d, 10b,
// 11; row B5, SPL-2991). B3's box_lock.go keeps a locked box's agents from
// being REACHED by a non-owner; this file keeps them from being SEEN or
// CHANGED by one.
//
// One predicate, hiddenByLock(from_box, to_box) of a lockView, decides every
// read: a message is hidden from a reader when either end is a box locked to
// someone else (OQ-1). A topic is hidden when any of its messages is (its
// TopicAccess.Boxes, its list row's parties), except the lobby feed, which
// every member shares: there only the messages go. Hidden reads answer as
// "not there" (404, or a row left out), never 403, as the read door does.
// A lock that does not verify (tampered) has no owner, so it hides from
// everyone.
//
// Writes that name a locked box or one of its agents answer 403 box_locked
// to a non-owner and write one refused audit row (adminLockRefusal), whatever
// the caller's role, root key or operator scope. A hidden read writes no
// audit row: like fallbackLockSkip it refuses nothing the reader asked to
// change, and a list read would write one row per hidden topic.
//
// Fail closed: a lock read error answers 500 on a read and 503 on a write.
//
// The live fan-out (wants) runs under the hub mutex and cannot read the
// store, so it reads lockSnaps: the locks last read for the workspace, kept
// fresh by every lockView load (each view read, each subscribe, each stored
// message's fan-out). hide_posts=false is not honoured yet: every lock hides.

// Audit paths of the view and admin points (box_lock_audit.path).
const (
	boxLockPathPin         = "pin"
	boxLockPathRevoke      = "revoke"
	boxLockPathJoin        = "join_token"
	boxLockPathSeatRevoke  = "seat_revoke"
	boxLockPathSenderAllow = "sender_allow"
	boxLockPathAIAgents    = "channel_ai_agents"
	boxLockPathAgentSplit  = "agent_split"
	boxLockPathLifecycle   = "agent_lifecycle"
	boxLockPathOperator    = "operator_workspace"
	boxLockPathIssueAssign = "issue_assign"
)

// lockView is one reader's view of the workspace's box locks: locks holds
// every locked box the reader does NOT own (a tampered lock included).
type lockView struct {
	locks map[string]*store.BoxLock
}

// any reports whether something is hidden from this reader at all; false
// lets a read skip every per-row check.
func (v lockView) any() bool { return len(v.locks) > 0 }

// hides reports whether box is locked to someone else.
func (v lockView) hides(box string) bool {
	_, ok := v.locks[box]
	return ok
}

// hiddenByLock is the one predicate of section 5.2: a message whose from_box
// or to_box is locked to someone else.
func (v lockView) hiddenByLock(fromBox, toBox string) bool {
	return v.hides(fromBox) || v.hides(toBox)
}

// hidesSeat reports whether a seat "<agent>@<box>" (or a bare box) sits on
// a hidden box.
func (v lockView) hidesSeat(seat string) bool {
	if i := strings.LastIndexByte(seat, '@'); i >= 0 {
		seat = seat[i+1:]
	}
	return v.hides(seat)
}

// hidesAny reports whether any box in boxes is hidden.
func (v lockView) hidesAny(boxes []string) bool {
	for _, b := range boxes {
		if v.hides(b) {
			return true
		}
	}
	return false
}

// tenantLocks reads every lock of the workspace (LockedBoxes, then each
// verified BoxLock; both cached by Postgres) and records them for the live
// fan-out. nil = no lock, or a store without locks. An error means refuse.
func (s *Server) tenantLocks(ctx context.Context, tenant string) (map[string]*store.BoxLock, error) {
	lister, ok := s.o.Store.(store.LockedBoxLister)
	if !ok || tenant == "" {
		s.locks.put(tenant, nil) // no lock store: known to hold no lock
		return nil, nil
	}
	ids, err := lister.LockedBoxes(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("box locks list")
		s.locks.forget(tenant)
		return nil, err
	}
	var out map[string]*store.BoxLock
	for _, id := range ids {
		l, err := s.boxLock(ctx, tenant, id)
		if err != nil {
			s.locks.forget(tenant)
			return nil, err
		}
		if l != nil {
			if out == nil {
				out = map[string]*store.BoxLock{}
			}
			out[id] = l
		}
	}
	s.locks.put(tenant, out)
	return out, nil
}

// lockViewFor is hum's lockView of tenant. hum "" (the door-off rig) owns
// nothing, so every locked box is hidden from it.
func (s *Server) lockViewFor(ctx context.Context, tenant, hum string) (lockView, error) {
	all, err := s.tenantLocks(ctx, tenant)
	if err != nil || len(all) == 0 {
		return lockView{}, err
	}
	v := lockView{locks: map[string]*store.BoxLock{}}
	for b, l := range all {
		if !l.IsOwner(hum) {
			v.locks[b] = l
		}
	}
	return v, nil
}

// topicLockHidden is the lock half of canReadTopic (path 4): a topic that
// touches a box locked to someone else reads as absent, except the lobby,
// whose hidden messages the page leaves out one by one.
func (s *Server) topicLockHidden(ctx context.Context, tenant, task string, a store.TopicAccess, hum string) (bool, error) {
	if !a.Found || len(a.Boxes) == 0 || (task != "" && task == s.o.LobbyTaskID) {
		return false, nil
	}
	v, err := s.lockViewFor(ctx, tenant, hum)
	if err != nil {
		return true, err
	}
	return v.hidesAny(a.Boxes), nil
}

// fileLockHidden is path 6: while a lock hides something from hum, a file
// is readable only through a carrying message that hum may read (the 0028
// rule) and that no lock hides. A file carried only by hidden messages reads
// as absent (404).
func (s *Server) fileLockHidden(ctx context.Context, tenant, fileID, hum string) (bool, error) {
	v, err := s.lockViewFor(ctx, tenant, hum)
	if err != nil || !v.any() {
		return err != nil, err
	}
	fd, ok := s.o.Store.(store.FileDetacher)
	if !ok {
		return true, nil // no carrier list: fail closed
	}
	now := s.o.Now()
	ids, err := fd.FileCarriers(ctx, tenant, fileID, now)
	if err != nil {
		return true, err
	}
	for _, id := range ids {
		m, err := s.o.Store.GetEditable(ctx, tenant, id, now)
		if errors.Is(err, store.ErrNotFound) {
			continue
		}
		if err != nil {
			return true, err
		}
		if v.hiddenByLock(m.FromBox, m.ToBox) {
			continue
		}
		switch may, err := s.canReadMessage(ctx, tenant, m, hum); {
		case err != nil:
			return true, err
		case may:
			return false, nil
		}
	}
	return true, nil
}

// lockKeepResults is one search section without what a lock hides from hum:
// a message or file hit from or to a hidden box, a box or robot on one, and
// any hit in a topic that touches one (its TopicAccess, as canReadTopic asks
// it; once per topic), so no file or line hit outlives its 404 topic.
func (s *Server) lockKeepResults(ctx context.Context, tenant, hum string, v lockView, rs []any) ([]any, error) {
	if !v.any() {
		return rs, nil
	}
	topics := map[string]bool{}
	kept := rs[:0]
	for _, r := range rs {
		m, _ := r.(map[string]any)
		hidden := false
		for _, k := range []string{"from_box", "to_box", "box_id", "box"} {
			if b, _ := m[k].(string); v.hides(b) {
				hidden = true
			}
		}
		if task, _ := m["task_id"].(string); !hidden && task != "" {
			h, seen := topics[task]
			if !seen {
				a, err := s.o.Store.TopicAccess(ctx, tenant, task, s.o.Now())
				if err != nil {
					return nil, err
				}
				if h, err = s.topicLockHidden(ctx, tenant, task, a, hum); err != nil {
					return nil, err
				}
				topics[task] = h
			}
			hidden = h
		}
		if !hidden {
			kept = append(kept, r)
		}
	}
	return kept, nil
}

// lockKeepLifecycle is evs without the events of an agent on, or written
// by, a box locked to hum's exclusion (path 5b).
func (s *Server) lockKeepLifecycle(ctx context.Context, tenant, hum string, evs []store.LifecycleEvent) ([]store.LifecycleEvent, error) {
	v, err := s.lockViewFor(ctx, tenant, hum)
	if err != nil || !v.any() {
		return evs, err
	}
	kept := evs[:0]
	for _, e := range evs {
		if !v.hides(e.AgentBox) && !v.hides(e.WriterBox) {
			kept = append(kept, e)
		}
	}
	return kept, nil
}

// tokenMember is the member session an upload token was minted for ("" =
// a box's token, or no token).
func (s *Server) tokenMember(r *http.Request) string {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return ""
	}
	t, reason := s.uploadTokenOf(tok)
	if reason != "" {
		return ""
	}
	return t.member
}

// lockKeepPins is path 8b: a locked box's pin is listed only to the box
// itself, a peer box of its lock, or a browser token of one of its owners.
func (s *Server) lockKeepPins(ctx context.Context, tenant, box, hum string, pins []store.Pin) ([]store.Pin, error) {
	all, err := s.tenantLocks(ctx, tenant)
	if err != nil || len(all) == 0 {
		return pins, err
	}
	kept := pins[:0:0]
	for _, p := range pins {
		l, locked := all[p.BoxID]
		if !locked || (box != "" && box != WUIBox && lockAdmitsBox(l, box)) || (box == WUIBox && l.IsOwner(hum)) {
			kept = append(kept, p)
		}
	}
	return kept, nil
}

// envBoxes are a stored envelope's two ends; ok=false: it does not parse,
// which a lock view treats as hidden (fail closed).
func envBoxes(env []byte) (from, to string, ok bool) {
	var e struct {
		FromBox string `json:"from_box"`
		ToBox   string `json:"to_box"`
	}
	if json.Unmarshal(env, &e) != nil {
		return "", "", false
	}
	return e.FromBox, e.ToBox, true
}

// keepMsgs is rows without the messages hidden from this reader.
func (v lockView) keepMsgs(rows []store.ViewMsg) []store.ViewMsg {
	if !v.any() {
		return rows
	}
	kept := rows[:0:0]
	for _, m := range rows {
		if from, to, ok := envBoxes(m.Env); ok && !v.hiddenByLock(from, to) {
			kept = append(kept, m)
		}
	}
	return kept
}

// keepTopics is out without the topics that touch a hidden box (their
// participants are "<agent>@<box>"), the lobby excepted.
func (v lockView) keepTopics(out []viewTopic, lobby string) []viewTopic {
	if !v.any() {
		return out
	}
	kept := out[:0]
	for _, t := range out {
		hidden := false
		for _, p := range t.Participants {
			if v.hidesSeat(p) {
				hidden = true
				break
			}
		}
		if !hidden || (lobby != "" && t.TaskID == lobby) {
			kept = append(kept, t)
		}
	}
	return kept
}

// adminLockRefusal is the write points' check (paths 5b, 8, 8c, 8d, 10b,
// 11): nil when box is not locked or hum owns its lock; else one refused
// audit row and 403 box_locked. A read error refuses with 503.
func (s *Server) adminLockRefusal(ctx context.Context, tenant, box, hum, path string) *frameRefusal {
	if box == "" {
		return nil
	}
	return s.boxLockRefusal(ctx, tenant, box, hum, path)
}

// seatLockRefusal is adminLockRefusal for a seat "<agent>@<box>"; a bare
// agent id is looked up on the roster, and refused when ANY box announcing
// it is locked to someone else (an ambiguous id names the locked one too).
func (s *Server) seatLockRefusal(ctx context.Context, tenant, seat, hum, path string) *frameRefusal {
	if _, box, ok := strings.Cut(seat, "@"); ok {
		return s.adminLockRefusal(ctx, tenant, box, hum, path)
	}
	all, err := s.tenantLocks(ctx, tenant)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	if len(all) == 0 || seat == "" {
		return nil
	}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	for box, agents := range roster {
		if _, locked := all[box]; !locked {
			continue
		}
		for _, a := range agents {
			if a == seat {
				if rf := s.adminLockRefusal(ctx, tenant, box, hum, path); rf != nil {
					return rf
				}
			}
		}
	}
	return nil
}

// channelLockRefusal is adminLockRefusal for a channel-wide switch: refused
// when an agent of the channel sits on a box locked to someone else.
func (s *Server) channelLockRefusal(ctx context.Context, tenant, channel, hum, path string) *frameRefusal {
	all, err := s.tenantLocks(ctx, tenant)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	if len(all) == 0 {
		return nil
	}
	members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	for box, agents := range members {
		if _, locked := all[box]; locked && len(agents) > 0 {
			if rf := s.adminLockRefusal(ctx, tenant, box, hum, path); rf != nil {
				return rf
			}
		}
	}
	return nil
}

// opHum is the operator admin's HUM-* ("" for the operator service account,
// which owns no lock).
func opHum(a *opActor) string {
	if a == nil {
		return ""
	}
	return a.hum
}

// lockKeepFleetLoad is path 10b's read: the operator workspace's fleet load
// without the bands and order places of a box locked to someone else.
func (s *Server) lockKeepFleetLoad(ctx context.Context, tenant, hum string, f store.FleetLoadStored) (store.FleetLoadStored, error) {
	v, err := s.lockViewFor(ctx, tenant, hum)
	if err != nil || !v.any() {
		return f, err
	}
	if f.Boxes != nil {
		kept := make(map[string]store.BoxBand, len(f.Boxes))
		for b, band := range f.Boxes {
			if !v.hides(b) {
				kept[b] = band
			}
		}
		f.Boxes = kept
	}
	if f.BoxOrder != nil {
		kept := make([]string, 0, len(f.BoxOrder))
		for _, b := range f.BoxOrder {
			if !v.hides(b) {
				kept = append(kept, b)
			}
		}
		f.BoxOrder = kept
	}
	return f, nil
}

// fleetLoadLockRefusal is path 10b's write: a patch of the per-box bands or
// the box order is refused when the stored or the new value names a box
// locked to someone else (either would change that box's place or band).
func (s *Server) fleetLoadLockRefusal(ctx context.Context, fl store.FleetLoadTarget, tenant, hum string, p store.FleetLoadPatch) *frameRefusal {
	if !p.BoxesSet && !p.OrderSet {
		return nil
	}
	v, err := s.lockViewFor(ctx, tenant, hum)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	if !v.any() {
		return nil
	}
	stored, err := fl.FleetLoadOf(ctx, tenant)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	var named []string
	if p.BoxesSet {
		for b := range p.Boxes {
			named = append(named, b)
		}
		for b := range stored.Boxes {
			named = append(named, b)
		}
	}
	if p.OrderSet {
		named = append(append(named, p.BoxOrder...), stored.BoxOrder...)
	}
	for _, b := range named {
		if v.hides(b) {
			return s.adminLockRefusal(ctx, tenant, b, hum, boxLockPathOperator)
		}
	}
	return nil
}

// assigneeLockRefusal is path 11: an issue is assigned to an agent on a
// locked box only by an owner of the lock, or by an agent of that box (its
// own agents file their own issues). A read error refuses with 503.
func (s *Server) assigneeLockRefusal(ctx context.Context, tenant, actor, box string, roster map[string][]string) *frameRefusal {
	if humanIDRe.MatchString(actor) {
		return s.adminLockRefusal(ctx, tenant, box, actor, boxLockPathIssueAssign)
	}
	l, err := s.boxLock(ctx, tenant, box)
	switch {
	case err != nil:
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	case l == nil || (!l.Tampered && slices.Contains(roster[box], actor)):
		return nil
	}
	s.lockRefused(ctx, tenant, box, "", "", boxLockPathIssueAssign)
	return &frameRefusal{codeBoxLocked, http.StatusForbidden, boxLockedDetail}
}

// writeLockRefusal answers rf on an HTTP route.
func writeLockRefusal(w http.ResponseWriter, rf *frameRefusal) {
	writeErr(w, rf.status, rf.token, rf.detail)
}

// lockSnaps is the locks last read per workspace (tenantLocks), for the
// live fan-out, which cannot read the store under the hub mutex. A
// workspace is known (read, with or without locks) or unknown (never read
// on this instance, or its last read failed); an unknown one hides every
// frame with a box end, as point (d) asks: hide, never show.
type lockSnaps struct {
	mu sync.RWMutex
	m  map[string]map[string]*store.BoxLock
}

func (n *lockSnaps) put(tenant string, locks map[string]*store.BoxLock) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if locks == nil {
		locks = map[string]*store.BoxLock{}
	}
	if n.m == nil {
		n.m = map[string]map[string]*store.BoxLock{}
	}
	n.m[tenant] = locks
}

// forget makes tenant unknown again (its locks read failed).
func (n *lockSnaps) forget(tenant string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	delete(n.m, tenant)
}

// hides reports whether a live message with ends p is hidden from hum by
// the last locks read for tenant: a box end locked to someone else, or any
// box end while tenant is unknown.
func (n *lockSnaps) hides(tenant, hum string, p parties) bool {
	if n == nil || tenant == "" {
		return false
	}
	n.mu.RLock()
	defer n.mu.RUnlock()
	ls, known := n.m[tenant]
	if !known {
		return p.fromBox != "" || p.toBox != ""
	}
	if len(ls) == 0 {
		return false
	}
	for _, b := range []string{p.fromBox, p.toBox} {
		if l, ok := ls[b]; ok && !l.IsOwner(hum) {
			return true
		}
	}
	return false
}
