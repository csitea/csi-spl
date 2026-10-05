package store

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
)

// The 3-hour stay (specs/077 FR-005, T009). Admission writes access_until =
// admitted + the stay (seatDemoTx); from then on MemberRole refuses the seat
// and the hub door answers 401 demo_expired (DemoSeatEnded). Every 5 minutes
// the hub's demo sweep (SweepDemo) drops each ended seat and the visitor's
// personal data, so the visitor leaves nothing behind but their posts, which
// stay until the nightly wipe (do_spl_demo_wipe, Q10). The rows it drops:
//
//   - tenant_memberships: the ended demo_user seat in the demo workspace;
//   - in the demo workspace, the visitor's read_marks, flow_watches,
//     message_reactions, channel_humans and member_activity (sign-in audit:
//     ip, user agent) rows;
//   - humans, when the visitor then holds no membership anywhere and is not
//     technical: the name, the email and the settings, and by cascade
//     human_identities (the IdP link), human_keys, human_events and
//     member_clones. A real member of another workspace keeps it (spec 3.8;
//     admission never seats one, this is the second fence).
//
// The hub then deletes avatars/<file_id> when no remaining human carries the
// same picture; the tenant copy t/<demo>/files/<file_id> leaves with the file
// sweep once the roster no longer names it.

// DemoSweep is what one SweepDemo dropped.
type DemoSweep struct {
	Ended   []string // HUM-* whose demo seat ended and was dropped
	Humans  int      // humans rows dropped (with their identities, keys, events)
	Rows    int      // demo-workspace rows dropped: reads, watches, reactions, channel seats, activity
	Avatars []string // avatar file_ids no remaining human carries
}

// DemoStays is implemented by Memory and Postgres.
type DemoStays interface {
	// SweepDemo drops every demo_user seat of tenant ended at now and the
	// visitor's personal data (see above). A seat admitted before T009
	// (access_until NULL) is first given admitted + maxStay, so no demo seat
	// is ever unlimited.
	SweepDemo(ctx context.Context, tenant string, maxStay time.Duration, now time.Time) (DemoSweep, error)
	// DemoSeatEnded reports whether hum's demo_user seat in tenant ended at
	// now, or hum was already swept (no humans row): the door's 401
	// demo_expired rather than a plain refusal.
	DemoSeatEnded(ctx context.Context, tenant, hum string, now time.Time) (bool, error)
}

var (
	_ DemoStays = (*Memory)(nil)
	_ DemoStays = (*Postgres)(nil)
)

