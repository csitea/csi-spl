package hub

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A question to the owner holds up the issue it is asked in (spec 135
// section 9 Q2 A, owner HUM-10 t1 5ea2e615 msgs f2c24a7b and 910b14c9):
// "Discussions are for discussions, and issues are for concrete, condensed
// data about what needs to be done." A blocker that tags a workspace owner
// files no issue (blocker_issue.go); when it is posted in an issue's own
// topic and stays unanswered N minutes, that issue goes blocked and gets the
// label needs-owner plus ONE line in its description, the shape of
// do_spl_issue_needs_owner (the daily digest lists it):
//
//	**Needs owner** since <ISO-8601 Z>: answer [the question](/m/<msg_id>) (was <status>)
//
// The owner's answer in that topic unblocks it: the label and the line go,
// the status goes back to what it was. An issue already marked needs-owner
// by someone else, or one that is done / diss, is left alone.

const needsOwnerLabel, needsOwnerColor = "needs-owner", "#b45309"

// needsOwnerLineRe is the hold line of one message; group 1 is the status the
// issue had before it.
func needsOwnerLineRe(msgID string) *regexp.Regexp {
	return regexp.MustCompile(`(?m)^\*\*Needs owner\*\* since \S+Z: answer \[the question\]\(/m/` +
		regexp.QuoteMeta(msgID) + `\) \(was ([a-z]+)\)\n?`)
}

// blockerOwnerStep is blockerStep for an owner a: hold the issue of p's topic
// while the question is open, release it once a answered.
func (s *Server) blockerOwnerStep(ctx context.Context, bi store.BlockerIssues, tenant string, p store.BlockerPost, a string, answered bool) {
	ref, err := bi.IssueByTask(ctx, tenant, p.TaskID)
	if err != nil || ref.Status == "" {
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Str("msg_id", p.MsgID).Msg("blocker hold: issue lookup")
		}
		return
	}
	is, ie := s.issueStore()
	if ie != nil {
		return
	}
	i, err := is.GetIssue(ctx, tenant, ref.Number)
	if err != nil {
		return
	}
	if answered {
		s.releaseOwnerHold(ctx, tenant, a, p, i)
		return
	}
	s.holdForOwner(ctx, tenant, p, i)
}

// holdForOwner: blocked (eval, todo, wip, onhold; blocked and qas keep
// theirs), label needs-owner, the line. Once: a needs-owner label already
// there means it is held, and a line of this message without the label means
// someone took the label off by hand, which stands.
func (s *Server) holdForOwner(ctx context.Context, tenant string, p store.BlockerPost, i store.Issue) {
	if issueResolved(i.Status) || contains(i.Labels, needsOwnerLabel) || needsOwnerLineRe(p.MsgID).MatchString(i.Description) {
		return
	}
	if _, ie := s.createIssueLabel(ctx, tenant, p.FromID, needsOwnerLabel, needsOwnerColor); ie != nil && ie.token != "label_exists" {
		s.o.Log.Error().Str("tenant", tenant).Str("err", ie.Error()).Msg("blocker hold: label")
		return
	}
	status := i.Status
	if status != store.IssueBlocked && status != store.IssueQAS {
		status = store.IssueBlocked
	}
	line := fmt.Sprintf("**Needs owner** since %s: answer [the question](/m/%s) (was %s)",
		s.o.Now().UTC().Format(time.RFC3339), p.MsgID, i.Status)
	desc := strings.TrimRight(i.Description, "\n")
	if desc != "" {
		desc += "\n\n"
	}
	desc += line
	labels := append(append([]string{}, i.Labels...), needsOwnerLabel)
	if _, ie := s.updateIssue(ctx, tenant, p.FromID, i.Number, issueRequest{Status: &status, Labels: &labels, Description: &desc}); ie != nil {
		s.o.Log.Error().Str("tenant", tenant).Int("number", i.Number).Str("err", ie.Error()).Msg("blocker hold: update")
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("msg_id", p.MsgID).Str("issue", i.Key()).Msg("blocker hold: issue waits for the owner")
}

// releaseOwnerHold: the owner answered; only the hold this message put on
// (its own line) is taken off.
func (s *Server) releaseOwnerHold(ctx context.Context, tenant, owner string, p store.BlockerPost, i store.Issue) {
	rx := needsOwnerLineRe(p.MsgID)
	sm := rx.FindStringSubmatch(i.Description)
	if sm == nil || !contains(i.Labels, needsOwnerLabel) {
		return
	}
	desc := strings.TrimRight(rx.ReplaceAllString(i.Description, ""), "\n")
	labels := make([]string, 0, len(i.Labels))
	for _, l := range i.Labels {
		if l != needsOwnerLabel {
			labels = append(labels, l)
		}
	}
	q := issueRequest{Labels: &labels, Description: &desc}
	if before := sm[1]; i.Status == store.IssueBlocked && store.ValidIssueStatus(before) && !issueResolved(before) {
		q.Status = &before
	}
	if _, ie := s.updateIssue(ctx, tenant, owner, i.Number, q); ie != nil {
		s.o.Log.Error().Str("tenant", tenant).Int("number", i.Number).Str("err", ie.Error()).Msg("blocker hold: release")
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("msg_id", p.MsgID).Str("issue", i.Key()).Msg("blocker hold: the owner answered")
}
