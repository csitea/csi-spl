// Command spool is the on-box agent-messaging binary: one binary behind every
// CLI verb, the stdio MCP server (`spool mcp`) and, later, the Cloud Run hub.
// Verbs and MCP tools both call internal/action. Spec 002.
//
// Verbs (invoked as `spool <verb>`; the hyphenated `spool-<verb>` names in the
// contract are shims over these):
//
//	keygen  --as <id> [--force]
//	pin     --id <id> --pubkey <b64> [--force]
//	send    --from <id> --to <id> [--task <uuid>] --kind <k> --body <text>
//	          [--file-id <id>]... [--file-ref <path>]... [--dir-blob <path>]... [--dir-ref <path>]...
//	recv    --as <id> [--ack]
//	put-file <path>            put-dir <path>
//	get-file <file_id> <dest>  get-dir <file_id> <dest>
//	tail    [--task <uuid>] [--json]
//	mcp                        stdio MCP server exposing the verbs as tools
//	version
//
// Exit codes: 0 ok, 78 verify/refuse (unpinned, bad sig, hash mismatch), 1 other.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mcp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// version is over/set at build time via -ldflags.
var version = "0.1.0-dev"

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: spool <keygen|pin|send|recv|put-file|put-dir|get-file|get-dir|tail|mcp|version> ...")
		return 1
	}
	cmd, rest := args[0], args[1:]

	if cmd == "version" {
		fmt.Println(version)
		return 0
	}

	cfg, err := config.Load()
	if err != nil {
		return fail(err)
	}

	switch cmd {
	case "keygen":
		return cmdKeygen(cfg, rest)
	case "pin":
		return cmdPin(cfg, rest)
	case "send":
		return cmdSend(cfg, rest)
	case "recv":
		return cmdRecv(cfg, rest)
	case "put-file":
		return cmdPut(cfg, rest, false)
	case "put-dir":
		return cmdPut(cfg, rest, true)
	case "get-file":
		return cmdGet(cfg, rest, false)
	case "get-dir":
		return cmdGet(cfg, rest, true)
	case "tail":
		return cmdTail(cfg, rest)
	case "mcp":
		return cmdMCP(cfg)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		return 1
	}
}

func cmdKeygen(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("keygen", flag.ContinueOnError)
	as := fs.String("as", "", "agent id (e.g. CLE-07)")
	force := fs.Bool("force", false, "overwrite an existing key")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !msg.ValidID(*as) {
		return fail(fmt.Errorf("--as must be a valid agent id"))
	}
	pub, err := sign.GenerateKey(cfg.KeysDir, *as, *force)
	if err != nil {
		return fail(err)
	}
	fmt.Println(pub) // print the PUBLIC key only
	return 0
}

func cmdPin(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("pin", flag.ContinueOnError)
	id := fs.String("id", "", "agent id to pin")
	pub := fs.String("pubkey", "", "base64 public key")
	force := fs.Bool("force", false, "replace an existing different pin")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !msg.ValidID(*id) || *pub == "" {
		return fail(fmt.Errorf("--id (valid) and --pubkey are required"))
	}
	if err := sign.Pin(cfg.PinsDir, *id, *pub, *force); err != nil {
		return fail(err)
	}
	return 0
}

type stringList []string

func (s *stringList) String() string { return fmt.Sprint(*s) }
func (s *stringList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func cmdSend(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("send", flag.ContinueOnError)
	from := fs.String("from", "", "sender agent id")
	to := fs.String("to", "", "recipient agent id")
	task := fs.String("task", "", "task id (uuid); minted if empty")
	kind := fs.String("kind", "", "task|result|note|reject")
	body := fs.String("body", "", "message body")
	var fileIDs, fileRefs, dirBlobs, dirRefs stringList
	fs.Var(&fileIDs, "file-id", "attach an existing blob by file_id (repeatable)")
	fs.Var(&fileRefs, "file-ref", "attach a file by on-box path reference (repeatable)")
	fs.Var(&dirBlobs, "dir-blob", "pack a dir into a blob and attach it (repeatable)")
	fs.Var(&dirRefs, "dir-ref", "attach a dir by on-box path reference (repeatable)")
	putFile := fs.String("put-file", "", "convenience: blob this file then attach it")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	out, err := action.Send(cfg, action.SendArgs{
		From: *from, To: *to, TaskID: *task, Kind: *kind, Body: *body,
		FileIDs: fileIDs, FileRefs: fileRefs, DirBlobs: dirBlobs, DirRefs: dirRefs,
		PutFile: *putFile,
	})
	if err != nil {
		return fail(err)
	}
	fmt.Println(action.JSON(out))
	return 0
}

func cmdRecv(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("recv", flag.ContinueOnError)
	as := fs.String("as", "", "receiving agent id")
	ack := fs.Bool("ack", false, "move returned messages to archive/")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	msgs, err := action.Recv(cfg, *as, *ack)
	// Print the valid messages regardless (they were verified); [] when empty.
	if msgs != nil {
		fmt.Println(action.JSON(msgs))
	}
	if err != nil {
		return fail(err)
	}
	return 0
}

func cmdPut(cfg *config.Config, args []string, dir bool) int {
	if len(args) != 1 {
		return fail(fmt.Errorf("usage: put-%s <path>", pick(dir, "dir", "file")))
	}
	out, err := action.Put(cfg, args[0], dir)
	if err != nil {
		return fail(err)
	}
	fmt.Println(action.JSON(out))
	return 0
}

func cmdGet(cfg *config.Config, args []string, dir bool) int {
	if len(args) != 2 {
		return fail(fmt.Errorf("usage: get-%s <file_id> <dest>", pick(dir, "dir", "file")))
	}
	out, err := action.Get(cfg, args[0], args[1], dir)
	if err != nil {
		return fail(err)
	}
	fmt.Println(action.JSON(out))
	return 0
}

func cmdTail(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("tail", flag.ContinueOnError)
	task := fs.String("task", "", "task id to tail")
	asJSON := fs.Bool("json", false, "emit raw v1 NDJSON")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	out, err := action.Tail(cfg, *task, *asJSON)
	if err != nil {
		return fail(err)
	}
	fmt.Print(out)
	return 0
}

// cmdMCP serves the verbs as MCP tools over stdio until stdin closes or the
// process is signalled. One server per agent session, never per tmux window.
func cmdMCP(cfg *config.Config) int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := mcp.Run(ctx, cfg, version); err != nil && ctx.Err() == nil {
		return fail(err)
	}
	return 0
}

func pick(b bool, yes, no string) string {
	if b {
		return yes
	}
	return no
}

// fail prints err and returns the mapped exit code (78 for verify/refuse).
func fail(err error) int {
	fmt.Fprintln(os.Stderr, "spool: "+err.Error())
	return action.ExitCode(err)
}
