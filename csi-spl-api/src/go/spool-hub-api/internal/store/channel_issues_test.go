package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-68 (specs/039 §3.4, rdb 0050): #tasks is gone and issue discussions
// live on the reserved id ChannelIssues. On memory and, with
// SPOOL_TEST_PG_DSN, Postgres: no default #tasks, the issue channel is known
// (a browser posts and subscribes to it) and readable by every member, yet it
// is never listed and can never be created; the retired #tasks stays readable
// for the rows 0050 has not moved yet and can never be created again.
func TestIssueChannelReplacesTasks(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)

			if IsDefaultChannel(ChannelTasks) {
				t.Fatal("#tasks is still a default channel")
			}
			if ok, err := s.ChannelKnown(ctx, tid, ChannelIssues); err != nil || !ok {
				t.Fatalf("issues known: %v %v", ok, err)
			}
			// CONTROL: an unknown id is still unknown, so "known" above is the rule.
			if ok, _ := s.ChannelKnown(ctx, tid, "nosuch"); ok {
				t.Fatal("nosuch known")
			}
			for _, id := range []string{ChannelIssues, ChannelTasks, ChannelLobby} {
				err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: id, Name: id, CreatedBy: "HUM-1", CreatedAt: now})
				if !errors.Is(err, ErrConflict) {
					t.Fatalf("create #%s: %v, want conflict", id, err)
				}
			}
			if !ChannelPublic(ChannelIssues) || !ChannelPublic(ChannelTasks) || ChannelPublic("releases") {
				t.Fatal("public: issues and the retired tasks yes, a created channel no")
			}

			task := uuid4()
			issue := msgFor(tid, task, "box-wui", now, now.Add(-2*time.Minute), "i1")
			issue.Channel, issue.FromID = ChannelIssues, "HUM-1"
			old := msgFor(tid, uuid4(), "box-wui", now, now.Add(-time.Minute), "t1")
			old.Channel, old.FromID = ChannelTasks, "HUM-1"
			for _, m := range []Message{issue, old} {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}

			stats, err := s.ViewChannelStats(ctx, tid, now, nil, "", "")
			if err != nil {
				t.Fatal(err)
			}
			var ids []string
			for _, st := range stats {
				ids = append(ids, st.ChannelID)
				if ChannelHidden(st.ChannelID) {
					t.Fatalf("#%s listed: %+v", st.ChannelID, st)
				}
			}
			if len(ids) != len(DefaultChannels) {
				t.Fatalf("channels %v, want the %d defaults", ids, len(DefaultChannels))
			}

			// A member of no created channel still reads the issue thread.
			got, err := s.ViewTopic(ctx, tid, TopicMsgQuery{Reader: "HUM-9", TaskID: task, Limit: 10, Now: now})
			if err != nil || len(got) != 1 {
				t.Fatalf("issue thread for HUM-9: %v %+v", err, got)
			}
		})
	}
}
