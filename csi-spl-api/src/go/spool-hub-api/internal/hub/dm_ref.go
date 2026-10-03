package hub

import (
	"context"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 067 rules 3 and 4 (section 8 row L4, rdb 0112).
//
// Rule 3: a DM about a channel topic carries the topic's id. A send claims it
// as the frame field ref_task_id (browser: wuiIn, box: wire.Frame). It is
// untrusted (spec 067 section 7): kept only when the sender may read the
// topic, else dropped and the DM stored as a plain DM. A DM reply that claims
// none inherits its thread's (store.DMMirror.DMRefTask).
//
// Rule 4: a PERSON's DM to an agent on such a thread is also stored as a
// thread reply in the topic, in the same transaction, with mirror_of = the
// DM's msg_id; edits and archives of the DM follow it in the store (edge 3).
// Only person -> agent DMs are mirrored (Q5): an agent's DM reply is not, so a
// copy can never be copied back (edge 5).
//
// Neither field reaches a box. msg.Parse refuses unknown keys, so a box binary
// older than rdb 0112's L3 refuses an envelope whose inner msg carries
// ref_task_id: the hub never sets msg.Message.RefTaskID, it stores the claim
// on the row only. The copy is a browser-only (unsigned box-wui) row: the
// agent already holds the DM, and a box copy would be the echo of edge 5.

// dmRefKey carries a send's dmRef from onSend / wuiSend to commitRowTyped.
type dmRefKey struct{}

// dmRef is what a send knows about the topic its DM is about. task is the
// claimed ref_task_id once its read door passed ("" = none claimed, or
// dropped); person marks a browser send by a person, whose read door is
// member's ("" = the door-off rig, which reads everything).
type dmRef struct {
	task   string
	person bool
	member string
}

// wuiDMRef is a browser send's dmRef: the claim is kept when the sending
// member may read the topic's channel (canReadChannel, the WUI's own door).
func (s *Server) wuiDMRef(ctx context.Context, c *wuiConn, claimed string) context.Context {
	r := dmRef{person: isPerson(c.from), member: c.member}
	if task, ch := s.refTopic(ctx, c.tenant, claimed); ch != "" {
		switch ok, err := s.canReadChannel(ctx, c.tenant, ch, c.member); {
		case err != nil:
			s.o.Log.Error().Err(err).Str("ref_task_id", task).Msg("dm ref door")
		case ok:
			r.task = task
		}
	}
	s.logDroppedRef(c.tenant, claimed, r.task)
	return context.WithValue(ctx, dmRefKey{}, r)
}

// boxDMRef is a box send's dmRef: the claim is kept when the sending agent
// is in the topic's channel (agentInChannel, the box's own post door).
func (s *Server) boxDMRef(ctx context.Context, x *session, from, claimed string) context.Context {
	var r dmRef
	if task, ch := s.refTopic(ctx, x.tenant, claimed); ch != "" {
		switch in, err := s.agentInChannel(ctx, x.tenant, ch, x.box, from); {
		case err != nil:
			s.o.Log.Error().Err(err).Str("ref_task_id", task).Msg("dm ref door")
		case in:
			r.task = task
		}
	}
	s.logDroppedRef(x.tenant, claimed, r.task)
	return context.WithValue(ctx, dmRefKey{}, r)
}

// refTopic is a claimed ref_task_id lower-cased, and the channel its topic
// lives in. channel "" = no uuid, or no channel row on that task: nothing for
// a DM to be about, so the claim is dropped.
func (s *Server) refTopic(ctx context.Context, tenant, claimed string) (task, channel string) {
	task = strings.ToLower(claimed)
	if task == "" || !uuidRe.MatchString(task) {
		return "", ""
	}
	return task, s.channelOf(ctx, tenant, "", task)
}

// logDroppedRef leaves one line per dropped claim: the sender sees no
// refusal (the DM is still stored), so the log is where a drop shows.
func (s *Server) logDroppedRef(tenant, claimed, kept string) {
	if claimed != "" && kept == "" {
		s.o.Log.Info().Str("tenant", tenant).Str("ref_task_id", claimed).Msg("dm ref dropped: not a topic the sender may read")
	}
}

// isPerson: a human member or a guest, never an agent (Q5).
func isPerson(id string) bool {
	return strings.HasPrefix(id, "HUM-") || strings.HasPrefix(id, GuestPrefix)
}

// insertRowRef is insertRow for a send that went through wuiDMRef or
// boxDMRef. On a DM it stores ref_task_id (claimed, else inherited), and a
// person's DM to an agent goes in with its channel copy (dmMirrorRow) in one
// transaction. Any other row, a hub-originated one, or a store without
// DMMirror is insertRow unchanged.
func (s *Server) insertRowRef(ctx context.Context, row *store.Message) (inserted, sentInOne bool, err error) {
	r, carried := ctx.Value(dmRefKey{}).(dmRef)
	dm, ok := s.o.Store.(store.DMMirror)
	if !carried || !ok || row.Channel != "" {
		return s.insertRow(ctx, *row)
	}
	row.RefTaskID = r.task
	if row.RefTaskID == "" {
		ref, err := dm.DMRefTask(ctx, row.TenantID, row.TaskID)
		if err != nil { // the DM is stored without it rather than refused
			s.o.Log.Error().Err(err).Str("task_id", row.TaskID).Msg("dm ref inherit")
		}
		row.RefTaskID = ref
	}
	cp, mirror := s.dmMirrorRow(ctx, *row, r)
	if !mirror {
		return s.insertRow(ctx, *row)
	}
	if s.o.WakeWUI { // spec 059 S3: both rows are fanned out here
		s.fanned.add([2]string{row.TenantID, row.MsgID})
		s.fanned.add([2]string{cp.TenantID, cp.MsgID})
	}
	_, si := s.o.Store.(store.SentInserter)
	var dmSent time.Time
	if sentInOne = si && row.ToBox == WUIBox; sentInOne {
		dmSent = row.ReceivedAt.Add(s.o.QueueTTL)
	}
	if inserted, err = dm.InsertMirrored(ctx, *row, dmSent, cp, cp.ReceivedAt.Add(s.o.QueueTTL)); err != nil || !inserted {
		return inserted, sentInOne, err
	}
	if !si { // the copy's box-wui delivery, as commitRowTyped writes a DM's
		now := cp.ReceivedAt
		if err := s.o.Store.Enqueue(ctx, cp.TenantID, cp.MsgID, WUIBox, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
			return true, sentInOne, err
		}
		if _, err := s.o.Store.ClaimSent(ctx, cp.TenantID, cp.MsgID, WUIBox, now); err != nil {
			return true, sentInOne, err
		}
	}
	s.fanoutWUI(ctx, cp)
	return true, sentInOne, nil
}

// dmMirrorRow is the channel copy of a person's DM answer (spec 067 3.4), and
// whether there is one: row is a person's DM to an agent with a ref_task_id,
// and the person may read the topic's channel, which is not archived (edge
// case 2) - checked on every send, an inherited ref included. The copy is
// row in topic T: a fresh msg_id, is_parent 0, the same author, recipient,
// ts, kind, body and files, mirror_of = the DM, in an unsigned box-wui
// envelope claiming T's channel. A lookup error stores the DM alone.
func (s *Server) dmMirrorRow(ctx context.Context, row store.Message, r dmRef) (store.Message, bool) {
	if row.RefTaskID == "" || !r.person || !isPerson(row.FromID) || !isAgent(row.ToID) {
		return store.Message{}, false
	}
	tenant := row.TenantID
	ch := s.channelOf(ctx, tenant, "", row.RefTaskID)
	if ch == "" {
		return store.Message{}, false
	}
	if may, err := s.canReadChannel(ctx, tenant, ch, r.member); err != nil || !may {
		return store.Message{}, false
	}
	if _, archived, err := s.o.Store.ArchivedChannel(ctx, tenant, ch); err != nil || archived {
		return store.Message{}, false
	}
	inner, err := msg.Parse(row.Msg)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", row.MsgID).Msg("dm mirror")
		return store.Message{}, false
	}
	inner.MsgID, inner.TaskID, inner.RefTaskID, inner.Sig = uid.New(), row.RefTaskID, "", ""
	raw, err := msg.Canonical(inner)
	if err != nil {
		return store.Message{}, false
	}
	canon, err := (&wire.Envelope{FromBox: WUIBox, ToBox: WUIBox, Channel: ch, Msg: raw}).Marshal()
	if err != nil {
		return store.Message{}, false
	}
	cp := row
	cp.MsgID, cp.TaskID, cp.Channel, cp.ParentTaskID, cp.IsParent = inner.MsgID, row.RefTaskID, ch, "", 0
	cp.FromBox, cp.ToBox, cp.Msg, cp.Env, cp.EnvSig = WUIBox, WUIBox, raw, canon, ""
	cp.ExpiresAt = cp.ReceivedAt.Add(s.retention(ch))
	cp.RefTaskID, cp.MirrorOf, cp.TypedBy = "", row.MsgID, ""
	return cp, true
}
