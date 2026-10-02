// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Postgres claims, option (b): the message row once, one queue row per
// subscribed group (the shape of today's deliveries table), a consumer claims
// with FOR UPDATE SKIP LOCKED and a 5 s lease (the AckWait of NATS), acks by
// marking the row done. LISTEN/NOTIFY wakes an idle consumer; a 500 ms poll
// catches an expired lease.
type pgqBackend struct{ dsn string }

func (b *pgqBackend) Name() string      { return "pgq" }
func (b *pgqBackend) Container() string { return "spike-pg" }

const pgqSchema = `
DROP TABLE IF EXISTS dq, msgs, subs;
CREATE TABLE subs (subject text NOT NULL, grp text NOT NULL, PRIMARY KEY (subject, grp));
CREATE TABLE msgs (id text PRIMARY KEY, subject text NOT NULL, payload bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE dq (id text NOT NULL REFERENCES msgs(id), grp text NOT NULL, seq bigserial,
  done boolean NOT NULL DEFAULT false, locked_until timestamptz, attempts int NOT NULL DEFAULT 0,
  PRIMARY KEY (id, grp));
CREATE INDEX dq_ready ON dq (grp, seq) WHERE NOT done;`

func (b *pgqBackend) Setup(ctx context.Context, groups map[string][]string, _ int) error {
	conn, err := pgx.Connect(ctx, b.dsn)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, pgqSchema); err != nil {
		return err
	}
	for s, gs := range groups {
		for _, g := range gs {
			if _, err := conn.Exec(ctx, `INSERT INTO subs VALUES ($1, $2)`, s, g); err != nil {
				return err
			}
		}
	}
	return nil
}

type pgqProducer struct{ pool *pgxpool.Pool }

func (b *pgqBackend) Producer(ctx context.Context) (Producer, error) {
	pool, err := pgxpool.New(ctx, b.dsn)
	if err != nil {
		return nil, err
	}
	return &pgqProducer{pool}, nil
}

// Publish is one transaction: the row (idempotent on id), its queue rows,
// and the wake-up, which Postgres sends only on commit.
func (p *pgqProducer) Publish(ctx context.Context, subject, id string, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO msgs (id, subject, payload) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, id, subject, data)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO dq (id, grp) SELECT $1, grp FROM subs WHERE subject = $2`, id, subject); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `SELECT pg_notify('dq', $1)`, subject)
		return err
	})
}

func (p *pgqProducer) Close() { p.pool.Close() }

type pgqConsumer struct {
	b      *pgqBackend
	pool   *pgxpool.Pool
	grp    string
	listen *pgx.Conn
}

func (b *pgqBackend) Consumer(ctx context.Context, _, group, _ string) (Consumer, error) {
	pool, err := pgxpool.New(ctx, b.dsn)
	if err != nil {
		return nil, err
	}
	return &pgqConsumer{b: b, pool: pool, grp: group}, nil
}

const pgqClaim = `
WITH c AS (
  SELECT id FROM dq WHERE grp = $1 AND NOT done AND (locked_until IS NULL OR locked_until < now())
  ORDER BY seq LIMIT 1 FOR UPDATE SKIP LOCKED)
UPDATE dq SET locked_until = now() + interval '5 seconds', attempts = attempts + 1
FROM c, msgs WHERE dq.grp = $1 AND dq.id = c.id AND msgs.id = c.id
RETURNING msgs.payload`

func (c *pgqConsumer) claim(ctx context.Context) (*Msg, error) {
	var data []byte
	err := c.pool.QueryRow(ctx, pgqClaim, c.grp).Scan(&data)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	p, _ := decode(data)
	return &Msg{Data: data, Ack: func(ctx context.Context) error {
		_, err := c.pool.Exec(ctx, `UPDATE dq SET done = true WHERE id = $1 AND grp = $2`, p.ID, c.grp)
		return err
	}}, nil
}

func (c *pgqConsumer) wait(ctx context.Context, d time.Duration) {
	if c.listen == nil || c.listen.IsClosed() {
		conn, err := pgx.Connect(ctx, c.b.dsn)
		if err != nil {
			time.Sleep(d)
			return
		}
		if _, err := conn.Exec(ctx, `LISTEN dq`); err != nil {
			conn.Close(ctx) //nolint:errcheck
			time.Sleep(d)
			return
		}
		c.listen = conn
	}
	wctx, cancel := context.WithTimeout(ctx, d)
	defer cancel()
	if _, err := c.listen.WaitForNotification(wctx); err != nil && wctx.Err() == nil {
		c.listen.Close(ctx) //nolint:errcheck
		c.listen = nil
	}
}

func (c *pgqConsumer) Next(ctx context.Context, wait time.Duration) (*Msg, error) {
	deadline := time.Now().Add(wait)
	for {
		m, err := c.claim(ctx)
		if err != nil {
			// A restart drops pooled connections: retry until the deadline.
			if time.Now().After(deadline) {
				return nil, err
			}
			time.Sleep(200 * time.Millisecond)
			continue
		}
		if m != nil {
			return m, nil
		}
		left := time.Until(deadline)
		if left <= 0 {
			return nil, errIdle
		}
		c.wait(ctx, min(left, 500*time.Millisecond))
	}
}

func (c *pgqConsumer) Ready() bool { return true }

func (c *pgqConsumer) Close() {
	if c.listen != nil {
		c.listen.Close(context.Background()) //nolint:errcheck
	}
	c.pool.Close()
}
