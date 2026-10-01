// Command spool is the on-box agent-messaging binary: one binary behind every
// CLI verb, the stdio MCP server (`spool mcp`) and, later, the Cloud Run hub.
// Verbs and MCP tools both call internal/action. Spec 002.
//
// Verbs (invoked as `spool <verb>`). The contract's hyphenated `spool-<verb>`
// names (spec 002 FR-001, contracts/cli.md) denote these subcommands: no
// separate `spool-<verb>` binaries or shims ship (spec 002 Clarifications
// 2026-09-18 spell them `spool <verb>`).
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
//	edit    --msg-id <uuid> (--body <text> | --body-file <path>) [--as <id>]   hub mode: re-sign
//	          a message this box sent with a new body (specs/032 §10)
//	delete  --msg-id <uuid> [--as <id>]   hub mode: remove a message this box sent
//	archive --task <uuid> --as <id> [--unarchive]   hub mode: archive a topic (CLE-77869)
//	react   (--task <uuid> [--msg <uuid>] | --msg <uuid>) --emoji <e> --as <id> [--remove]   hub mode:
//	          add an emoji reaction, default on the topic's opening message (CLE-77895)
//	mcp [--as <id>]            stdio MCP server exposing the verbs as tools; --as
//	                           (or $SPOOL_MCP_AS) seats it: it acts for that agent only
//
// Hub (spec 003; operator / box-daemon verbs, never called by agents):
//
//	serve                      run the hub (env: SPOOL_HUB_*; see config.Hub)
//	migrate [--db <dsn>] [--sql-dir <dir>]   apply the hub DDL (defaults
//	          $SPOOL_HUB_DB_DSN, $SPOOL_HUB_MIGRATIONS_DIR)
//	hub-tenant --tenant <id> --root-pubkey <b64>   seed a tenant row (via $SPOOL_HUB_DB_DSN)
//	hub-tenant-billing --tenant <id> --event paid|unpaid|failed|refund|cancel   set billing_status (via $SPOOL_HUB_DB_DSN)
//	hub-invite --tenant <id> --email <addr> [--role <role-id>] [--ttl 168h] [--no-mail]   operator invite
//	          (via $SPOOL_HUB_DB_DSN) + the invitation email via $SPOOL_HUB_MAIL_* (010 FR-016)
//	hub-provision-member --tenant <id> --email <addr> --role <role-id> [--name <n>] [--password-stdin]
//	          seat a member by email before any sign-in, no mail (via $SPOOL_HUB_DB_DSN)
//	hub-invite-mail --tenant <id> --email <addr> [--locale xx] [--min-gap 10m] [--max-sends 5]
//	          resend the invitation email of an open invite (exit 3 = not sent)
//	root-keygen --out <path> [--force]   tenant root keypair; prints the public key
//	hub-pin --box <id> --pubkey <b64> --root-key <path> [--force] [--revoke]
//	hub-sync                   one role=box session: hello, pins, drain queue, flush
//	hub-run                    box daemon: hold the session, reconnect with backoff
//	hub-tail --task <uuid> [--follow] [--json]
//	hub-get-file --file-id <sha256>   download one file from the hub (read door proof)
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

// version, commit and builtAt are set at build time via -ldflags
// (csi-spl-api/src/bash/build.sh); GET /version serves all three.
var (
	version = "0.1.0-dev"
	commit  = "unknown"
	builtAt = "unknown"
)

// usage names every verb run() dispatches (specs/047 W17: a stranger found
// hub-pin / hub-sync only in the Go source). TestUsageNamesEveryVerb keeps it
// in step with the switch below.
const usage = `usage: spool <verb> [flags]      (spool <verb> -h lists a verb's flags)

on a box (an agent's machine):
  keygen              make this box's signing key (prints the PUBLIC key)
  pin                 pin a box key locally; with --root-key also at the hub
  send                send a message (hub mode: --channel posts a new topic)
  recv                read this box's inbox
  put-file, put-dir   store a file / a directory as a blob
  get-file, get-dir   fetch a blob to a path
  tail                follow the local spool
  mcp                 serve the spool tools over MCP on stdio (--as <agent>)
  issue               list, get, create, update, comment, label, delete issues
  edit, delete        edit or delete a message this box sent
  archive             archive (or --unarchive) a topic by its task id
  react               add (or --remove) an emoji reaction on a topic's message

a box and its hub ($SPOOL_HUB_URL):
  hub-pin             pin (or --revoke) a box key at the hub, signed by the
                      tenant root key: --root-key <file | key text | - = stdin>
  hub-sync            one session: push the outbox, pull the inbox
  hub-run             the same, held open until signalled (the box sidecar)
  hub-tail            print a topic from the hub (--follow keeps printing)
  hub-get-file        fetch a file by id from the hub into the local blob store

running a hub:
  serve               run the hub (configured by SPOOL_HUB_* env vars)
  migrate             apply the schema migrations
  root-keygen         make a tenant root key pair (private key 0600, never printed)
  hub-tenant          create a tenant with its root public key
  hub-tenant-billing  set a tenant's billing status
  hub-invite          invite an email address into a tenant
  hub-provision-member  seat a member by email before sign-in (--password-stdin optional)
  hub-invite-mail     send (or resend) an invite's mail
  version             print the version
`

