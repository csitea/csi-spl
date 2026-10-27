package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/keyexec"
)

// keyExecUsage is the help of the two seat verbs of spec 127 X2.
const keyExecUsage = `usage:
  spool key-exec <claude|grok|agy|mistral|qwen> -- <cli> [args...]
      start a seat's CLI on its workspace's own key, asked from the desk
      socket ($SPOOL_KEY_SOCK), in the seat dir ($SPOOL_SEAT_DIR). Exit 79:
      the vendor refused the key (reported to the desk), or the hub marked
      it exhausted; 78: no key for this seat; else the CLI's own code.
  spool key-helper --sock <path> claude
      claude's apiKeyHelper: prints the key on stdout, nothing on stderr.
`

// cmdKeyExec is `spool key-exec` (spec 127 5.2 step 5, spec 159 9.1).
func cmdKeyExec(args []string) int {
	kind, cli, rest, ok := keyExecArgs(args)
	if !ok {
		fmt.Fprint(os.Stderr, keyExecUsage)
		return keyexec.ExitUsage
	}
	sock := os.Getenv(keyexec.SockEnv)
	seatDir := os.Getenv(keyexec.SeatDirEnv)
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "spool key-exec: %v\n", err)
		return keyexec.ExitRefused
	}
	return keyexec.Run(context.Background(), keyexec.Opts{
		Kind: kind, CLI: cli, Args: rest, Env: os.Environ(),
		SeatDir: seatDir,
		Helper:  shQuote(self) + " key-helper --sock " + shQuote(sock) + " claude",
		Desk:    keyexec.SockDesk{Path: sock, Seat: seatDir},
		Stdin:   os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr,
	})
}

// keyExecArgs reads `<kind> -- <cli> [args...]`.
func keyExecArgs(args []string) (kind, cli string, rest []string, ok bool) {
	if len(args) < 3 || args[1] != "--" || !keyexec.IsKind(args[0]) {
		return "", "", nil, false
	}
	return args[0], args[2], args[3:], true
}

// cmdKeyHelper is claude's apiKeyHelper: the key on stdout and nothing on
// stderr (127 5.2 step 5), from the desk's held lease only (op helper).
func cmdKeyHelper(args []string) int {
	if len(args) != 3 || args[0] != "--sock" || args[2] != "claude" {
		fmt.Fprint(os.Stderr, keyExecUsage)
		return keyexec.ExitUsage
	}
	l, err := keyexec.SockDesk{Path: args[1]}.Helper(context.Background(), "claude")
	if err != nil {
		return 1 // silent: claude shows its own auth error
	}
	fmt.Println(l.Key)
	return 0
}

// shQuote quotes s for the shell that runs the apiKeyHelper line.
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
