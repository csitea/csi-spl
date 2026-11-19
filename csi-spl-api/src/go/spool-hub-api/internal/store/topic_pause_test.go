package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"
)

// Spec 179 row B1 (rdb 0297, SPL-5980): pause the agents of a discussion.

// TestTopicPauseIssuesRestore: a pause puts the discussion's open issues on
// hold and keeps their status; a resume puts back every held issue still
// onhold (wip as todo) even when it got a comment and an updated_at bump
// after paused_at, and leaves one moved out of onhold by hand. Done, qas,
// onhold and epics are never held. A repeat of either is a no-op.
func TestTopicPauseIssuesRestore(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			is, tp := s.(Issues), s.(TopicPauseStore)
			T, U := uuid4(), uuid4()
			for i, task := range []string{T, U} {
				if _, err := s.InsertMessage(ctx, msgFor(tid, task, "box-b", now.Add(time.Duration(i)*time.Second), now, `{"n":"`+uuid4()+`"}`)); err != nil {
					t.Fatal(err)
				}
			}
			mk := func(title, kind, status string, tasks ...string) Issue {
				t.Helper()
				i, err := is.CreateIssue(ctx, Issue{TenantID: tid, Title: title, Kind: kind, TaskID: uuid4(), Discussions: tasks, CreatedBy: "HUM-1"}, now)
				if err != nil {
					t.Fatal(err)
				}
				if status != i.Status {
					st := status
					if i, err = is.UpdateIssue(ctx, tid, i.Number, IssuePatch{Status: &st}, "HUM-1", now); err != nil {
						t.Fatal(err)
					}
				}
				return i
			}
			status := func(n int) string {
				t.Helper()
				i, err := is.GetIssue(ctx, tid, n)
				if err != nil {
					t.Fatalf("issue %d: %v", n, err)
				}
				return i.Status
			}
			todo := mk("todo on T", "", IssueTodo, T)
			wip := mk("wip on T and U", "", IssueWIP, T, U)
			blocked := mk("blocked on T", "", IssueBlocked, T)
			eval := mk("eval on T", "", IssueEval, T)
			byHand := mk("todo on T, moved by hand", "", IssueTodo, T)
			untouched := map[int]string{
				mk("done on T", "", IssueDone, T).Number:           IssueDone,
				mk("qas on T", "", IssueQAS, T).Number:             IssueQAS,
				mk("onhold on T", "", IssueOnHold, T).Number:       IssueOnHold,
				mk("epic on T", IssueKindEpic, IssueWIP, T).Number: IssueWIP,
				mk("todo on U only", "", IssueTodo, U).Number:      IssueTodo,
			}

			pausedAt := now.Add(time.Minute)
			st, err := tp.SetTopicPaused(ctx, tid, strings.ToUpper(T), "HUM-10", "  No need to stand by  ", pausedAt, true)
			if err != nil {
				t.Fatal(err)
			}
			wantHeld := []int{todo.Number, wip.Number, blocked.Number, eval.Number, byHand.Number}
			if got := followNums(st.Followed); !st.Changed || !slices.Equal(got, wantHeld) {
				t.Fatalf("pause: changed=%v held %v, want true %v", st.Changed, got, wantHeld)
			}
			for _, f := range st.Followed {
				if f.Op != IssueFollowPause || f.TaskID != T || f.To != IssueOnHold {
					t.Errorf("pause follow %+v", f)
				}
			}
			p := st.Pause
			if p.TaskID != T || p.PausedBy != "HUM-10" || !p.PausedAt.Equal(pausedAt) || p.Reason != "No need to stand by" || !p.Paused() {
				t.Fatalf("pause row %+v", p)
			}
			for _, n := range wantHeld {
				if got := status(n); got != IssueOnHold {
					t.Fatalf("issue %d is %s after the pause, want onhold", n, got)
				}
			}
			for n, want := range untouched {
				if got := status(n); got != want {
					t.Errorf("issue %d is %s after the pause, want %s (never held)", n, got, want)
				}
			}

			// A repeat: no new hold, the first stamp kept, only a new reason.
			again, err := tp.SetTopicPaused(ctx, tid, T, "HUM-11", "", pausedAt.Add(time.Minute), true)
			if err != nil || again.Changed || len(again.Followed) != 0 || again.Pause.PausedBy != "HUM-10" || again.Pause.Reason != "No need to stand by" {
				t.Fatalf("repeat pause: %+v %v, want unchanged", again, err)
			}
			again, err = tp.SetTopicPaused(ctx, tid, T, "HUM-11", "new reason", pausedAt.Add(time.Minute), true)
			if err != nil || again.Changed || again.Pause.Reason != "new reason" || !again.Pause.PausedAt.Equal(pausedAt) {
				t.Fatalf("repeat pause with a reason: %+v %v", again, err)
			}
			if got, ok, err := tp.AnyTopicPaused(ctx, tid, uuid4(), "not-a-uuid", T); err != nil || !ok || got.TaskID != T {
				t.Fatalf("AnyTopicPaused(other, junk, T) = %+v %v %v, want T", got, ok, err)
			}
			if _, ok, err := tp.AnyTopicPaused(ctx, tid, U, ""); err != nil || ok {
				t.Fatalf("AnyTopicPaused(U) = %v %v, want not paused", ok, err)
			}

			// While paused: a comment and an edit on todo (updated_at moves past
			// paused_at), and byHand is moved out of onhold by hand.
			if _, err := s.InsertMessage(ctx, msgFor(tid, todo.TaskID, "box-wui", pausedAt.Add(2*time.Minute), now, `{"c":"`+uuid4()+`"}`)); err != nil {
				t.Fatal(err)
			}
			title := "todo on T, edited while paused"
			if _, err := is.UpdateIssue(ctx, tid, todo.Number, IssuePatch{Title: &title}, "HUM-2", pausedAt.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			if i, _ := is.GetIssue(ctx, tid, todo.Number); !i.UpdatedAt.After(pausedAt) {
				t.Fatalf("CONTROL: the edit left updated_at at %v, want after %v", i.UpdatedAt, pausedAt)
			}
			w := IssueWIP
			if _, err := is.UpdateIssue(ctx, tid, byHand.Number, IssuePatch{Status: &w}, "HUM-2", pausedAt.Add(3*time.Minute)); err != nil {
				t.Fatal(err)
			}

			st, err = tp.SetTopicPaused(ctx, tid, T, "HUM-12", "ignored", pausedAt.Add(4*time.Minute), false)
			if err != nil {
				t.Fatal(err)
			}
			wantBack := map[int]string{todo.Number: IssueTodo, wip.Number: IssueTodo, blocked.Number: IssueBlocked, eval.Number: IssueEval}
			if got := followNums(st.Followed); !st.Changed || st.Pause.Paused() || len(got) != len(wantBack) {
				t.Fatalf("resume: changed=%v pause=%+v restored %v, want %v", st.Changed, st.Pause, got, wantBack)
			}
			for _, f := range st.Followed {
				if f.Op != IssueFollowResume || f.From != IssueOnHold || f.To != wantBack[f.Number] {
					t.Errorf("resume follow %+v, want onhold -> %s", f, wantBack[f.Number])
				}
			}
			for n, want := range wantBack {
				if got := status(n); got != want {
					t.Errorf("issue %d is %s after the resume, want %s", n, got, want)
				}
			}
			if got := status(byHand.Number); got != IssueWIP {
				t.Errorf("the issue moved by hand is %s after the resume, want wip (left as it is)", got)
			}
			for n, want := range untouched {
				if got := status(n); got != want {
					t.Errorf("issue %d is %s after the resume, want %s", n, got, want)
				}
			}
			if _, ok, err := tp.AnyTopicPaused(ctx, tid, T); err != nil || ok {
				t.Fatalf("AnyTopicPaused(T) after the resume = %v %v", ok, err)
			}
			if again, err := tp.SetTopicPaused(ctx, tid, T, "HUM-12", "", pausedAt.Add(5*time.Minute), false); err != nil || again.Changed || len(again.Followed) != 0 {
				t.Fatalf("repeat resume: %+v %v, want unchanged", again, err)
			}
		})
	}
}

