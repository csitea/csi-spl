package main

import (
	"encoding/json"
	"flag"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdEdit is specs/032 §10: this box replaces the body of a message it sent,
// re-signed with its own key; the hub keeps every earlier body as a revision.
// Prints {msg_id, task_id, from, revision}.
func cmdEdit(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("edit", flag.ContinueOnError)
	id := fs.String("msg-id", "", "the message to edit (sent by this box)")
	as := fs.String("as", "", "also require the message's author to be this agent")
	body := fs.String("body", "", "the new text")
	bodyFile := fs.String("body-file", "", "read the new text from this file")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	r, err := action.Edit(ctx, cfg, action.EditArgs{MsgID: *id, As: *as, Body: *body, BodyFile: *bodyFile})
	if err != nil {
		return fail(err)
	}
	out, _ := json.Marshal(r)
	fmt.Println(string(out))
	return 0
}

// cmdDelete removes a message this box sent (specs/032 §10).
func cmdDelete(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("delete", flag.ContinueOnError)
	id := fs.String("msg-id", "", "the message to delete (sent by this box)")
	as := fs.String("as", "", "also require the message's author to be this agent")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	task, err := action.Delete(ctx, cfg, action.EditArgs{MsgID: *id, As: *as})
	if err != nil {
		return fail(err)
	}
	out, _ := json.Marshal(map[string]string{"msg_id": *id, "task_id": task, "deleted": "true"})
	fmt.Println(string(out))
	return 0
}

// cmdAttachRename is SPL-1808: this box gives the attachments of a message it
// sent that are still named by their own sha256 a name with the extension
// their bytes are (file-<12 hex>.<ext>), re-signed with its own key. Names
// only: the bytes, file_id and body stay. Prints the RenameResult.
func cmdAttachRename(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("attach-rename", flag.ContinueOnError)
	id := fs.String("msg-id", "", "the message whose files to name (sent by this box)")
	as := fs.String("as", "", "also require the message's author to be this agent")
	dry := fs.Bool("dry-run", false, "print what would be renamed, send nothing")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	r, err := action.AttachRename(ctx, cfg, action.EditArgs{MsgID: *id, As: *as}, *dry)
	if err != nil {
		return fail(err)
	}
	out, _ := json.Marshal(r)
	fmt.Println(string(out))
	return 0
}
