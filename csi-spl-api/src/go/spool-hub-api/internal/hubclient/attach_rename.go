package hubclient

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// FileRename is one attachment of a message and what its name becomes.
type FileRename struct {
	FileID string `json:"file_id"`
	From   string `json:"from"`
	To     string `json:"to,omitempty"` // "" = the type is unknown, the name stays
	Ext    string `json:"ext,omitempty"`
}

// RenameResult is the answer of RenameHashNamedFiles.
type RenameResult struct {
	MsgID   string       `json:"msg_id"`
	TaskID  string       `json:"task_id,omitempty"`
	From    string       `json:"from"`
	Files   []FileRename `json:"files"`   // every attachment named by its own sha
	Renamed int          `json:"renamed"` // of those, how many got (or, dry, would get) a name
	Unknown int          `json:"unknown"` // of those, how many keep the sha: no known type
	Applied bool         `json:"applied"`
}

// RenameHashNamedFiles gives the attachments of a message THIS box sent that
// are still named by their own sha256 a real name (SPL-1808): the bytes are
// read from this box's blob store (fetched from the hub when absent), their
// type sniffed from the magic bytes, and the name set to
// file-<12 hex>.<ext>. The message is re-signed with this box's key and sent
// as an edit that changes those names only: never the bytes, the file_id or
// the body. dry = report what would change and send nothing. as != "" also
// requires the stored author to be that agent, as for EditMessage.
func (c *Client) RenameHashNamedFiles(ctx context.Context, msgID, as string, dry bool) (RenameResult, error) {
	own, priv, err := c.box()
	if err != nil {
		return RenameResult{}, err
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return RenameResult{}, err
	}
	defer sess.Close()
	id := strings.ToLower(msgID)
	old, err := sess.EditFetch(ctx, id)
	if err != nil {
		return RenameResult{}, err
	}
	m, err := old.Inner()
	if err != nil {
		return RenameResult{}, fmt.Errorf("stored message: %w", err)
	}
	if as != "" && m.From != as {
		return RenameResult{}, fmt.Errorf("message %s was written by %s, not %s", id, m.From, as)
	}
	res := RenameResult{MsgID: id, TaskID: m.TaskID, From: m.From, Files: []FileRename{}}
	for i, a := range m.Files {
		if a.Mode != "blob" || a.Kind != "file" || !files.IsHashName(a.Name, a.FileID, a.SHA256) {
			continue
		}
		if err := sess.fetchFile(ctx, a.FileID); err != nil {
			return res, fmt.Errorf("file %s: %w", a.FileID, err)
		}
		ext, err := files.SniffExt(filepath.Join(c.Cfg.FilesDir(), a.FileID))
		if err != nil {
			return res, fmt.Errorf("file %s: %w", a.FileID, err)
		}
		r := FileRename{FileID: a.FileID, From: a.Name, Ext: ext}
		if ext == "" {
			res.Unknown++
		} else {
			r.To = files.RepairedName(a.FileID, ext)
			m.Files[i].Name = r.To
			res.Renamed++
		}
		res.Files = append(res.Files, r)
	}
	if dry || res.Renamed == 0 {
		return res, nil
	}
	env, err := wire.NewEnvelopeIn(priv, own, old.ToBox, old.Channel, old.ParentTaskID, m)
	if err != nil {
		return res, err
	}
	if _, err := sess.EditApply(ctx, id, env); err != nil {
		return res, err
	}
	res.Applied = true
	return res, nil
}
