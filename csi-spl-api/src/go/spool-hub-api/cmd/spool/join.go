package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// joinUsage is spool join's usage line: the token comes from the environment
// or stdin, so it need not appear in ps or shell history (spec 073 4.4).
const joinUsage = `usage: SPOOL_JOIN_TOKEN=<token> spool join [--box <box_id>] [<hub-url>]
       spool join [--box <box_id>] <hub-url> -      (the token on stdin)
<hub-url> defaults to $SPOOL_HUB_URL, --box to $SPOOL_BOX_ID`

// cmdJoin seats this box with a join token (spec 073 T004, spec 108 T003):
// the box makes its own key and the hub pins its public half.
func cmdJoin(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("join", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprintln(fs.Output(), joinUsage); fs.PrintDefaults() }
	box := fs.String("box", cfg.BoxID, "box id to seat (default $SPOOL_BOX_ID)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	hubURL, src := cfg.HubURL, ""
	switch fs.NArg() {
	case 0:
	case 1:
		hubURL = fs.Arg(0)
	case 2:
		hubURL, src = fs.Arg(0), fs.Arg(1)
	default:
		fmt.Fprintln(os.Stderr, joinUsage)
		return 1
	}
	if hubURL == "" {
		fmt.Fprintln(os.Stderr, joinUsage)
		return 1
	}
	tok, err := action.ReadJoinToken(src, os.Stdin)
	if err != nil {
		return fail(err)
	}
	res, err := action.Join(cfg, action.JoinArgs{HubURL: hubURL, Token: tok, Box: *box})
	if err != nil {
		return fail(fmt.Errorf("join: %w", err))
	}
	fmt.Printf("seated %s on %s\n", res.Box, res.Tenant)
	return 0
}
