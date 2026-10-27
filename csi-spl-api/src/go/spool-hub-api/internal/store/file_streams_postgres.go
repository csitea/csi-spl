package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The Postgres file streams (file_streams.go, rdb 0237). Every statement
// runs in the box session's tenant scope and names tenant_id in its WHERE;
// the one exception is fileStreamWorkspaces, a count of the workspaces that
// stream (operatorCallers), read inside the announce's own transaction.

const fileStreamCols = `id::text, tenant_id, box_id, stream_key, path, state, reason, first_seen_at, announced_at,
	last_line_at, last_seq, lines_total, lines_dropped, lines_kept, bytes_kept, redactions`

func scanFileStream(r pgx.Row) (FileStream, error) {
	var f FileStream
	var red []byte
	err := r.Scan(&f.ID, &f.Tenant, &f.Box, &f.StreamKey, &f.Path, &f.State, &f.Reason, &f.FirstSeenAt, &f.AnnouncedAt,
		&f.LastLineAt, &f.LastSeq, &f.LinesTotal, &f.LinesDropped, &f.LinesKept, &f.BytesKept, &red)
	if err == nil {
		f.Redactions = map[string]int64{}
		err = json.Unmarshal(red, &f.Redactions)
	}
	return f, err
}

// fileStreamUpsert writes one announced key; a new row takes the id the
// hub minted.
const fileStreamUpsert = `INSERT INTO file_streams (tenant_id, id, box_id, stream_key, path, state, reason, first_seen_at, announced_at)
	VALUES ($1, $2::uuid, $3, $4, $5, $6, $7, $8, $8)
	ON CONFLICT (tenant_id, box_id, stream_key) DO UPDATE SET path = EXCLUDED.path, state = EXCLUDED.state,
		reason = EXCLUDED.reason, announced_at = EXCLUDED.announced_at`

// fileStreamWorkspaces answers whether tenant may stream: it already does,
// or fewer than max workspaces do. A count across workspaces, inside the
// announce's transaction; no row of another workspace leaves it.
func (s *Postgres) fileStreamWorkspaces(ctx context.Context, tx pgx.Tx, tenant string, max int) (bool, error) {
	var mine bool
	var others int
	err := s.asOperatorInTx(ctx, tx, `SELECT coalesce(bool_or(tenant_id = $1), false), count(DISTINCT tenant_id) FILTER (WHERE tenant_id <> $1)
		FROM file_streams WHERE state IN ('following', 'missing')`, []any{tenant}, func(r pgx.Rows) error {
		return r.Scan(&mine, &others)
	})
	return mine || others < max, err
}

// AnnounceFileStreams is FileStreamStore.AnnounceFileStreams.
func (s *Postgres) AnnounceFileStreams(ctx context.Context, tenant, box string, in []wire.FileStreamAnnounced, lim FileStreamLimits, now time.Time) ([]wire.FileStreamAckState, error) {
	lim = lim.Norm()
	var plan []wire.FileStreamAckState
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var one int
		if err := tx.QueryRow(ctx, `SELECT 1 FROM boxes WHERE tenant_id = $1 AND box_id = $2`, tenant, box).Scan(&one); err != nil {
			return err
		}
		ok := true
		if fileStreamAnnounceStreams(in) {
			var err error
			if ok, err = s.fileStreamWorkspaces(ctx, tx, tenant, lim.MaxWorkspaces); err != nil {
				return err
			}
		}
		plan = fileStreamAnnouncePlan(in, lim, ok)
		keys := make([]string, len(plan))
		for i, a := range plan {
			keys[i] = a.StreamKey
			if _, err := tx.Exec(ctx, fileStreamUpsert, tenant, uuid.New(), box, a.StreamKey, in[i].Path, a.State, a.Reason, now); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `UPDATE file_streams SET state = 'gone', reason = ''
			WHERE tenant_id = $1 AND box_id = $2 AND NOT (stream_key = ANY($3)) AND state <> 'gone'`, tenant, box, keys)
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) { // the box has no row in tenant: it never said hello there
		return nil, ErrNotFound
	}
	return plan, err
}

// fileStreamInsert writes the push's new lines from parallel arrays; a seq
// already stored is skipped. It answers the bytes of each row it wrote.
const fileStreamInsert = `INSERT INTO file_stream_lines (tenant_id, stream_id, seq, at, text, marker)
	SELECT $1, $2::uuid, l.seq, l.at, l.text, l.marker
	FROM unnest($3::bigint[], $4::timestamptz[], $5::text[], $6::bool[]) AS l(seq, at, text, marker)
	ON CONFLICT (tenant_id, stream_id, seq) DO NOTHING
	RETURNING octet_length(text), at`

