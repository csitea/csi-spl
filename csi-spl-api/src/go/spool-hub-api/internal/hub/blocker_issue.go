package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"spool-hub-api/internal/timeutil"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// An unanswered blocker becomes an issue assigned to whoever it tags.
//
// Owner HUM-10, csitea topic e48433ef msg 2512ff1f: "whenever an agent or a
// person tags another person with a blocker, it should take a configurable
// amount of time (let's say 3 minutes). After these 3 minutes, if the person
// doesn't respond, this tagging message should be converted into an issue
// which is assigned to that person." Corrected in t1 de3c2cf5 msg 26c89f60:
// the tagged one may be a person or an agent, the issue counts on their
// issues, and the blocker mark and the issue are linked both ways - "whenever
// one marks one or the other, the issue will also be resolved", and "the
// issue will be resolved with the same comment that person makes in the
// discussion".
//
// The rules, as built:
//   - Trigger: a live message of kind blocker; each id it tags (recipient or
//     @mention, a member HUM-n or a roster agent, never its author) is one
//     assignee. The workspace setting blocker.issue_after_minutes is N
//     (default 3, 0 = off).
//   - Answer: any post by that assignee in the blocker's topic after it (a
//     reaction is not an answer; a reply by someone else is not theirs).
//   - N minutes without one: ONE issue per (blocker, assignee), status todo,
//     label blocker, reporter = the blocker's author, its body linking back to
//     the message. Its topic id is BlockerIssueTask, so issues' UNIQUE
//     (tenant_id, task_id) refuses a second one.
//   - The assignee answers after that: the issue resolves (done) and the
//     answer is quoted as its resolving comment.
//   - Resolving the issue clears the blocker mark on the message (kind back to
//     what it was before blocker, else note); clearing the mark resolves every
//     open issue made from that message.
//   - A workspace owner (the role's tenant_owner flag, never a literal id) is
//     the exception. Owner HUM-10, t1 5ea2e615 msg db5ed497: "An owner
//     question should not become an issue until the owner decides that." The
//     sweep never makes an issue for an owner; the blocker mark stays their
//     open question until they pick "Make an issue" on the message
//     (POST /v1/messages/{msg_id}/issue, blocker_issue_make.go), which makes
//     the same issue, with the same links both ways.
//     Asked in an issue's own topic, it holds that issue instead: blocked +
//     needs-owner until the owner answers (blocker_issue_hold.go, spec 135
//     section 9 Q2 A).
//
// It runs in the hub (RunBlockerIssues), so it works with every agent down;
// each workspace's rows are read and written in that workspace's scope. Two
// hub processes may run the same tick: the topic id keeps the create single,
// the derived comment ids keep the notes single, and a status already done is
// left alone.

const (
	blockerKind          = "blocker"
	blockerShortLookback = time.Hour      // every tick: a blocker due in the last hour
	blockerLongLookback  = timeutil.Day // every blockerLongEvery ticks: a late answer
	blockerLongEvery     = 10
	blockerSweepMax      = 200 // blocker posts per workspace per tick
	blockerExcerpt       = 2000
	blockerLabelColor    = "#dc2626"
)

// blockerLinkRe finds the message link the issue body carries.
var blockerLinkRe = regexp.MustCompile(`\(/m/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\)`)

// RunBlockerIssues runs the sweep every interval until ctx ends; interval <=
// 0 does nothing (tests drive SweepBlockerIssues with their own clock).
func (s *Server) RunBlockerIssues(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		return
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for i := 0; ; i++ {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			lookback := blockerShortLookback
			if i%blockerLongEvery == 0 {
				lookback = blockerLongLookback
			}
			s.SweepBlockerIssues(ctx, lookback)
		}
	}
}

// BlockerSweepResult is what one sweep did.
type BlockerSweepResult struct {
	Created  int
	Resolved int
}

