package store

import (
	"encoding/json"
	"strings"
	"time"
)

// The hub's post-minute upsert (spec 107 v1.0, T005; section 1.2). When the
// store writes a post, an edit or a reaction by a member (a HUM-*; a post
// also from box-wui), it upserts that minute into hours_minutes with src
// post and target t:<task_id>, in the same transaction as the write: the
// write and its minute land together or not at all. A post minute overrides
// a tab minute; a tab write never overrides a post (spec 1.3, the
// hoursMinutesUpsert rule).
//
//   - post:     received_at's minute, the message's task, only when this call
//     stored the row (a resend writes nothing more);
//   - edit:     edited_at's minute, the edited message's task;
//   - reaction: the reaction's minute, the message's task, only when it was
//     added (adding one already there writes nothing).
//
// The zone (spec 1.6): the member's time_zone in this workspace, else the
// zone of the member's latest tab minute (the WUI's last tab batch), else
// the workspace's hours.tz, else UTC.
//
// Privacy (spec 1.7): with hours.go this file pair is the only one naming the
// table; nothing here reads a minute back out.

// hoursPostMember reports whether an actor's write is counted: a member
// (HUM-*), never an agent, a guest or a box.
func hoursPostMember(actor string) bool { return strings.HasPrefix(actor, "HUM-") }

// hoursPostOfMessage reports whether a stored message is a member's post.
func hoursPostOfMessage(m Message) bool {
	return m.FromBox == wuiBox && hoursPostMember(m.FromID) && m.TaskID != ""
}

// hoursPostLocked is Memory's upsert of one post minute, under s.mu. A
// tenant this Memory does not know (the FK of rdb 0151) writes nothing.
func (s *Memory) hoursPostLocked(tenant, member, taskID string, at time.Time) {
	if _, ok := s.tenants[tenant]; !ok || taskID == "" {
		return
	}
	s.hrs.init()
	k := [2]string{tenant, member}
	at = at.UTC().Truncate(time.Minute)
	if old, ok := s.hrs.minutes[k][at.Unix()]; ok && old.Src != HoursSrcTab {
		return // a post minute stays (spec 1.3)
	}
	tz := s.hoursPostZoneLocked(tenant, member)
	if s.hrs.minutes[k] == nil {
		s.hrs.minutes[k] = map[int64]HoursMinute{}
	}
	s.hrs.minutes[k][at.Unix()] = HoursMinute{At: at, Target: "t:" + taskID, Src: HoursSrcPost, TZ: tz}
}

// hoursPostZoneLocked is the zone order of spec 1.6 on Memory.
func (s *Memory) hoursPostZoneLocked(tenant, member string) string {
	if m, ok := s.hum.members[[2]string{tenant, member}]; ok {
		var z string
		if raw, ok := m.settings["time_zone"]; ok && json.Unmarshal(raw, &z) == nil && z != "" {
			return z
		}
	}
	var last HoursMinute
	for _, m := range s.hrs.minutes[[2]string{tenant, member}] {
		if m.Src == HoursSrcTab && m.At.After(last.At) {
			last = m
		}
	}
	if last.TZ != "" {
		return last.TZ
	}
	if z := s.tenants[tenant].Settings.String(HoursKeyTZ); z != "" {
		return z
	}
	return "UTC"
}