// TestTopicPauseRefusals: a bad task id, no actor or an unknown workspace
// write nothing; a long reason is cut to its column.
func TestTopicPauseRefusals(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tid, tp, now := newTenant(t, s), s.(TopicPauseStore), time.Now().UTC()
			if _, err := tp.SetTopicPaused(ctx, tid, "dispatch-a4b718a6", "HUM-1", "", now, true); !errors.Is(err, ErrBadTopicTask) {
				t.Errorf("bad task: %v", err)
			}
			if _, err := tp.SetTopicPaused(ctx, tid, uuid4(), "", "", now, true); !errors.Is(err, ErrBadTopicPauseBy) {
				t.Errorf("no actor: %v", err)
			}
			if _, err := tp.SetTopicPaused(ctx, "", uuid4(), "HUM-1", "", now, true); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant: %v", err)
			}
			if _, err := tp.SetTopicPaused(ctx, "no-such-"+uuid4(), uuid4(), "HUM-1", "", now, true); !errors.Is(err, ErrNotFound) {
				t.Errorf("unknown workspace: %v", err)
			}
			st, err := tp.SetTopicPaused(ctx, tid, uuid4(), "HUM-1", strings.Repeat("é", TopicPauseReasonMax+20), now, true)
			if err != nil || len([]rune(st.Pause.Reason)) != TopicPauseReasonMax {
				t.Fatalf("long reason: %d rune(s) %v, want %d", len([]rune(st.Pause.Reason)), err, TopicPauseReasonMax)
			}
		})
	}
}