// SweepBlockerIssues is one sweep over every live workspace: the blockers
// that fell due within lookback before now - N.
func (s *Server) SweepBlockerIssues(ctx context.Context, lookback time.Duration) BlockerSweepResult {
	var res BlockerSweepResult
	bi, ok := s.o.Store.(store.BlockerIssues)
	if _, ie := s.issueStore(); !ok || ie != nil {
		return res
	}
	tenants, err := bi.BlockerTenants(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("blocker issues: tenant list")
		return res
	}
	now := s.o.Now()
	for _, tenant := range tenants {
		t, err := s.o.Store.GetTenant(ctx, tenant)
		if err != nil {
			continue
		}
		n := t.Settings.Int(store.BlockerKeyIssueMinutes)
		if n <= 0 {
			continue
		}
		due := now.Add(-time.Duration(n) * time.Minute)
		posts, err := bi.BlockerPosts(ctx, tenant, due.Add(-lookback), due, blockerSweepMax)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("blocker issues: posts")
			continue
		}
		for _, p := range posts {
			for _, a := range p.Assignees() {
				c, r := s.blockerStep(ctx, bi, tenant, p, a, n)
				res.Created += c
				res.Resolved += r
			}
		}
	}
	if res.Created+res.Resolved > 0 {
		s.o.Log.Info().Int("created", res.Created).Int("resolved", res.Resolved).Msg("blocker issues")
	}
	return res
}

// blockerStep moves one (blocker, assignee) on: make the issue when it is due
// and unanswered, resolve it when the answer came after.
func (s *Server) blockerStep(ctx context.Context, bi store.BlockerIssues, tenant string, p store.BlockerPost, a string, n int) (created, resolved int) {
	task := store.BlockerIssueTask(tenant, p.MsgID, a)
	ref, err := bi.IssueByTask(ctx, tenant, task)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("msg_id", p.MsgID).Msg("blocker issues: issue lookup")
		return 0, 0
	}
	reply, answered, rerr := bi.FirstPostAfter(ctx, tenant, p.TaskID, a, p.ReceivedAt)
	if rerr != nil {
		s.o.Log.Error().Err(rerr).Str("tenant", tenant).Str("msg_id", p.MsgID).Msg("blocker issues: answer lookup")
		return 0, 0
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		if s.workspaceOwner(ctx, tenant, a) {
			s.blockerOwnerStep(ctx, bi, tenant, p, a, answered)
			return 0, 0
		}
		if answered {
			return 0, 0
		}
		if s.blockerCreate(ctx, tenant, p, a, task, n) {
			return 1, 0
		}
	case answered && ref.Status != "" && !issueResolved(ref.Status):
		if s.blockerResolve(ctx, tenant, ref.Number, task, bareAgentID(a),
			fmt.Sprintf("Resolved by the answer of @%s in the discussion:\n\n%s\n\n[Open the answer](/m/%s)",
				bareAgentID(a), blockerQuote(reply.Body), reply.MsgID), "answer:"+reply.MsgID) {
			return 0, 1
		}
	}
	return 0, 0
}

// blockerCreate makes the issue; false when the assignee is nobody this
// workspace knows, or another hub process made it first.
func (s *Server) blockerCreate(ctx context.Context, tenant string, p store.BlockerPost, a, task string, n int) bool {
	out, ie := s.blockerIssueOn(ctx, tenant, p.FromID, p, a, task, blockerDescription(p, a, n))
	if ie != nil {
		if ie.token != "conflict" && ie.token != "bad_assignee" {
			s.o.Log.Error().Str("tenant", tenant).Str("msg_id", p.MsgID).Str("err", ie.Error()).Msg("blocker issues: create")
		}
		return false
	}
	s.o.Log.Info().Str("tenant", tenant).Str("msg_id", p.MsgID).Str("assignee", a).Str("issue", out.Key()).
		Msg("blocker issues: unanswered blocker made an issue")
	return true
}