// fileStreamPrune removes tenant's oldest lines, at most 1000 of them a
// statement: the first $2 (the lines over the line cap) and every line whose
// older lines' bytes are still under $3 (the bytes over the byte cap), so
// a byte overshoot takes only as many lines as it must. It takes them off
// their streams' kept counts in the same statement.
const fileStreamPrune = `WITH o AS (
		SELECT at, stream_id, seq, octet_length(text) AS b FROM file_stream_lines WHERE tenant_id = $1
		ORDER BY at, stream_id, seq LIMIT 1000
	), w AS (
		SELECT stream_id, seq, row_number() OVER x AS rn, sum(b) OVER x - b AS before FROM o
		WINDOW x AS (ORDER BY at, stream_id, seq ROWS UNBOUNDED PRECEDING)
	), d AS (
		DELETE FROM file_stream_lines l USING w WHERE l.tenant_id = $1 AND l.stream_id = w.stream_id AND l.seq = w.seq
			AND (w.rn <= $2 OR w.before < $3)
		RETURNING l.stream_id, octet_length(l.text) AS b
	), g AS (
		SELECT stream_id, count(*) AS n, sum(b) AS b FROM d GROUP BY stream_id
	)
	UPDATE file_streams f SET lines_kept = f.lines_kept - g.n, bytes_kept = f.bytes_kept - g.b
	FROM g WHERE f.tenant_id = $1 AND f.id = g.stream_id
	RETURNING g.n, g.b`