func (s *Memory) SweepDemo(_ context.Context, tenant string, maxStay time.Duration, now time.Time) (DemoSweep, error) {
	var out DemoSweep
	if err := checkTenant(tenant); err != nil {
		return out, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	for k, m := range h.members {
		if k[0] != tenant || m.role != rbac.DemoUser {
			continue
		}
		if m.accessUntil.IsZero() {
			m.accessUntil = m.since.Add(maxStay).UTC()
			h.members[k] = m
		}
		if lapsed(m.accessUntil, now) {
			delete(h.members, k)
			out.Ended = append(out.Ended, k[1])
		}
	}
	for _, hum := range out.Ended {
		out.Rows += s.memDropDemoRows(tenant, hum)
		if av, ok := s.memDropHuman(hum); ok {
			out.Humans++
			if av != "" {
				out.Avatars = append(out.Avatars, av)
			}
		}
	}
	return out, nil
}

// memDropDemoRows deletes hum's reads, watches, reactions and channel seats
// in tenant; the caller holds s.mu.
func (s *Memory) memDropDemoRows(tenant, hum string) int {
	n := 0
	for k := range s.readMarks {
		if k[0] == tenant && k[1] == hum {
			delete(s.readMarks, k)
			n++
		}
	}
	for k := range s.flowWatches {
		if k[0] == tenant && k[2] == hum {
			delete(s.flowWatches, k)
			n++
		}
	}
	for k, rs := range s.reactions {
		if k[0] != tenant {
			continue
		}
		kept := rs[:0]
		for _, r := range rs {
			if r.actor != hum {
				kept = append(kept, r)
			}
		}
		n += len(rs) - len(kept)
		s.reactions[k] = kept
	}
	for k, hs := range s.ch.humans {
		if _, ok := hs[hum]; ok && k[0] == tenant {
			delete(hs, hum)
			n++
		}
	}
	return n
}

// memDropHuman deletes hum and its identities when it holds no membership
// left; the avatar is returned when no other human carries it. The caller
// holds s.mu.
func (s *Memory) memDropHuman(hum string) (string, bool) {
	h := &s.hum
	for k := range h.members {
		if k[1] == hum {
			return "", false
		}
	}
	hm, ok := h.humans[hum]
	if !ok {
		return "", false
	}
	delete(h.humans, hum)
	for k, i := range h.identities {
		if i.human == hum {
			delete(h.identities, k)
		}
	}
	for _, o := range h.humans {
		if hm.avatar != "" && o.avatar == hm.avatar {
			return "", true
		}
	}
	return hm.avatar, true
}

func (s *Memory) DemoSeatEnded(_ context.Context, tenant, hum string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, ok := s.hum.humans[hum]; !ok {
		return true, nil
	}
	m, ok := s.hum.members[[2]string{tenant, hum}]
	return ok && m.role == rbac.DemoUser && lapsed(m.accessUntil, now), nil
}

// pgDemoRows are the demo-workspace rows of the ended visitors ($2) the
// sweep drops, in tenant $1.
var pgDemoRows = []string{
	`DELETE FROM read_marks WHERE tenant_id = $1 AND member_id = ANY($2::text[])`,
	`DELETE FROM flow_watches WHERE tenant_id = $1 AND member_id = ANY($2::text[])`,
	`DELETE FROM message_reactions WHERE tenant_id = $1 AND actor = ANY($2::text[])`,
	`DELETE FROM channel_humans WHERE tenant_id = $1 AND human_id = ANY($2::text[])`,
	`DELETE FROM member_activity WHERE tenant_id = $1
		AND (subject_hum = ANY($2::text[]) OR actor_hum = ANY($2::text[]))`,
}

// SweepDemo runs in the operator scope (TestOperatorScopeCallers): humans are
// hub-wide, and "no membership left anywhere" must read every tenant in the
// same transaction that deletes the human.
func (s *Postgres) SweepDemo(ctx context.Context, tenant string, maxStay time.Duration, now time.Time) (DemoSweep, error) {
	var out DemoSweep
	if err := checkTenant(tenant); err != nil {
		return out, err
	}
	if !s.hasAccessUntil(ctx) {
		return out, ErrAccessUntilUnavailable
	}
	defer s.hot.forget() // the door cache must not outlive a dropped seat
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		out = DemoSweep{}
		if _, err := tx.Exec(ctx, `UPDATE tenant_memberships
			SET access_until = created_at + make_interval(secs => $3)
			WHERE tenant_id = $1 AND role = $2 AND access_until IS NULL`,
			tenant, rbac.DemoUser, maxStay.Seconds()); err != nil {
			return err
		}
		err := eachRow(ctx, tx, `DELETE FROM tenant_memberships
			WHERE tenant_id = $1 AND role = $2 AND access_until <= $3 RETURNING human_id`,
			[]any{tenant, rbac.DemoUser, now}, func(rows pgx.Rows) error {
				var hum string
				err := rows.Scan(&hum)
				out.Ended = append(out.Ended, hum)
				return err
			})
		if err != nil || len(out.Ended) == 0 {
			return err
		}
		return pgDropDemoVisitors(ctx, tx, tenant, &out)
	})
	return out, err
}

// pgDropDemoVisitors drops out.Ended's demo-workspace rows, then each human
// that holds no membership left, and lists the avatars nobody else carries.
func pgDropDemoVisitors(ctx context.Context, tx pgx.Tx, tenant string, out *DemoSweep) error {
	for _, q := range pgDemoRows {
		tag, err := tx.Exec(ctx, q, tenant, out.Ended)
		if err != nil {
			return err
		}
		out.Rows += int(tag.RowsAffected())
	}
	var avatars []string
	err := eachRow(ctx, tx, `DELETE FROM humans h WHERE h.human_id = ANY($1::text[]) AND NOT h.technical
		AND NOT EXISTS (SELECT 1 FROM tenant_memberships m WHERE m.human_id = h.human_id)
		RETURNING coalesce(h.avatar_file_id, '')`, []any{out.Ended}, func(rows pgx.Rows) error {
		var av string
		err := rows.Scan(&av)
		out.Humans++
		avatars = append(avatars, av)
		return err
	})
	if err != nil {
		return err
	}
	// Read after the delete: a picture another human still carries stays.
	return eachRow(ctx, tx, `SELECT DISTINCT a FROM unnest($1::text[]) a
		WHERE a <> '' AND NOT EXISTS (SELECT 1 FROM humans WHERE avatar_file_id = a)`,
		[]any{avatars}, func(rows pgx.Rows) error {
			var av string
			err := rows.Scan(&av)
			out.Avatars = append(out.Avatars, av)
			return err
		})
}

func (s *Postgres) DemoSeatEnded(ctx context.Context, tenant, hum string, now time.Time) (bool, error) {
	if !s.hasAccessUntil(ctx) {
		return false, nil
	}
	var ended bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM tenant_memberships
			WHERE tenant_id = $1 AND human_id = $2 AND role = $3 AND access_until <= $4)
		OR NOT EXISTS (SELECT 1 FROM humans WHERE human_id = $2)`,
		[]any{tenant, hum, rbac.DemoUser, now}, &ended)
	return ended, err
}
