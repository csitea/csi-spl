// Command spool is the on-box agent-messaging binary: one binary behind every
// CLI verb (and, later, the stdio MCP server and the Cloud Run hub). Spec 002.
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
//	version
//
// Exit codes: 0 ok, 78 verify/refuse (unpinned, bad sig, hash mismatch), 1 other.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
)

// version is over/set at build time via -ldflags.
var version = "0.1.0-dev"

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: spool <keygen|pin|send|recv|put-file|put-dir|get-file|get-dir|tail|version> ...")
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
		fmt.Fprintln(os.Stderr, "spool mcp: stdio MCP server not yet implemented (spec 002 US4)")
		return 1
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
	var atts []msg.Attachment
	for _, id := range fileIDs {
		atts = append(atts, msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: id})
	}
	if *putFile != "" {
		a, err := files.PutFile(cfg.FilesDir(), *putFile)
		if err != nil {
			return fail(err)
		}
		atts = append(atts, a)
	}
	for _, p := range dirBlobs {
		a, err := files.PutDir(cfg.FilesDir(), p)
		if err != nil {
			return fail(err)
		}
		atts = append(atts, a)
	}
	for _, p := range fileRefs {
		a, err := files.RefFile(p)
		if err != nil {
			return fail(err)
		}
		atts = append(atts, a)
	}
	for _, p := range dirRefs {
		a, err := files.RefDir(p)
		if err != nil {
			return fail(err)
		}
		atts = append(atts, a)
	}
	st := spool.New(cfg)
	m, err := st.Send(*from, *to, *task, *kind, *body, atts)
	if err != nil {
		return fail(err)
	}
	out, _ := json.Marshal(map[string]string{"msg_id": m.MsgID, "task_id": m.TaskID, "ts": m.TS})
	fmt.Println(string(out))
	return 0
}

func cmdRecv(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("recv", flag.ContinueOnError)
	as := fs.String("as", "", "receiving agent id")
	ack := fs.Bool("ack", false, "move returned messages to archive/")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	st := spool.New(cfg)
	res, err := st.Recv(*as, *ack)
	// Print the valid messages regardless (they were verified); [] when empty.
	if res != nil {
		msgs := res.Messages
		if msgs == nil {
			msgs = []*msg.Message{}
		}
		out, _ := json.Marshal(msgs)
		fmt.Println(string(out))
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
	var a msg.Attachment
	var err error
	if dir {
		a, err = files.PutDir(cfg.FilesDir(), args[0])
	} else {
		a, err = files.PutFile(cfg.FilesDir(), args[0])
	}
	if err != nil {
		return fail(err)
	}
	out, _ := json.Marshal(map[string]interface{}{
		"file_id": a.FileID, "sha256": a.SHA256, "bytes": a.Bytes, "name": a.Name, "kind": a.Kind,
	})
	fmt.Println(string(out))
	return 0
}

func cmdGet(cfg *config.Config, args []string, dir bool) int {
	if len(args) != 2 {
		return fail(fmt.Errorf("usage: get-%s <file_id> <dest>", pick(dir, "dir", "file")))
	}
	var err error
	if dir {
		err = files.GetDir(cfg.FilesDir(), args[0], args[1])
	} else {
		err = files.GetFile(cfg.FilesDir(), args[0], args[1])
	}
	if err != nil {
		return fail(err)
	}
	out, _ := json.Marshal(map[string]string{"path": args[1], "file_id": args[0]})
	fmt.Println(string(out))
	return 0
}

func cmdTail(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("tail", flag.ContinueOnError)
	task := fs.String("task", "", "task id to tail")
	asJSON := fs.Bool("json", false, "emit raw v1 NDJSON")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *task == "" {
		return fail(fmt.Errorf("--task is required"))
	}
	st := spool.New(cfg)
	msgs, err := st.Tail(*task)
	if err != nil {
		return fail(err)
	}
	for _, m := range msgs {
		if *asJSON {
			b, _ := msg.Marshal(m)
			fmt.Println(string(b))
		} else {
			fmt.Printf("%s  %s -> %s  [%s]  %s\n", m.TS, m.From, m.To, m.Kind, m.Body)
		}
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
	if errors.Is(err, files.ErrHashMismatch) {
		return 78
	}
	return spool.ExitCode(err)
}