// blockerIssueOn makes the issue of (p, a) on topic task, reported by actor:
// status todo, label blocker, desc linking back to the message. The sweep and
// the owner's "Make an issue" both make it here, so both link the same way.
func (s *Server) blockerIssueOn(ctx context.Context, tenant, actor string, p store.BlockerPost, a, task, desc string) (store.Issue, *issueErr) {
	if ie := s.checkAssignee(ctx, tenant, a); ie != nil {
		return store.Issue{}, ie
	}
	if _, ie := s.createIssueLabel(ctx, tenant, actor, store.BlockerIssueLabel, blockerLabelColor); ie != nil && ie.token != "label_exists" {
		return store.Issue{}, ie
	}
	title := blockerTitle(p)
	status, labels := store.IssueTodo, []string{store.BlockerIssueLabel}
	return s.createIssueOn(ctx, tenant, actor, task, issueRequest{Title: &title, Description: &desc,
		Status: &status, Assignee: &a, Labels: &labels})
}

// workspaceOwner: a is a member HUM-n whose role is the workspace owner's.
// No member table (the door-off rig) makes nobody an owner.
func (s *Server) workspaceOwner(ctx context.Context, tenant, a string) bool {
	if !humanIDRe.MatchString(a) || s.o.Authorizer == nil {
		return false
	}
	acc, err := s.access(ctx, a, tenant)
	return err == nil && acc.TenantOwner
}

// blockerResolve posts the resolving comment on the issue's topic and sets
// it done; updateIssue then clears the mark on the message.
func (s *Server) blockerResolve(ctx context.Context, tenant string, number int, task, actor, comment, why string) bool {
	if err := s.postIssueNote(ctx, tenant, task, uid.FromSeed("spool-blocker-resolve:"+task+":"+why), comment); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Int("number", number).Msg("blocker issues: resolving comment")
	}
	done := store.IssueDone
	if _, ie := s.updateIssue(ctx, tenant, actor, number, issueRequest{Status: &done}); ie != nil {
		s.o.Log.Error().Str("tenant", tenant).Int("number", number).Str("err", ie.Error()).Msg("blocker issues: resolve")
		return false
	}
	return true
}

// resolveBlockerIssues: the mark was cleared on m, so every open issue made
// from it resolves.
func (s *Server) resolveBlockerIssues(ctx context.Context, tenant string, m store.EditableMessage, by string) {
	bi, ok := s.o.Store.(store.BlockerIssues)
	if !ok {
		return
	}
	for _, a := range blockerPostOf(m).Assignees() {
		task := store.BlockerIssueTask(tenant, m.MsgID, a)
		ref, err := bi.IssueByTask(ctx, tenant, task)
		if err != nil || ref.Status == "" || issueResolved(ref.Status) {
			continue
		}
		s.blockerResolve(ctx, tenant, ref.Number, task, by,
			fmt.Sprintf("Resolved: %s cleared the blocker mark on [the message](/m/%s).", by, m.MsgID), "mark:"+m.MsgID)
	}
}

