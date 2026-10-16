package hub

import (
	"context"
	"fmt"
	"runtime/debug"
	"time"

	"github.com/rs/zerolog"
)

// The loop supervisor (SPL-2128, robustness gap 7). The hub's background
// loops (sweeper, relay, wake, blocker issues, marketing share) used to start
// as bare goroutines: one panic in a tick ended the whole process, every
// socket and request with it. Supervise runs a loop, recovers its panic, logs
// it and starts the loop again after a backoff, so only that loop pauses.

const (
	loopBackoffMin = time.Second
	loopBackoffMax = time.Minute
)

// LoopPanicMsg is the ERROR line a recovered loop panic writes: the alert
// hook. Its fields: loop, panic, stack, restarts, retry_in.
const LoopPanicMsg = "hub loop panicked; restarting"

// Supervise runs run until ctx ends. A panic in run is recovered, logged as
// one ERROR line (LoopPanicMsg) with the loop name and stack, counted, and
// run starts again after a backoff that doubles from 1 s to 1 min (and
// starts over once a run outlived the maximum). A run that returns without
// a panic is done: a loop that is off (an interval <= 0) returns at once and
// is not restarted. It returns the number of restarts.
func Supervise(ctx context.Context, log zerolog.Logger, name string, run func(context.Context)) int {
	return supervise(ctx, log, name, run, loopBackoffMin, loopBackoffMax)
}

func supervise(ctx context.Context, log zerolog.Logger, name string, run func(context.Context), lo, hi time.Duration) int {
	restarts := 0
	backoff := lo
	for ctx.Err() == nil {
		start := time.Now()
		rec, stack := runOnce(ctx, run)
		if rec == nil || ctx.Err() != nil {
			return restarts
		}
		if time.Since(start) > hi {
			backoff = lo
		}
		restarts++
		log.Error().Str("loop", name).Str("panic", fmt.Sprint(rec)).Str("stack", stack).
			Int("restarts", restarts).Dur("retry_in", backoff).Msg(LoopPanicMsg)
		t := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			t.Stop()
			return restarts
		case <-t.C:
		}
		backoff = nextBackoff(backoff, hi)
	}
	return restarts
}

// runOnce calls run and returns the value it panicked with (nil when it
// returned) and that panic's stack.
func runOnce(ctx context.Context, run func(context.Context)) (rec any, stack string) {
	defer func() {
		if rec = recover(); rec != nil {
			stack = string(debug.Stack())
		}
	}()
	run(ctx)
	return nil, ""
}

func nextBackoff(d, hi time.Duration) time.Duration {
	if d *= 2; d > hi {
		return hi
	}
	return d
}
