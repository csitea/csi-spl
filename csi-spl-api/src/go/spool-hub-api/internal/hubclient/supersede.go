package hubclient

import (
	"context"
	"time"
)

// A role=box hello evicts the box's previous session with 4409 (last hello
// wins), and the hub cannot tell who sent it: a one-shot `spool hub-sync`
// (the Connect an Agent help, section 6, suggests one) and a second
// `spool hub-run` on the same box send the same hello. Before SPL-2712 the
// daemon exited on every 4409, so one hand-run hub-sync took a live box
// offline until someone restarted hub-run (lane c-317, SPL-2698).
//
// The daemon tells the two apart by what happens after it comes back:
//
//   - First 4409: it yields for SupersedeYield, long enough for a one-shot
//     sync to finish its exchange and close, then says hello again.
//   - A one-shot sync has gone by then, so the re-hello holds: the box is
//     back online after about SupersedeYield.
//   - A second long-running hub-run is still there. The re-hello evicts it,
//     and it does the same: yields, says hello again and evicts this one. A
//     daemon superseded again within SupersedeFight of its own re-hello has
//     met another daemon and exits with ErrSuperseded, as before, leaving
//     the box to that one. The newer hub-run keeps the box, as it did with
//     no yield, after one extra hello each instead of a fight.
//
// Any other close clears the re-hello state, and so does a re-hello session
// that outlived SupersedeFight: a hub-sync run now and again never adds up
// to an exit. A hub-sync run twice inside SupersedeFight of the re-hello
// does read as a second daemon; the ERROR line says so.
const (
	defaultSupersedeYield = 10 * time.Second
	defaultSupersedeFight = time.Minute
)

func (c *Client) supersedeYield() time.Duration {
	if c.SupersedeYield > 0 {
		return c.SupersedeYield
	}
	return defaultSupersedeYield
}

func (c *Client) supersedeFight() time.Duration {
	if c.SupersedeFight > 0 {
		return c.SupersedeFight
	}
	return defaultSupersedeFight
}

// yield handles a session that hold ended with ErrSuperseded after it was up
// for upFor. It returns true when Run must exit (another hub-run holds the
// box); else it waits SupersedeYield (or until ctx ends) and Run redials.
func (c *Client) yield(ctx context.Context, rehello *bool, upFor time.Duration) bool {
	if *rehello && upFor < c.supersedeFight() {
		c.Log.Error().Str("box", c.Cfg.BoxID).Dur("up", upFor).
			Msg("superseded again right after the re-hello: another hub-run holds this box; leaving it to that one")
		return true
	}
	*rehello = true
	wait := c.supersedeYield()
	c.Log.Warn().Str("box", c.Cfg.BoxID).Dur("retry_in", wait).
		Msg("session superseded by a newer hello for this box (a one-shot hub-sync or another hub-run); saying hello again")
	select {
	case <-ctx.Done():
	case <-time.After(wait):
	}
	return false
}
