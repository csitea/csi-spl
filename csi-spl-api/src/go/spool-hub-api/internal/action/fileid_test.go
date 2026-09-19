package action

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// TestSC006_FileIDAttachCarriesBytes: message-schema.md's file ref has
// file_id, name, bytes and sha256. A `send --file-id` attach of a blob that is
// in the local store must carry its byte length. Before the fix it had no
// `bytes` at all (SC-006 drift). A dangling id (not in the store) is still
// sent as before, without bytes: refusing it would change the CLI.
func TestSC006_FileIDAttachCarriesBytes(t *testing.T) {
	cfg := testkit.NewConfig(t)
	src := filepath.Join(t.TempDir(), "patch.txt")
	if err := os.WriteFile(src, []byte("twelve bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	put, err := Put(cfg, src, false)
	if err != nil {
		t.Fatal(err)
	}
	dangling := "0000000000000000000000000000000000000000000000000000000000000000"
	if _, err := Send(cfg, SendArgs{From: "GRK-03", To: "CLE-07", Kind: "task", Body: "b", FileIDs: []string{put.FileID, dangling}}); err != nil {
		t.Fatal(err)
	}
	res, err := spool.New(cfg).Recv("CLE-07", false)
	if err != nil || len(res.Messages) != 1 {
		t.Fatalf("recv: %v", err)
	}
	fs := res.Messages[0].Files
	if len(fs) != 2 {
		t.Fatalf("want 2 files, got %d", len(fs))
	}
	want := msg.Attachment{Mode: "blob", Kind: "file", FileID: put.FileID, SHA256: put.FileID, Name: put.FileID, Bytes: 12}
	if fs[0] != want {
		t.Errorf("files[0] = %+v, want %+v", fs[0], want)
	}
	if fs[1].Bytes != 0 || fs[1].FileID != dangling {
		t.Errorf("dangling files[1] = %+v, want unchanged (no bytes)", fs[1])
	}
}