// TestFallbackSkipsPausedTopic: a human post in a paused topic is neither
// unheard, unanswered nor re-escalated (spec 179 5.2 row 8); the same post
// in an unpaused topic is, and the paused one is again after a resume.
func TestFallbackSkipsPausedTopic(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tid := newTenant(t, s)
			fb, tp := s.(Fallbacks), s.(TopicPauseStore)
			base := time.Now().UTC().Truncate(time.Microsecond).Add(-time.Hour)
			P, Q := uuid4(), uuid4()
			posts := map[string]Message{}
			for i, task := range []string{P, Q} {
				m := humanPost(tid, task, "devel", "anyone?", base.Add(time.Duration(i)*time.Second))
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				posts[task] = m
			}
			// every query, as the msg ids it answers
			type query func() []Queued
			queries := map[string]query{
				"UnheardPosts": func() []Queued {
					q, err := fb.UnheardPosts(ctx, tid, base.Add(-time.Minute), time.Now().UTC(), 20)
					if err != nil {
						t.Fatal(err)
					}
					return q
				},
				"UnansweredPosts": func() []Queued {
					q, err := fb.UnansweredPosts(ctx, tid, base.Add(-time.Minute), time.Now().UTC(), 20)
					if err != nil {
						t.Fatal(err)
					}
					return q
				},
			}
			ids := func(q []Queued) []string {
				out := []string{}
				for _, x := range q {
					out = append(out, x.TaskID)
				}
				slices.Sort(out)
				return out
			}
			both := []string{P, Q}
			slices.Sort(both)
			for qn, q := range queries {
				if got := ids(q()); !slices.Equal(got, both) {
					t.Fatalf("CONTROL %s before the pause: %v, want %v", qn, got, both)
				}
			}
			if _, err := tp.SetTopicPaused(ctx, tid, P, "HUM-10", "", base, true); err != nil {
				t.Fatal(err)
			}
			for qn, q := range queries {
				if got := ids(q()); !slices.Equal(got, []string{Q}) {
					t.Errorf("%s while P is paused: %v, want only Q %s", qn, got, Q)
				}
			}
			// escalated once, long ago, never acted on: re-escalatable
			for _, m := range posts {
				if err := fb.RecordFallback(ctx, FallbackDelivery{TenantID: tid, MsgID: m.MsgID, Channel: "devel", Box: "box-r", Agent: "CLE-9", DeliveredAt: base.Add(time.Minute)}); err != nil {
					t.Fatal(err)
				}
			}
			reesc := func() []string {
				q, err := fb.ReescalatablePosts(ctx, tid, base.Add(-time.Minute), base.Add(time.Hour), time.Now().UTC(), 5, 20)
				if err != nil {
					t.Fatal(err)
				}
				return ids(q)
			}
			if got := reesc(); !slices.Equal(got, []string{Q}) {
				t.Errorf("ReescalatablePosts while P is paused: %v, want only Q %s", got, Q)
			}
			if _, err := tp.SetTopicPaused(ctx, tid, P, "HUM-10", "", base, false); err != nil {
				t.Fatal(err)
			}
			if got := reesc(); !slices.Equal(got, both) {
				t.Errorf("ReescalatablePosts after the resume: %v, want %v", got, both)
			}
		})
	}
}

