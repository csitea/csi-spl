package store

import (
	"context"
	"fmt"
	"time"
)

// The Postgres side of hours_post.go. Each upsert rides the write it counts:
// a CTE of the message insert and of the reaction insert, one more
// statement in the edit's transaction. One indexed upsert per write, never
// another round trip on its own.

// hasHoursMinutes says whether rdb 0151's hours_minutes is there. The hub may
// roll before the migration reaches its database (a trunk push deploys dev
// and prd together): until then a post writes no minute and never fails.
func (s *Postgres) hasHoursMinutes(ctx context.Context) bool {
	return s.hoursTab.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT to_regclass('hours_minutes') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}

// hoursPostZoneSQL is the zone order of spec 1.6 for tenant t, member m (two
// parameter references): the member's time_zone, the latest tab minute's
// zone, the workspace's hours.tz, UTC.
func hoursPostZoneSQL(t, m string) string {
	return fmt.Sprintf(`COALESCE(
		(SELECT NULLIF(ms.settings->>'time_zone', '') FROM tenant_memberships ms
			WHERE ms.tenant_id = %[1]s AND ms.human_id = %[2]s),
		(SELECT h.tz FROM hours_minutes h WHERE h.tenant_id = %[1]s AND h.member_id = %[2]s AND h.src = 'tab'
			ORDER BY h.minute DESC LIMIT 1),
		(SELECT NULLIF(tn.settings->>'%[3]s', '') FROM tenants tn WHERE tn.tenant_id = %[1]s),
		'UTC')`, t, m, HoursKeyTZ)
}

// hoursPostConflict is hoursMinutesUpsert's post-over-tab rule.
const hoursPostConflict = `
		ON CONFLICT (tenant_id, member_id, minute) DO UPDATE
		SET target = EXCLUDED.target, src = EXCLUDED.src, tz = EXCLUDED.tz
		WHERE hours_minutes.src = 'tab'`

// hoursPostCTE is the minute of a stored message as a CTE of insertMessageSQL:
// $1 tenant, $3 task, $7 from_id, $16 received_at; only when ins stored it.
var hoursPostCTE = `,
	hrs AS (INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz)
		SELECT $1, $7, date_trunc('minute', $16::timestamptz, 'UTC'), 't:' || $3::text, 'post', ` +
	hoursPostZoneSQL("$1", "$7::text") + `
		FROM ins` + hoursPostConflict + `)`

var (
	insertMessageOnlyHours = fmt.Sprintf(insertMessageSQL, flowInsertCTE(23)+hoursPostCTE)
	insertMessageSentHours = fmt.Sprintf(insertMessageSQL, insertMessageSentDel+flowInsertCTE(24)+hoursPostCTE)
)

// insertMessageStmt is insertMessageArgs plus, for a member's post on a
// database that has the table, the minute's CTE.
func (s *Postgres) insertMessageStmt(ctx context.Context, m Message, sentExpires time.Time) (string, []any) {
	sql, args := insertMessageArgs(m, sentExpires)
	if !hoursPostOfMessage(m) || !s.hasHoursMinutes(ctx) {
		return sql, args
	}
	if sentExpires.IsZero() {
		return insertMessageOnlyHours, args
	}
	return insertMessageSentHours, args
}

// hoursEditUpsert is an edit's minute, inside the edit's transaction: $1
// tenant, $2 member, $3 edited_at, $4 msg_id.
var hoursEditUpsert = `INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz)
	SELECT $1, $2, date_trunc('minute', $3::timestamptz, 'UTC'), 't:' || m.task_id::text, 'post', ` +
	hoursPostZoneSQL("$1", "$2::text") + `
	FROM messages m WHERE m.tenant_id = $1 AND m.msg_id = $4` + hoursPostConflict

// hoursReactionCTE is a reaction's minute as a CTE of AddReaction's
// statement: $1 tenant, $3 actor, $5 now; only when ins added it.
var hoursReactionCTE = `,
		hrs AS (INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz)
			SELECT $1, $3, date_trunc('minute', $5::timestamptz, 'UTC'), 't:' || m.task_id::text, 'post', ` +
	hoursPostZoneSQL("$1", "$3::text") + `
			FROM m WHERE EXISTS (SELECT 1 FROM ins)` + hoursPostConflict + `)`
