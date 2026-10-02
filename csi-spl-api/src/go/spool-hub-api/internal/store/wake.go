package store

import (
	"context"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5"
)

// Spec 059 §11 S1: the wake-up between hub processes, the one Kafka property
// the Postgres log lacked (a consumer is told the moment a record lands
// instead of polling). Enqueue announces (tenant, box) when its row commits;
// every hub process listens and pushes the queued rows of the box sockets it
// holds. The relay poll (hub/relay.go) stays as the backstop for a wake-up
// lost while a listener reconnects.

// WakeChannel is the Postgres NOTIFY channel; the payload is "<tenant>|<box>".
const WakeChannel = "spool_wake"

// Waker is implemented by stores that can announce a newly queued delivery.
type Waker interface {
	// ListenWake calls fn for every (tenant, box) that gets a queued row,
	// until ctx ends (nil) or the listen connection fails (the error; the
	// caller reconnects). fn must not block.
	ListenWake(ctx context.Context, fn func(tenant, box string)) error
}

// memWake fans a wake-up out to the in-process listeners of a Memory store
// (tests and lde run two hub servers on one Memory store as two "processes").
type memWake struct {
	mu   sync.Mutex
	next int
	subs map[int]memWakeSub
}

// memWakeSub is one listener: box wake-ups and (S3) stored messages; nil = not asked.
type memWakeSub struct {
	box, wui func(tenant, key string)
}

func (w *memWake) notify(tenant, box string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, sub := range w.subs {
		if sub.box != nil {
			go sub.box(tenant, box)
		}
	}
}

// notifyWUI announces a newly stored message (spec 059 S3).
func (w *memWake) notifyWUI(tenant, msgID string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, sub := range w.subs {
		if sub.wui != nil {
			go sub.wui(tenant, msgID)
		}
	}
}

func (s *Memory) ListenWake(ctx context.Context, fn func(tenant, box string)) error {
	return s.ListenWakes(ctx, fn, nil)
}

// ListenWakes: see WUIWaker.
func (s *Memory) ListenWakes(ctx context.Context, box func(tenant, box string), wui func(tenant, msgID string)) error {
	w := &s.wake
	w.mu.Lock()
	if w.subs == nil {
		w.subs = map[int]memWakeSub{}
	}
	id := w.next
	w.next++
	w.subs[id] = memWakeSub{box: box, wui: wui}
	w.mu.Unlock()
	<-ctx.Done()
	w.mu.Lock()
	delete(w.subs, id)
	w.mu.Unlock()
	return nil
}

// ListenWake holds ONE extra connection outside the pool (pool 8 + 1 per hub
// process, of max_connections 25), so a burst of queries never starves the
// listener and the listener never takes a query slot.
func (s *Postgres) ListenWake(ctx context.Context, fn func(tenant, box string)) error {
	return s.ListenWakes(ctx, fn, nil)
}

// ListenWakes listens on both channels over that one connection (S3 adds no
// connection); a nil fn leaves its channel unlistened.
func (s *Postgres) ListenWakes(ctx context.Context, box func(tenant, box string), wui func(tenant, msgID string)) error {
	conn, err := pgx.ConnectConfig(ctx, s.pool.Config().ConnConfig.Copy())
	if err != nil {
		return err
	}
	defer conn.Close(context.Background()) //nolint:errcheck
	fns := map[string]func(string, string){WakeChannel: box, WUIWakeChannel: wui}
	for ch, fn := range fns {
		if fn == nil {
			continue
		}
		if _, err := conn.Exec(ctx, "LISTEN "+ch); err != nil {
			return err
		}
	}
	for {
		n, err := conn.WaitForNotification(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		fn := fns[n.Channel]
		if tenant, key, ok := strings.Cut(n.Payload, "|"); ok && fn != nil {
			fn(tenant, key)
		}
	}
}
