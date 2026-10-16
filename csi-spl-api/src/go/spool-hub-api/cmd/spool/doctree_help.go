package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// dtVerb is one doctree verb: cmdDocTree routes by this table and
// `spool doctree --help` prints it, so a new verb cannot miss the help.
// usage is what the verb's own -h prints (TestDocTreeHelpListsTheDispatchTable).
type dtVerb struct {
	name    string
	run     func(context.Context, *config.Config, []string) error
	purpose string
	usage   string
}

var docTreeVerbs = []dtVerb{
	{"list", dtList, "list the documents, or only those linked to a topic",
		"usage: spool doctree list [--topic id]"},
	{"nodes", dtNodes, "list one folder's children (no --parent = the top level)",
		"usage: spool doctree nodes [--parent folder-id]"},
	{"folder", dtFolder, "create a folder",
		"usage: spool doctree folder --name n [--parent folder-id] [--title t] [--description d]"},
	{"move-node", dtMoveNode, "move a folder or a document (its node id from nodes) under another folder",
		"usage: spool doctree move-node <node> [--parent folder-id]"},
	{"create", dtCreate, "create a document; prints it with its id",
		"usage: spool doctree create --title t [--folder id] [--description d]"},
	{"head", dtHead, "show a document's rev, item count, root and topic",
		"usage: spool doctree head <doc>"},
	{"read", dtRead, "print a document's items as JSON (the whole doc, or one subtree)",
		"usage: spool doctree read <doc> [--item id]"},
	{"add", dtAdd, "add a heading, or a paragraph, table, code block or picture to an item",
		"usage: spool doctree add <doc> --kind heading|para|code|table|picture " +
			"[--title t] [--level n | --under id | --after id] [--unnumbered] [--dotted] [--outline n] [--tight] [--tight-end] [--text t | --file f] [--lang l] [--path img] [--caption c] [--item id]"},
	{"edit", dtEdit, "replace an item's title or body, or set one key of its attrs",
		"usage: spool doctree edit <doc> <item> --field title|body|attrs.<key> [--value v | --file f] [--json]"},
	{"move", dtMove, "move an item to another parent or position",
		"usage: spool doctree move <doc> <item> [--parent id] [--ord n] [--rev n]"},
	{"delete", dtDelete, "delete an item's subtree, or the whole document",
		"usage: spool doctree delete <doc> [<item>] [--rev n]"},
	{"rename", dtRename, "rename a document",
		"usage: spool doctree rename <doc> --title t [--rev n]"},
	{"export", dtExport, "export a document or a branch as Markdown (the WUI's export rules)",
		"usage: spool doctree export <doc> [--item id] [--out file] [--from read.json]"},
	{"asset-put", dtAssetPut, "upload a picture of a document under its md-relative path, <doc>.assets/NN-name.ext",
		"usage: spool doctree asset-put <doc> <path> --file f"},
	{"asset-get", dtAssetGet, "print a picture of a document as JSON, its bytes in base64",
		"usage: spool doctree asset-get <doc> <path>"},
}

func dtVerbByName(name string) (dtVerb, bool) {
	for _, v := range docTreeVerbs {
		if v.name == name {
			return v, true
		}
	}
	return dtVerb{}, false
}

// docTreeHelp is the page `spool doctree --help` prints.
func docTreeHelp() string {
	var b strings.Builder
	b.WriteString("usage: spool doctree <verb> [args]\n\n")
	b.WriteString("Workspace documents (the Qto outline): folders, documents and their items,\n")
	b.WriteString("over the hub's workspace doctree API. Needs hub mode ($SPOOL_HUB_URL) and a tenant.\n")
	b.WriteString("<doc> and <item> are ids; --item defaults to the document's last item.\n\n")
	b.WriteString("Verbs:\n")
	w := 0
	for _, v := range docTreeVerbs {
		w = max(w, len(v.name))
	}
	for _, v := range docTreeVerbs {
		fmt.Fprintf(&b, "  %-*s  %s\n", w, v.name, v.purpose)
		fmt.Fprintf(&b, "  %-*s  %s\n", w, "", v.usage)
	}
	b.WriteString("\nExample:\n")
	b.WriteString("  spool doctree create --title \"Release notes\"\n")
	b.WriteString("  spool doctree add <doc> --kind heading --title \"Overview\"\n")
	b.WriteString("  spool doctree add <doc> --kind para --text \"What changed and why.\"\n")
	b.WriteString("  spool doctree export <doc> --out release-notes.md\n")
	b.WriteString("\nOne verb's flags: spool doctree <verb> -h\n")
	return b.String()
}

// dtHelp answers --help, -h and help on stdout (exit 0), and a bare
// `spool doctree` on stderr (exit 2: no verb is a usage error).
func dtHelp(asked bool) int {
	if asked {
		return writeStdout([]byte(docTreeHelp()), false)
	}
	fmt.Fprint(os.Stderr, docTreeHelp())
	return 2
}
