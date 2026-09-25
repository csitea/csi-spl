package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// CLE-34986: a download is bytes a member uploaded, served from the origin
// that holds the session cookie - never sniffed, never rendered as a page.
func TestFileDownloadIsNeverRendered(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	data := []byte("<html><script>alert(1)</script></html>")
	fid := sha256Hex(data)
	if err := (blob.Dir{Root: e.blobs}).Put(context.Background(), "t/"+tid+"/files/"+fid, data); err != nil {
		t.Fatal(err)
	}
	resp, err := e.client.Get(e.url(tid) + "/v1/files/" + fid)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	h := resp.Header
	if resp.StatusCode != http.StatusOK || h.Get("X-Content-Type-Options") != "nosniff" ||
		h.Get("Content-Disposition") != "attachment" || h.Get("Content-Security-Policy") != "sandbox; default-src 'none'" {
		t.Fatalf("download headers: %d %v", resp.StatusCode, h)
	}
}
