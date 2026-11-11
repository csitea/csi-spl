package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-5284 (spec 041 archive-releases-work.md): an issue follows its
// discussion. Archive closes the open issues the topic links (diss, the
// previous status kept); unarchive puts each back unless it was changed by
// hand in between; delete soft-deletes them. Any ONE linked discussion
// decides (owner poll 063a4bdd, 1 B). Done, qas and epics are left alone.
func TestIssueFollowsDiscussion(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			is := s.(Issues)
			card := func(task string, n int) Message {
				t.Helper()
				m := msgFor(tid, task, "box-b", now.Add(time.Duration(n)*time.Second), now, `{"n":"`+uuid4()+`"}`)
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			T, U := uuid4(), uuid4()
			cT, cU := card(T, 0), card(U, 1)
			mk := func(title, kind, status string, tasks ...string) int {
				t.Helper()
				i, err := is.CreateIssue(ctx, Issue{TenantID: tid, Title: title, Kind: kind, TaskID: uuid4(), Discussions: tasks, CreatedBy: "HUM-1"}, now)
				if err != nil {
					t.Fatal(err)
				}
				if status != "" && status != i.Status {
					st := status
					if _, err := is.UpdateIssue(ctx, tid, i.Number, IssuePatch{Status: &st}, "HUM-1", now); err != nil {
						t.Fatal(err)
					}
				}
				return i.Number
			}
			a := mk("todo on T", "", IssueTodo, T)
			b := mk("wip on T and U", "", IssueWIP, T, U)
			done := mk("done on T", "", IssueDone, T)
			qas := mk("qas on T", "", IssueQAS, T)
			epic := mk("epic on T", IssueKindEpic, IssueWIP, T)
			f := mk("eval on U", "", IssueEval, U)
			status := func(n int) string {
				t.Helper()
				i, err := is.GetIssue(ctx, tid, n)
				if err != nil {
					t.Fatalf("issue %d: %v", n, err)
				}
				return i.Status
			}
			nums := func(fs []IssueFollow) []int {
				out := []int{}
				for _, x := range fs {
					out = append(out, x.Number)
				}
				return out
			}
			same := func(got, want []int) bool {
				if len(got) != len(want) {
					return false
				}
				for i := range got {
					if got[i] != want[i] {
						return false
					}
				}
				return true
			}

			// archive T: a and b close (b by T alone, 1 B); the rest stay.
			st, err := s.SetArchived(ctx, tid, cT.MsgID, "HUM-1", now.Add(time.Minute), true)
			if err != nil {
				t.Fatal(err)
			}
			if !same(nums(st.Followed), []int{a, b}) {
				t.Fatalf("archive followed %v, want [%d %d]", nums(st.Followed), a, b)
			}
			for _, x := range st.Followed {
				if x.TaskID != T || x.To != IssueDiss || x.Op != IssueFollowArchive {
					t.Errorf("archive follow %+v", x)
				}
			}
			if status(a) != IssueDiss || status(b) != IssueDiss {
				t.Fatalf("after archive a=%s b=%s, want diss", status(a), status(b))
			}
			for n, want := range map[int]string{done: IssueDone, qas: IssueQAS, epic: IssueWIP, f: IssueEval} {
				if got := status(n); got != want {
					t.Errorf("issue %d is %s after the archive, want %s (untouched)", n, got, want)
				}
			}

			// a is changed by hand while T is archived: the unarchive leaves it.
			wip := IssueWIP
			if _, err := is.UpdateIssue(ctx, tid, a, IssuePatch{Status: &wip}, "HUM-2", now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			if _, err := is.UpdateIssue(ctx, tid, a, IssuePatch{Status: func() *string { d := IssueDiss; return &d }()}, "HUM-2", now.Add(3*time.Minute)); err != nil {
				t.Fatal(err)
			}
			st, err = s.SetArchived(ctx, tid, cT.MsgID, "HUM-1", now.Add(4*time.Minute), false)
			if err != nil {
				t.Fatal(err)
			}
			if !same(nums(st.Followed), []int{b}) {
				t.Fatalf("unarchive followed %v, want [%d] (a was changed by hand)", nums(st.Followed), b)
			}
			if st.Followed[0].From != IssueDiss || st.Followed[0].To != IssueWIP {
				t.Errorf("unarchive follow %+v, want diss -> wip", st.Followed[0])
			}
			if status(a) != IssueDiss || status(b) != IssueWIP {
				t.Fatalf("after unarchive a=%s (hand-set diss stays) b=%s (want wip)", status(a), status(b))
			}
			// a second unarchive reopens nothing: the record is gone.
			if st, err = s.SetArchived(ctx, tid, cT.MsgID, "HUM-1", now.Add(5*time.Minute), false); err != nil || len(st.Followed) != 0 {
				t.Fatalf("second unarchive: %v, followed %v", err, nums(st.Followed))
			}

			// delete U: its open issues (b, f) are soft-deleted; a stays.
			set, err := s.DeleteTopic(ctx, tid, cU.MsgID, U, "HUM-1", now.Add(6*time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			if !same(nums(set.Followed), []int{b, f}) {
				t.Fatalf("delete followed %v, want [%d %d]", nums(set.Followed), b, f)
			}
			for _, n := range []int{b, f} {
				if _, err := is.GetIssue(ctx, tid, n); !errors.Is(err, ErrNotFound) {
					t.Errorf("issue %d after the delete: %v, want ErrNotFound", n, err)
				}
			}
			if status(a) != IssueDiss || status(done) != IssueDone {
				t.Errorf("a=%s done=%s after deleting U, want untouched", status(a), status(done))
			}
		})
	}
}

// SPL-5284: a channel archive closes the open issues of its topics and its
// unarchive reopens them; a channel delete soft-deletes them.
func TestIssueFollowsChannel(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			is := s.(Issues)
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "closed", Name: "closed", CreatedBy: "HUM-2", CreatedAt: now}); err != nil {
				t.Fatal(err)
			}
			T := uuid4()
			m := msgFor(tid, T, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
			m.Channel = "closed"
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			i, err := is.CreateIssue(ctx, Issue{TenantID: tid, Title: "in the channel", TaskID: uuid4(), Discussions: []string{T}, CreatedBy: "HUM-2"}, now)
			if err != nil {
				t.Fatal(err)
			}
			wip := IssueWIP
			if _, err := is.UpdateIssue(ctx, tid, i.Number, IssuePatch{Status: &wip}, "HUM-2", now); err != nil {
				t.Fatal(err)
			}
			status := func() string {
				t.Helper()
				g, err := is.GetIssue(ctx, tid, i.Number)
				if err != nil {
					t.Fatal(err)
				}
				return g.Status
			}
			// R7 c-574 W1: each call answers what it did, for the hub's frames.
			one := func(what string, fs []IssueFollow, op, from, to string) {
				t.Helper()
				if len(fs) != 1 || fs[0].Number != i.Number || fs[0].TaskID != T || fs[0].Op != op || fs[0].From != from || fs[0].To != to {
					t.Fatalf("%s answered %+v, want one %s of #%d %s->%s", what, fs, op, i.Number, from, to)
				}
			}
			fs, err := s.ArchiveChannel(ctx, tid, "closed", "HUM-2", now.Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			one("archive", fs, IssueFollowArchive, IssueWIP, IssueDiss)
			if got := status(); got != IssueDiss {
				t.Fatalf("after the channel archive: %s, want diss", got)
			}
			if fs, err = s.UnarchiveChannel(ctx, tid, "closed", "HUM-1"); err != nil {
				t.Fatal(err)
			}
			one("unarchive", fs, "unarchive", IssueDiss, IssueWIP)
			if got := status(); got != IssueWIP {
				t.Fatalf("after the channel unarchive: %s, want wip", got)
			}
			if fs, err = s.DeleteChannel(ctx, tid, "closed", "HUM-2", now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			one("delete", fs, IssueFollowDelete, IssueWIP, "")
			if _, err := is.GetIssue(ctx, tid, i.Number); !errors.Is(err, ErrNotFound) {
				t.Fatalf("after the channel delete: %v, want ErrNotFound", err)
			}
		})
	}
}
