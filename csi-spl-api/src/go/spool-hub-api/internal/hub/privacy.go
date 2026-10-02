package hub

import (
	"context"
	"net/http"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The read door for channels and DMs (rdb 0028, owner's call 2026-09-23).
//
// Two rules, in one place, applied by every path that hands a stored message
// to a browser:
//
//   - a CHANNEL message is readable by the HUMANS in that channel. The three
//     default channels (#lobby, #alerts, #feedback) and the issue
//     discussions (store.ChannelIssues) are public to the tenant and
//     need no membership; every created channel is members-only, and a
//     non-member cannot learn it exists - it is absent from the channel list
//     and its topics read 404, never 403.
//   - a DM (no channel tag) is readable by its two ends only.
//
// Before this file the only gate was rbac.TopicsRead, a TENANT-wide role, so
// any signed-in member could read any topic of the tenant by its task_id -
// another member's DM included. Membership for humans did not exist at all:
// channel_subscriptions (0002) is the agent/box delivery half.
//
// A reader of "" filters nothing. That is the door-off rig (ViewDoorOff, lde
// only - config refuses it elsewhere), and it is the rule the topic LIST has
// always used for DMs; in the session door humanTenant guarantees a human.

// readerID is the reader a read door filters for: the member HUM-* of the
// session, or "" on the door-off lde rig (which filters nothing). It FAILS
// CLOSED: a lookup error, or no human while the door is on,
// answers ok=false and the caller refuses. The sites it replaced dropped
// memberID's error, and "" is "filter nothing" - so a transient membership
// error, or a member removed mid-request, turned the door off for that
// request (the channel list, the topic list, a topic, search, a file).
//
// With the door OFF (lde only) no session is the normal anonymous reader, and
// its lookup error means exactly that: "" as before.
func (s *Server) readerID(r *http.Request, tenant string) (string, bool) {
	hum, err := s.memberID(r, tenant)
	if s.o.ViewDoor == ViewDoorOff {
		if err != nil {
			return "", true
		}
		return hum, true
	}
	if err != nil || hum == "" {
		return "", false
	}
	return hum, true
}

// readerChannels is the set of created channels human belongs to. The result
// is used as an allow-list, so a lookup error must fail CLOSED - an empty set
// leaves the default channels readable and nothing else.
func (s *Server) readerChannels(ctx context.Context, tenant, human string) ([]string, error) {
	if human == "" {
		return nil, nil
	}
	return s.o.Store.HumanChannels(ctx, tenant, human)
}

// canReadChannel reports whether human may read channel. An empty channel is
// a DM and is not this rule's business: canReadTopic decides those.
func (s *Server) canReadChannel(ctx context.Context, tenant, channel, human string) (bool, error) {
	if channel == "" || human == "" || store.ChannelPublic(channel) {
		return true, nil
	}
	ms, err := s.channelHumans(ctx, tenant, store.NormalizeChannel(channel))
	if err != nil {
		return false, err
	}
	for _, m := range ms {
		if m == human {
			return true, nil
		}
	}
	return false, nil
}

// canReadMessage applies the per-message rule to one stored message: a DM by
// its two ends, a channel message by canReadChannel. "" reads all (door
// off). Edit, delete and reactions ask it BEFORE anything that tells the
// caller the message exists: they answered 403 not_author to a
// non-member, which a missing id answers 404, and reactions checked only the
// topic, so a mixed topic let a member react to (and read the reaction list
// of) a DM they are not an end of.
func (s *Server) canReadMessage(ctx context.Context, tenant string, m store.EditableMessage, human string) (bool, error) {
	if human == "" {
		return true, nil
	}
	if m.Channel == "" {
		return m.FromID == human || m.ToID == human, nil
	}
	return s.canReadChannel(ctx, tenant, m.Channel, human)
}

// messageDoor answers the per-message door for a browser request, writing
// the refusal (404 as for a missing id, 500 on a lookup error). ok=true =
// the caller may go on and learn the message exists.
func (s *Server) messageDoor(w http.ResponseWriter, r *http.Request, tenant string, m store.EditableMessage) bool {
	s.openMembersMemo(r.Context())
	reader, ok := s.readerID(r, tenant)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return false
	}
	switch may, err := s.canReadMessage(r.Context(), tenant, m, reader); {
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("message door")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return false
	case !may:
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return false
	}
	return true
}

// canReadTopic applies both rules to one task_id. found=false when the
// tenant has no message with that task_id in retention, which the caller
// answers exactly as it answers "not yours": 404.
func (s *Server) canReadTopic(ctx context.Context, tenant, task, human string) (ok, found bool, err error) {
	a, err := s.o.Store.TopicAccess(ctx, tenant, task, s.o.Now())
	if err != nil {
		return false, false, err
	}
	if !a.Found {
		return false, false, nil
	}
	if human == "" {
		return true, true, nil
	}
	// Readable when the topic holds at least ONE message this human may
	// read. It is only the door onto the topic: which messages come back is
	// decided again, per message, by TopicMsgQuery's Reader - a topic that
	// mixes a DM with a channel reply must not hand over the DM half.
	if a.HasDM() && a.Party(human) {
		return true, true, nil
	}
	for _, ch := range a.Channels {
		if ch == "" {
			continue
		}
		switch may, err := s.canReadChannel(ctx, tenant, ch, human); {
		case err != nil:
			return false, true, err
		case may:
			return true, true, nil
		}
	}
	return false, true, nil
}

// memberSet is the channel's human members as a set, for the live fan-out.
// nil means "no membership rule applies" (a public or DM message).
func (s *Server) channelMemberSet(ctx context.Context, tenant, channel string) map[string]bool {
	if channel == "" || store.ChannelPublic(channel) {
		return nil
	}
	ms, err := s.channelHumans(ctx, tenant, channel)
	if err != nil {
		// Fail closed: an empty set reaches nobody, which is the safe end of
		// a lookup failure on a members-only channel.
		return map[string]bool{}
	}
	out := make(map[string]bool, len(ms))
	for _, m := range ms {
		out[m] = true
	}
	return out
}

// Request memo of channel_humans (perf round 4 G1). A message route asked for
// the same channel's members for its door (messageDoor, a target's
// canReadChannel) and again for every fan-out set: kind, archive and
// reaction 2 reads, promote 3, move 4, merge-topic 5. messageDoor opens a
// memo on its request's context and the rest of that request reads each
// channel once.
//
// It is NOT a cache: it is dropped when the request's context ends, so a
// member removed between two requests is out on the next one (025 FR-004,
// as store.WithMemo). It is opened only by messageDoor, whose routes never
// change channel membership; the membership routes never carry one. A
// lookup error is never memoised. A context that never ends (Background,
// WithoutCancel) gets no memo, so nothing outlives the request.
type membersMemo struct {
	mu sync.Mutex
	m  map[[2]string][]string
}

type membersMemoKey struct {
	s   *Server
	ctx context.Context
}

// membersMemos maps an open request to its memo. It is keyed on the
// request's context rather than carried in it because messageDoor cannot
// hand its caller a new context.
var membersMemos sync.Map

func (s *Server) openMembersMemo(ctx context.Context) {
	if ctx.Done() == nil {
		return
	}
	k := membersMemoKey{s, ctx}
	if _, loaded := membersMemos.LoadOrStore(k, &membersMemo{m: map[[2]string][]string{}}); !loaded {
		context.AfterFunc(ctx, func() { membersMemos.Delete(k) })
	}
}

// channelHumans is Store.ChannelHumanMembers through the request's memo,
// when messageDoor opened one. Callers only read the list.
func (s *Server) channelHumans(ctx context.Context, tenant, channel string) ([]string, error) {
	if ctx.Done() == nil {
		return s.o.Store.ChannelHumanMembers(ctx, tenant, channel)
	}
	v, ok := membersMemos.Load(membersMemoKey{s, ctx})
	if !ok {
		return s.o.Store.ChannelHumanMembers(ctx, tenant, channel)
	}
	mm, k := v.(*membersMemo), [2]string{tenant, channel}
	mm.mu.Lock()
	ms, hit := mm.m[k]
	mm.mu.Unlock()
	if hit {
		return ms, nil
	}
	ms, err := s.o.Store.ChannelHumanMembers(ctx, tenant, channel)
	if err == nil {
		mm.mu.Lock()
		mm.m[k] = ms
		mm.mu.Unlock()
	}
	return ms, err
}
