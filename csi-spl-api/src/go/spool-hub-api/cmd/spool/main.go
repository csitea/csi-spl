// Command spool is the on-box agent-messaging binary: one binary behind every
// CLI verb, the stdio MCP server (`spool mcp`) and, later, the Cloud Run hub.
// Verbs and MCP tools both call internal/action. Spec 002.
//
// Verbs (invoked as `spool <verb>`; the hyphenated `spool-<verb>` names in the
// contract are shims over these):
//
//	keygen  [--box <box_id>] [--force]      box keypair; --box defaults to $SPOOL_BOX_ID
//	pin     --box <box_id> --pubkey <b64> [--force] [--revoke] [--root-key <path>]
//	send    --from <id> --to <id> [--task <uuid>] --kind <k> --body <text>
//	          [--file-id <id>]... [--file-ref <path>]... [--dir-blob <path>]... [--dir-ref <path>]...
//	          [--to-box <box_id>]   (hub mode only, spec 003)
//	recv    --as <id> [--ack]
//	put-file <path>            put-dir <path>
//	get-file <file_id> <dest>  get-dir <file_id> <dest>
//	tail    [--task <uuid>] [--json]
//	mcp                        stdio MCP server exposing the verbs as tools
//
// Hub (spec 003; operator / box-daemon verbs, never called by agents):
//
//	serve                      run the hub (env: SPOOL_HUB_*; see config.Hub)
//	migrate [--db <dsn>] [--sql-dir <dir>]   apply the hub DDL (defaults
//	          $SPOOL_HUB_DB_DSN, $SPOOL_HUB_MIGRATIONS_DIR)
//	hub-tenant --tenant <id> --root-pubkey <b64>   seed a tenant row (via $SPOOL_HUB_DB_DSN)
//	hub-tenant-billing --tenant <id> --event paid|unpaid|failed|refund|cancel   set billing_status (via $SPOOL_HUB_DB_DSN)
//	root-keygen --out <path> [--force]   tenant root keypair; prints the public key
//	hub-pin --box <id> --pubkey <b64> --root-key <path> [--force] [--revoke]
//	hub-sync                   one role=box session: hello, pins, drain queue, flush
//	hub-run                    box daemon: hold the session, reconnect with backoff
//	hub-tail --task <uuid> [--follow] [--json]
//	version
//
// Local mode (no hub) is unsigned: send/recv need no key and no pin; keygen and
// pin only prepare the one per-box key for hub mode (contracts/trust-modes.md).
//
// Exit codes: 0 ok, 78 verify/refuse (hash mismatch; in hub mode also a bad or
// unpinned box signature), 1 other.
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
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
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
	switch cmd {
	case "migrate":
		return cmdMigrate(rest)
	case "serve":
		return cmdServe()
	case "hub-tenant":
		return cmdHubTenant(rest)
	case "hub-tenant-billing":
		return cmdHubTenantBilling(rest)
	case "root-keygen":
		return cmdRootKeygen(rest)
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
	case "hub-pin":
		return cmdHubPin(cfg, rest)
	case "hub-sync":
		return cmdHubSync(cfg)
	case "hub-run":
		return cmdHubRun(cfg)
	case "hub-tail":
		return cmdHubTail(cfg, rest)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		return 1
	}
}

func cmdKeygen(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("keygen", flag.ContinueOnError)
	box := fs.String("box", cfg.BoxID, "box id (default $SPOOL_BOX_ID)")
	force := fs.Bool("force", false, "overwrite an existing key")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !msg.ValidBoxID(*box) {
		return fail(fmt.Errorf("--box or $SPOOL_BOX_ID must be a valid box id (e.g. box-a)"))
	}
	pub, err := sign.GenerateKey(cfg.KeysDir, *box, *force)
	if err != nil {
		return fail(err)
	}
	fmt.Println(pub) // print the PUBLIC key only
	return 0
}

func cmdPin(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("pin", flag.ContinueOnError)
	box := fs.String("box", "", "box id to pin")
	pub := fs.String("pubkey", "", "base64 box public key")
	force := fs.Bool("force", false, "replace an existing different pin")
	revoke := fs.Bool("revoke", false, "remove the local pin and DELETE /v1/pins when a root key is set")
	rootKey := fs.String("root-key", cfg.TenantRootKey, "tenant root private key (POST/DELETE /v1/pins); default $SPOOL_TENANT_ROOT_KEY")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if err := action.Pin(cfg, action.PinArgs{Box: *box, PubKey: *pub, RootKey: *rootKey, Force: *force, Revoke: *revoke}); err != nil {
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
	toBox := fs.String("to-box", "", "hub mode: recipient box id (needed when --to exists on several boxes)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	out, err := action.SendCtx(ctx, cfg, action.SendArgs{
		From: *from, To: *to, TaskID: *task, Kind: *kind, Body: *body,
		FileIDs: fileIDs, FileRefs: fileRefs, DirBlobs: dirBlobs, DirRefs: dirRefs,
		PutFile: *putFile, ToBox: *toBox,
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

// cmdMigrate applies the hub DDL (csi-spl-rdb/src/sql/postgres/spool-hub) to
// the database in filename order; a re-run is a no-op (spec 003 T001b).
func cmdMigrate(args []string) int {
	fs := flag.NewFlagSet("migrate", flag.ContinueOnError)
	dsn := fs.String("db", os.Getenv("SPOOL_HUB_DB_DSN"), "postgres DSN (default $SPOOL_HUB_DB_DSN)")
	dir := fs.String("sql-dir", os.Getenv("SPOOL_HUB_MIGRATIONS_DIR"), "DDL dir (default $SPOOL_HUB_MIGRATIONS_DIR)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *dsn == "" || *dir == "" {
		return fail(fmt.Errorf("--db / $SPOOL_HUB_DB_DSN and --sql-dir / $SPOOL_HUB_MIGRATIONS_DIR are required"))
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pg, err := store.OpenPostgres(ctx, *dsn)
	if err != nil {
		return fail(err)
	}
	defer pg.Close()
	res, err := store.Migrate(ctx, pg.Pool(), *dir)
	for _, a := range res {
		if a.Skipped {
			fmt.Println("skipped " + a.File + " (already applied)")
		} else {
			fmt.Println("applied " + a.File)
		}
	}
	if err != nil {
		return fail(err)
	}
	return 0
}
