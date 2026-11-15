package main

import (
	"errors"
	"flag"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdChannelPins is one channel's box pins (spec 164 section 4.3, row B4),
// over the authenticated hello like `spool box-presence`, signed by the box's
// key and scoped to its own workspace:
//
//	channel-pins --channel <c>   {channel, box_pins, is_pinned} as JSON
//
// box_pins [] with is_pinned false = any box of the workspace (the default).
// Any failure exits non-zero (no hub, unknown_channel, a bad answer): the
// placer and the launcher (B5) read that as pinned to nobody, never as
// unpinned.
func cmdChannelPins(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("channel-pins", flag.ContinueOnError)
	channel := fs.String("channel", "", "the channel id")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 || *channel == "" {
		return fail(errors.New("usage: spool channel-pins --channel <c>"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.ChannelPins(ctx, cfg, action.ChannelPinsArgs{Channel: *channel})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