// TestViewTopicDoorPaused: the topic list row and the door aggregate carry
// the pause in their own read (spec 179 6.1), zero for an unpaused topic;
// on Postgres the fused ViewTopicDoor carries it too.
func TestViewTopicDoorPaused(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tid := newTenant(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			P, Q := uuid4(), uuid4()
			for i, task := range []string{P, Q} {
				m := humanPost(tid, task, ChannelLobby, "subject", now.Add(time.Duration(i-5)*time.Second))
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			at := now.Add(-time.Minute)
			if _, err := s.(TopicPauseStore).SetTopicPaused(ctx, tid, P, "HUM-10", "No need to stand by", at, true); err != nil {
				t.Fatal(err)
			}
			check := func(where string, task string, p TopicPause) {
				t.Helper()
				if task == Q {
					if p.Paused() || p != (TopicPause{}) {
						t.Errorf("%s: unpaused topic carries %+v", where, p)
					}
					return
				}
				if !p.Paused() || p.TaskID != P || p.PausedBy != "HUM-10" || !p.PausedAt.Equal(at) || p.Reason != "No need to stand by" {
					t.Errorf("%s: paused topic carries %+v", where, p)
				}
			}
			rows, err := s.ViewTopics(ctx, tid, TopicQuery{Limit: 10, Now: now})
			if err != nil || len(rows) != 2 {
				t.Fatalf("ViewTopics: %d row(s) %v", len(rows), err)
			}
			for _, r := range rows {
				check("ViewTopics", r.TaskID, r.Pause)
			}
			for _, task := range []string{P, Q} {
				a, err := s.TopicAccess(ctx, tid, task, now)
				if err != nil || !a.Found {
					t.Fatalf("TopicAccess(%s): %+v %v", task, a, err)
				}
				check("TopicAccess", task, a.Pause)
				pg, ok := s.(*Postgres)
				if !ok {
					continue
				}
				a, may, _, err := pg.ViewTopicDoor(ctx, tid, TopicMsgQuery{TaskID: task, Limit: 51, Now: now}, func(TopicAccess) (bool, error) { return true, nil })
				if err != nil || !may {
					t.Fatalf("ViewTopicDoor(%s): %v %v", task, may, err)
				}
				check("ViewTopicDoor", task, a.Pause)
			}
		})
	}
}

// followNums are the numbers of fs, in order.
func followNums(fs []IssueFollow) []int {
	out := []int{}
	for _, f := range fs {
		out = append(out, f.Number)
	}
	return out
}