func main() { os.Exit(run(os.Args[1:])) }

// helpRC prints usage for no verb (rc 1) or a help verb (rc 0); ok=false
// means args name a verb run() dispatches.
func helpRC(args []string) (int, bool) {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(os.Stderr, usage)
		if len(args) == 0 {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

func run(args []string) int {
	if rc, ok := helpRC(args); ok {
		return rc
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
	case "hub-invite":
		return cmdHubInvite(rest)
	case "hub-provision-member":
		return cmdHubProvisionMember(rest)
	case "hub-invite-mail":
		return cmdHubInviteMail(rest)
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
		return cmdMCP(cfg, rest)
	case "hub-pin":
		return cmdHubPin(cfg, rest)
	case "hub-sync":
		return cmdHubSync(cfg)
	case "hub-run":
		return cmdHubRun(cfg)
	case "hub-tail":
		return cmdHubTail(cfg, rest)
	case "hub-get-file":
		return cmdHubGetFile(cfg, rest)
	case "issue": // specs/039 FR-008
		return cmdIssue(cfg, rest)
	case "edit": // specs/032 §10
		return cmdEdit(cfg, rest)
	case "delete":
		return cmdDelete(cfg, rest)
	case "archive": // CLE-77869
		return cmdArchive(cfg, rest)
	case "react": // CLE-77895
		return cmdReact(cfg, rest)
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
	if err := cfg.CheckKeysDir(); err != nil {
		return fail(err)
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
	rootKey := fs.String("root-key", cfg.TenantRootKey, "tenant root private key (POST/DELETE /v1/pins): a file, the key text, or - for stdin; default $SPOOL_TENANT_ROOT_KEY")
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
	kind := fs.String("kind", "", msg.KindList)
	body := fs.String("body", "", "message body")
	var fileIDs, fileRefs, dirBlobs, dirRefs stringList
	fs.Var(&fileIDs, "file-id", "attach an existing blob by file_id (repeatable)")
	fs.Var(&fileRefs, "file-ref", "attach a file by on-box path reference (repeatable)")
	fs.Var(&dirBlobs, "dir-blob", "pack a dir into a blob and attach it (repeatable)")
	fs.Var(&dirRefs, "dir-ref", "attach a dir by on-box path reference (repeatable)")
	putFile := fs.String("put-file", "", "convenience: blob this file then attach it")
	toBox := fs.String("to-box", "", "hub mode: recipient box id (needed when --to exists on several boxes)")
	channel := fs.String("channel", "", "hub mode: post into this channel (a new topic every member reads, to ALL-0), like a human's post; the hub refuses it unless --from is a member")
	typedBy := fs.String("typed-by", "", "hub mode: the HUM-<n> who typed this line at --from's terminal; the hub refuses it (typed_by_not_bound) unless that human is bound as this box's operator")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	out, err := action.SendCtx(ctx, cfg, action.SendArgs{
		From: *from, To: *to, TaskID: *task, Kind: *kind, Body: *body,
		FileIDs: fileIDs, FileRefs: fileRefs, DirBlobs: dirBlobs, DirRefs: dirRefs,
		PutFile: *putFile, ToBox: *toBox, TypedBy: *typedBy, Channel: *channel,
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
func cmdMCP(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	as := fs.String("as", os.Getenv("SPOOL_MCP_AS"), "the one agent id this server acts for")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *as != "" && !msg.ValidID(*as) {
		fmt.Fprintf(os.Stderr, "spool: mcp --as %q is not an agent id\n", *as)
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := mcp.Run(ctx, cfg, version, mcp.Options{Seat: *as}); err != nil && ctx.Err() == nil {
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