// RecordFileStreamLines is FileStreamStore.RecordFileStreamLines.
func (s *Postgres) RecordFileStreamLines(ctx context.Context, tenant, box string, p wire.FileStreamsPushFrame, lim FileStreamLimits, now time.Time) (FileStreamPushResult, error) {
	lim = lim.Norm()
	keep, expired, acked := fileStreamPrepare(p.Lines, now)
	res := FileStreamPushResult{Expired: expired, AckedSeq: acked}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var reason string
		err := tx.QueryRow(ctx, `SELECT id::text, reason FROM file_streams
			WHERE tenant_id = $1 AND box_id = $2 AND stream_key = $3 FOR UPDATE`, tenant, box, p.StreamKey).Scan(&res.StreamID, &reason)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return ErrFileStreamUnknown
		case err != nil:
			return err
		case reason != "":
			return ErrFileStreamRefused
		}
		var bytes int64
		var last *time.Time
		if len(keep) > 0 {
			if res.Inserted, bytes, last, err = s.insertFileStreamLines(ctx, tx, tenant, res.StreamID, keep, lim); err != nil {
				return err
			}
		}
		red := []byte("{}") // a nil map is JSON null, which jsonb_each_text refuses
		if len(p.Redactions) > 0 {
			if red, err = json.Marshal(p.Redactions); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE file_streams SET last_seq = greatest(last_seq, $3), lines_total = lines_total + $4,
			lines_dropped = lines_dropped + $5, lines_kept = lines_kept + $4, bytes_kept = bytes_kept + $6,
			last_line_at = CASE WHEN $7::timestamptz IS NULL THEN last_line_at ELSE greatest(last_line_at, $7) END,
			redactions = (SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) FROM (
				SELECT k, sum(v)::bigint AS v FROM (
					SELECT key AS k, value::bigint AS v FROM jsonb_each_text(redactions)
					UNION ALL SELECT key, value::bigint FROM jsonb_each_text($8::jsonb)) a GROUP BY k) b)
			WHERE tenant_id = $1 AND id = $2::uuid`, tenant, res.StreamID, acked, res.Inserted, p.Dropped, bytes, last, red); err != nil {
			return err
		}
		res.Pruned, err = s.pruneFileStreamsToCaps(ctx, tx, tenant, lim)
		return err
	})
	if err != nil {
		return FileStreamPushResult{}, err
	}
	return res, nil
}

// insertFileStreamLines inserts the lines, then refuses the push when a
// minute of the stream holds more than twice the rate (the caller's
// transaction rolls the insert back). It answers the rows written, their
// bytes and their newest time.
func (s *Postgres) insertFileStreamLines(ctx context.Context, tx pgx.Tx, tenant, stream string, keep []wire.FileStreamLine, lim FileStreamLimits) (int, int64, *time.Time, error) {
	n := len(keep)
	seq, at, text, marker := make([]int64, n), make([]time.Time, n), make([]string, n), make([]bool, n)
	for i, l := range keep {
		seq[i], at[i], text[i], marker[i] = l.Seq, l.At, l.Text, l.Marker
	}
	var rows int
	var bytes int64
	var last *time.Time
	err := eachRow(ctx, tx, fileStreamInsert, []any{tenant, stream, seq, at, text, marker}, func(r pgx.Rows) error {
		var b int64
		var t time.Time
		if err := r.Scan(&b, &t); err != nil {
			return err
		}
		rows, bytes = rows+1, bytes+b
		if last == nil || t.After(*last) {
			last = &t
		}
		return nil
	})
	if err != nil || rows == 0 {
		return rows, bytes, last, err
	}
	from, to := fileStreamWindow(keep)
	per := map[time.Time]int{}
	err = eachRow(ctx, tx, `SELECT date_trunc('minute', at), count(*) FROM file_stream_lines
		WHERE tenant_id = $1 AND stream_id = $2::uuid AND at >= $3 AND at < $4 GROUP BY 1`, []any{tenant, stream, from, to}, func(r pgx.Rows) error {
		var m time.Time
		var c int
		if err := r.Scan(&m, &c); err != nil {
			return err
		}
		per[m.UTC()] = c
		return nil
	})
	if err == nil && fileStreamOverRate(per, lim) {
		err = ErrFileStreamRate
	}
	return rows, bytes, last, err
}

// pruneFileStreamsToCaps removes tenant's oldest lines, a batch at a time,
// until its kept lines and bytes are within lim. Only tenant's rows: the
// statement runs in tenant's scope and names it.
func (s *Postgres) pruneFileStreamsToCaps(ctx context.Context, tx pgx.Tx, tenant string, lim FileStreamLimits) (int, error) {
	pruned := 0
	for {
		var lines, bytes int64
		if err := tx.QueryRow(ctx, `SELECT coalesce(sum(lines_kept), 0)::bigint, coalesce(sum(bytes_kept), 0)::bigint
			FROM file_streams WHERE tenant_id = $1`, tenant).Scan(&lines, &bytes); err != nil {
			return pruned, err
		}
		if lines <= lim.MaxLines && bytes <= lim.MaxBytes {
			return pruned, nil
		}
		overLines, overBytes := max(lines-lim.MaxLines, 0), max(bytes-lim.MaxBytes, 0)
		got := 0
		err := eachRow(ctx, tx, fileStreamPrune, []any{tenant, overLines, overBytes}, func(r pgx.Rows) error {
			var n, b int64
			if err := r.Scan(&n, &b); err != nil {
				return err
			}
			got += int(n)
			return nil
		})
		if err != nil || got == 0 {
			return pruned, err
		}
		pruned += got
	}
}

// ListFileStreams is FileStreamStore.ListFileStreams.
func (s *Postgres) ListFileStreams(ctx context.Context, tenant string) ([]FileStream, error) {
	out := []FileStream{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT `+fileStreamCols+` FROM file_streams WHERE tenant_id = $1 ORDER BY box_id, stream_key`,
			[]any{tenant}, func(r pgx.Rows) error {
				f, err := scanFileStream(r)
				out = append(out, f)
				return err
			})
	})
	return out, err
}

// FileStreamLinesAfter is FileStreamStore.FileStreamLinesAfter.
func (s *Postgres) FileStreamLinesAfter(ctx context.Context, tenant, id string, after int64, limit int) ([]FileStreamLine, error) {
	if !uuidRe.MatchString(id) {
		return nil, ErrNotFound
	}
	if limit <= 0 {
		limit = wire.FileStreamLinesPerPush
	}
	out := []FileStreamLine{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var one int
		if err := tx.QueryRow(ctx, `SELECT 1 FROM file_streams WHERE tenant_id = $1 AND id = $2::uuid`, tenant, id).Scan(&one); err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT stream_id::text, seq, at, text, marker FROM file_stream_lines
			WHERE tenant_id = $1 AND stream_id = $2::uuid AND seq > $3 ORDER BY seq LIMIT $4`, []any{tenant, id, after, limit},
			func(r pgx.Rows) error {
				var l FileStreamLine
				err := r.Scan(&l.StreamID, &l.Seq, &l.At, &l.Text, &l.Marker)
				out = append(out, l)
				return err
			})
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return out, err
}