// clearBlockerMark: issue i was resolved. When it was made from a blocker
// that still carries the mark, the mark goes back to the kind the message had
// before it, and the other issues made from it resolve too.
func (s *Server) clearBlockerMark(ctx context.Context, tenant, actor string, i store.Issue) {
	if !contains(i.Labels, store.BlockerIssueLabel) {
		return
	}
	sm := blockerLinkRe.FindStringSubmatch(i.Description)
	if sm == nil {
		return
	}
	m, err := s.o.Store.GetEditable(ctx, tenant, sm[1], s.o.Now())
	if err != nil || m.Kind != blockerKind || !madeFrom(tenant, m, i.TaskID) {
		return
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	c, err := s.o.Store.SetKind(ctx, tenant, m.MsgID, s.kindBeforeBlocker(ctx, tenant, m.MsgID), actor, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("msg_id", m.MsgID).Msg("blocker issues: clear mark")
		return
	}
	if c.Seq == 0 {
		return
	}
	m.Kind, m.KindSetAt, m.KindSetBy = c.To, now, actor
	s.fanoutEdited(ctx, tenant, m, m.Env, m.EditedAt, m.EditedBy, m.Revision)
	s.resolveBlockerIssues(ctx, tenant, m, actor)
}

// madeFrom: issue topic task is one BlockerIssueTask of m. The link in the
// body is text anyone may edit; the derived id is the proof.
func madeFrom(tenant string, m store.EditableMessage, task string) bool {
	for _, a := range blockerPostOf(m).Assignees() {
		if store.BlockerIssueTask(tenant, m.MsgID, a) == task {
			return true
		}
	}
	return false
}

// kindBeforeBlocker is the kind the message had before its latest change to
// blocker; note when it was sent as a blocker.
func (s *Server) kindBeforeBlocker(ctx context.Context, tenant, msgID string) string {
	cs, _ := s.o.Store.KindChanges(ctx, tenant, msgID)
	for i := len(cs) - 1; i >= 0; i-- {
		if cs[i].To == blockerKind && cs[i].From != blockerKind && msg.ValidKind(cs[i].From) {
			return cs[i].From
		}
	}
	return "note"
}

func blockerPostOf(m store.EditableMessage) store.BlockerPost {
	return store.BlockerPost{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, FromID: m.FromID,
		ToID: m.ToID, Body: m.Body, ReceivedAt: m.ReceivedAt}
}

// issueResolved: done or discarded.
func issueResolved(status string) bool {
	return status == store.IssueDone || status == store.IssueDiss
}

func bareAgentID(id string) string {
	b, _, _ := strings.Cut(id, "@")
	return b
}

// blockerTitle is the blocker's first non-empty line, without a heading or
// quote marker, cut to the title limit.
func blockerTitle(p store.BlockerPost) string {
	for _, line := range strings.Split(p.Body, "\n") {
		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "#> "))
		if line != "" {
			return cutRunes(line, store.IssueTitleMax)
		}
	}
	return "Blocker from " + p.FromID
}

func blockerDescription(p store.BlockerPost, a string, n int) string {
	return fmt.Sprintf("Unanswered blocker from %s to @%s: no answer in %d min, so it became this issue.\n\n%s\n\n"+
		"[Open the message](/m/%s) in topic `%s`. An answer by @%s in that discussion resolves this issue; "+
		"resolving it clears the blocker mark.", p.FromID, bareAgentID(a), n, blockerQuote(p.Body), p.MsgID, p.TaskID, bareAgentID(a))
}

// blockerQuote is body as a markdown quote, cut to blockerExcerpt runes.
func blockerQuote(body string) string {
	return "> " + strings.ReplaceAll(cutRunes(strings.TrimSpace(body), blockerExcerpt), "\n", "\n> ")
}

// postIssueNote stores one hub note (HUB-0, signed as box-wui like the
// #public notice) on an issue's discussion topic; id makes a second post of
// the same note a no-op insert.
func (s *Server) postIssueNote(ctx context.Context, tenant, task, id, body string) error {
	if len(s.o.WUIKey) == 0 {
		return nil
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: 1, MsgID: id, TaskID: task, TS: now.Format(time.RFC3339), From: PublicNoticeFrom,
		To: BroadcastID, Kind: "note", Body: body, Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(s.o.WUIKey, WUIBox, WUIBox, store.ChannelIssues, "", m)
	if err != nil {
		return err
	}
	canon, err := env.Marshal()
	if err != nil {
		return err
	}
	files, _ := json.Marshal(m.Files)
	at := s.o.Now().Truncate(time.Microsecond)
	row := store.Message{
		TenantID: tenant, MsgID: id, TaskID: task, TS: now,
		FromBox: WUIBox, FromID: m.From, ToBox: WUIBox, ToID: m.To, Kind: m.Kind, Body: m.Body,
		Files: files, Msg: env.Msg, EnvSig: env.Sig, Env: canon, Channel: store.ChannelIssues,
		ReceivedAt: at, ExpiresAt: at.Add(s.retention(store.ChannelIssues)),
	}
	inserted, sentInOne, err := s.insertRow(ctx, row)
	if err != nil {
		return err
	}
	if inserted && !sentInOne {
		if err := s.o.Store.Enqueue(ctx, tenant, id, WUIBox, row.ReceivedAt, row.ReceivedAt.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
			return err
		}
	}
	if inserted {
		s.fanoutWUI(ctx, row)
	}
	return nil
}
