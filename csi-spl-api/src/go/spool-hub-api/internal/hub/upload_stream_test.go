package hub_test

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// postFile is POST /v1/files with body; size < 0 sends it chunked (no
// Content-Length), so the size and quota checks cannot run before the body.
func (e *env) postFile(tenant, token string, body io.Reader, size int64) (int, wire.FileResult, wire.ErrorBody) {
	e.t.Helper()
	req, _ := http.NewRequest(http.MethodPost, e.url(tenant)+"/v1/files", body)
	req.ContentLength = size
	if size < 0 {
		req.ContentLength = -1
		req.TransferEncoding = []string{"chunked"}
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var fr wire.FileResult
	var eb wire.ErrorBody
	json.Unmarshal(raw, &fr) //nolint:errcheck
	json.Unmarshal(raw, &eb) //nolint:errcheck
	return resp.StatusCode, fr, eb
}

// blobFiles lists every object file under the blob root (tmp included).
func (e *env) blobFiles() []string {
	var out []string
	filepath.Walk(e.blobs, func(p string, fi os.FileInfo, err error) error { //nolint:errcheck
		if err == nil && !fi.IsDir() {
			rel, _ := filepath.Rel(e.blobs, p)
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	return out
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b) //nolint:errcheck
	return b
}

// TestUploadStreamControls: 027 T020 CONTROLS. What was refused before the
// streamed upload is still refused, and what it stores is what was sent.
func TestUploadStreamControls(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)

	t.Run("id is the sha of the stored bytes", func(t *testing.T) {
		data := randBytes(3<<20 + 11)
		code, fr, _ := e.postFile(tid, tok, bytes.NewReader(data), -1)
		if code != http.StatusCreated || fr.Bytes != int64(len(data)) {
			t.Fatalf("upload: %d %+v", code, fr)
		}
		gc, got := e.getFile(tid, fr.FileID, tok)
		if gc != http.StatusOK {
			t.Fatalf("get: %d", gc)
		}
		sum := sha256.Sum256([]byte(got))
		if hex.EncodeToString(sum[:]) != fr.FileID || fr.SHA256 != fr.FileID || !bytes.Equal([]byte(got), data) {
			t.Fatal("stored bytes do not hash to the returned id")
		}
	})

	t.Run("duplicate upload: same id, one object", func(t *testing.T) {
		data := randBytes(100 << 10)
		before := len(e.blobFiles())
		_, f1, _ := e.postFile(tid, tok, bytes.NewReader(data), int64(len(data)))
		code, f2, _ := e.postFile(tid, tok, bytes.NewReader(data), -1)
		if code != http.StatusCreated || f1.FileID == "" || f1.FileID != f2.FileID {
			t.Fatalf("dup: %d %s %s", code, f1.FileID, f2.FileID)
		}
		if n := len(e.blobFiles()); n != before+1 {
			t.Fatalf("objects after two uploads of the same bytes: %d, want %d (%v)", n, before+1, e.blobFiles())
		}
	})

	over := int64(msg.MaxFileBytes) + 1
	for _, cl := range []int64{over, -1} {
		t.Run(fmt.Sprintf("over the limit is 413 and leaves nothing (content-length %d)", cl), func(t *testing.T) {
			before := e.blobFiles()
			code, _, eb := e.postFile(tid, tok, io.LimitReader(rand.Reader, over), cl)
			if code != http.StatusRequestEntityTooLarge || eb.Error != "limit_file" {
				t.Fatalf("over limit: %d %+v", code, eb)
			}
			if after := e.blobFiles(); len(after) != len(before) {
				t.Fatalf("413 left objects: %v", after)
			}
		})
	}

	t.Run("no upload token is 401", func(t *testing.T) {
		if code, _, eb := e.postFile(tid, "", strings.NewReader("x"), 1); code != http.StatusUnauthorized || eb.Error != "door" {
			t.Fatalf("anonymous: %d %+v", code, eb)
		}
	})

	t.Run("aborted upload leaves no tmp object", func(t *testing.T) {
		before := e.blobFiles()
		conn, err := net.Dial("tcp", e.ts.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		w := bufio.NewWriter(conn)
		fmt.Fprintf(w, "POST /v1/files HTTP/1.1\r\nHost: %s%s\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n", tid, domain, tok, 8<<20)
		w.Write(randBytes(2 << 20)) //nolint:errcheck
		w.Flush()                   //nolint:errcheck
		time.Sleep(100 * time.Millisecond)
		conn.Close()
		deadline := time.Now().Add(5 * time.Second)
		for {
			after := e.blobFiles()
			if len(after) == len(before) {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("aborted upload left: %v", after)
			}
			time.Sleep(20 * time.Millisecond)
		}
	})
}

func TestUploadUnpaidTenant(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)
	if err := e.st.SetBillingStatus(context.Background(), tid, "grace"); err != nil {
		t.Fatal(err)
	}
	if code, _, eb := e.postFile(tid, tok, strings.NewReader("hello"), -1); code != http.StatusPaymentRequired || eb.Error != "unpaid" {
		t.Fatalf("unpaid: %d %+v", code, eb)
	}
	if n := len(e.blobFiles()); n != 0 {
		t.Fatalf("unpaid upload stored %d objects", n)
	}
}

// TestUploadQuotaPerTenant: over quota is refused with and without
// Content-Length, leaves no object, and tenant A never counts against B.
func TestUploadQuotaPerTenant(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.QuotaFileBytes = 10 })
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	ba := e.box(ta, "box-a", "GRK-03")
	bb := e.box(tb, "box-b", "CLE-07")
	e.pin(ta, ba)
	e.pin(tb, bb)
	toka, tokb := e.uploadToken(ta, ba), e.uploadToken(tb, bb)

	if code, _, _ := e.postFile(ta, toka, strings.NewReader("aaaaaaaa"), 8); code != http.StatusCreated {
		t.Fatalf("A first 8 bytes: %d", code)
	}
	if code, _, _ := e.postFile(tb, tokb, strings.NewReader("bbbbbbbb"), -1); code != http.StatusCreated {
		t.Fatalf("B 8 bytes counted against A's usage: %d", code)
	}
	before := e.blobFiles()
	for _, cl := range []int64{8, -1} {
		code, _, eb := e.postFile(ta, toka, strings.NewReader("cccccccc"), cl)
		if code != http.StatusTooManyRequests || eb.Error != "quota" {
			t.Fatalf("A over quota (content-length %d): %d %+v", cl, code, eb)
		}
	}
	if after := e.blobFiles(); len(after) != len(before) {
		t.Fatalf("over-quota upload left objects: %v", after)
	}
	// A re-upload of bytes A already holds needs no new quota.
	if code, _, _ := e.postFile(ta, toka, strings.NewReader("aaaaaaaa"), -1); code != http.StatusCreated {
		t.Fatalf("A duplicate at quota: %d", code)
	}
	// Deleting frees quota at once (the usage entry is dropped, not aged out).
	sum := sha256.Sum256([]byte("aaaaaaaa"))
	req, _ := http.NewRequest(http.MethodDelete, e.url(ta)+"/v1/files/"+hex.EncodeToString(sum[:]), nil)
	req.Header.Set("Authorization", "Bearer "+toka)
	resp, err := e.client.Do(req)
	if err != nil || resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete: %v %v", resp, err)
	}
	resp.Body.Close()
	if code, _, _ := e.postFile(ta, toka, strings.NewReader("cccccccc"), 8); code != http.StatusCreated {
		t.Fatalf("A after delete: %d", code)
	}
}
