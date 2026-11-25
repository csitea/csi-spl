package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// cmdLiveAck hands this box's sidecar the shown ack of messages agent --as
// was shown (spec 053 S1, SPL-6517): `spool live-ack --as <id> <msg_id>...`.
// The agent hook runs it detached (scripts/spool-live-ack.sh) each time it
// injects inbox messages. It never dials the hub: no sidecar = exit 0 with a
// note on stderr, the ack dropped. Prints {"acked": n}.
func cmdLiveAck(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("live-ack", flag.ContinueOnError)
	as := fs.String("as", "", "the local agent the messages were shown to")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	n, err := hubclient.New(cfg).LiveAckShown(ctx, *as, fs.Args())
	if errors.Is(err, hubclient.ErrNoSidecar) {
		fmt.Fprintln(os.Stderr, "spool live-ack: no sidecar listens on this box; ack dropped")
		return 0
	}
	if err != nil {
		return fail(err)
	}
	fmt.Printf("{\"acked\":%d}\n", n)
	return 0
}
