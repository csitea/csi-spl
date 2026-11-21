package hub

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Media in the Qto docs (spec 190 v1.0, rows H1 and H2; owner HUM-10, t1
// bc3df46d, msgs b04212f4 and 653f9c91: Q1 A, Q2 B, Q3 A, Q4 B, Q6 A):
//
//	POST /v1/workspace/doctree/{doc}/media[?filename=<name>]  the raw bytes (C2)
//
// The bytes go to the workspace's own docs bucket (step 052) at
// qto-media/<doc>/<sha256>.<ext>, one key per document: deleting a document
// then deletes its files, and a sha256 known from another document names
// nothing here. The media index (store DocMediaPut, rdb 0306) records the
// file under its document. The body is streamed to a scratch key while it is
// hashed, never held in memory, then promoted. Who: as every doctree route
// (docTreeCaller with docs.write, then DocHeadOf under the human_lock mark);
// a refused doc is the same 404 as an unknown one.
//
// Types and caps (C3): a picture png/jpeg/gif/webp 5 MiB, a video mp4/webm
// or an audio mp3/m4a/ogg/wav 32 MiB, each sniffed from its first bytes and
// matching the sent Content-Type (415 bad_media). Any other Content-Type is
// kind "file", 32 MiB, never sniffed for a type, stored as
// application/octet-stream; its extension comes from ?filename=, and the
// deny list (cnf SPOOL_HUB_DOC_MEDIA_DENY) and an executable's magic number
// refuse it (415 denied_type). SVG and HTML are only ever kind "file".
//
// Measured on dev 2026-11-21 (gap G8, n=1 per size, POST /v1/files with no
// token): a body of 33 554 000 bytes reached the hub (401), one of
// 33 554 432 (exactly 32 MiB) got Cloud Run's own HTML 413. So a file of
// exactly 32 MiB is refused in front of the hub; the cap below still holds
// for lde and for any other front end.
//
// H2's seam: POST .../media/{name}/url goes in this file. Its door is
// docMediaDoor with rbac.DocsRead plus store DocMediaNamed for {name}; its
// signed response type is docMediaExtType[ext] for a media kind and
// application/octet-stream + attachment for kind "file" (C5, C10).

// DocMediaPrefix is where a workspace's doc media sit in its own docs store.
const DocMediaPrefix = "qto-media/"

// docMediaScratch is where an upload is streamed before its sha256 is known;
// the sweep removes what a crashed hub left there after FileOrphanGrace.
const docMediaScratch = "qto-media.tmp/"

// DocMediaMax caps a video, an audio or any other file (Q3 A); a picture
// keeps DocTreeImageMax.
const DocMediaMax = 32 << 20

// DocMediaGrace is how long a file no doc names is kept (Q6 A).
const DocMediaGrace = 7 * 24 * time.Hour

// DefaultDocMediaDeny is the deny list of C3 when the cnf sets none.
var DefaultDocMediaDeny = []string{"exe", "msi", "bat", "cmd", "com", "scr", "ps1", "vbs", "js", "jar", "apk", "dmg", "app", "sh"}

// docMediaKey is the store key of one media file of doc.
func docMediaKey(doc, name string) string { return DocMediaPrefix + doc + "/" + name }

// docMediaType is one sendable media type: its kind, stored extension, cap
// and the check of its first bytes.
type docMediaType struct {
	kind, ext string
	max       int64
	sniff     func(head []byte) bool
}

func sniffIs(want string) func([]byte) bool {
	return func(b []byte) bool { return http.DetectContentType(b) == want }
}

func sniffPrefix(p ...string) func([]byte) bool {
	return func(b []byte) bool {
		for _, x := range p {
			if bytes.HasPrefix(b, []byte(x)) {
				return true
			}
		}
		return false
	}
}

// sniffFtyp: an ISO base media file (mp4, m4a): a box whose type is ftyp.
func sniffFtyp(b []byte) bool { return len(b) >= 12 && string(b[4:8]) == "ftyp" }

// sniffMP3: an ID3 tag or an MPEG audio frame sync.
func sniffMP3(b []byte) bool {
	return bytes.HasPrefix(b, []byte("ID3")) || len(b) >= 2 && b[0] == 0xff && b[1]&0xe0 == 0xe0
}

// sniffWAV: a RIFF container of WAVE.
func sniffWAV(b []byte) bool {
	return len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WAVE"
}

// docMediaTypes is C3's media table, by the sent Content-Type.
var docMediaTypes = map[string]docMediaType{
	"image/png":  {"image", "png", DocTreeImageMax, sniffIs("image/png")},
	"image/jpeg": {"image", "jpg", DocTreeImageMax, sniffIs("image/jpeg")},
	"image/gif":  {"image", "gif", DocTreeImageMax, sniffIs("image/gif")},
	"image/webp": {"image", "webp", DocTreeImageMax, sniffIs("image/webp")},
	"video/mp4":  {"video", "mp4", DocMediaMax, sniffFtyp},
	"video/webm": {"video", "webm", DocMediaMax, sniffPrefix("\x1a\x45\xdf\xa3")},
	"audio/mpeg": {"audio", "mp3", DocMediaMax, sniffMP3},
	"audio/mp4":  {"audio", "m4a", DocMediaMax, sniffFtyp},
	"audio/ogg":  {"audio", "ogg", DocMediaMax, sniffPrefix("OggS")},
	"audio/wav":  {"audio", "wav", DocMediaMax, sniffWAV},
}

// docMediaExtType is a media extension's type, the one a signed URL pins.
var docMediaExtType = func() map[string]string {
	m := map[string]string{"jpeg": "image/jpeg"}
	for t, d := range docMediaTypes {
		m[d.ext] = t
	}
	return m
}()

// sniffExecutable: a Windows PE, an ELF or a Mach-O (fat or thin) binary.
var sniffExecutable = sniffPrefix("MZ", "\x7fELF", "\xfe\xed\xfa\xce", "\xfe\xed\xfa\xcf", "\xce\xfa\xed\xfe", "\xcf\xfa\xed\xfe", "\xca\xfe\xba\xbe")

var docMediaFileExt = regexp.MustCompile(`^[a-z0-9]{1,16}$`)

// docMediaUpload is one upload's resolved type and the name it was sent as.
type docMediaUpload struct {
	docMediaType
	name string // the sent file name, "" = none
	tmp  string // its scratch key, once streamed
	sha  string
	n    int64
}

// docMediaTypeOf resolves the upload's type from its Content-Type and
// ?filename=, or writes the refusal. Kind "file" takes its extension from
// the name ("bin" when it has none, or when it is a media extension that was
// not sent as that type: a file never renders inline).
func (s *Server) docMediaTypeOf(w http.ResponseWriter, r *http.Request) (docMediaUpload, bool) {
	name := docMediaFileName(r.URL.Query().Get("filename"))
	sent, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if t, ok := docMediaTypes[sent]; ok {
		return docMediaUpload{docMediaType: t, name: name}, true
	}
	ext := strings.TrimPrefix(strings.ToLower(path.Ext(name)), ".")
	for _, d := range s.docMediaDeny() {
		if ext == d {
			writeErr(w, http.StatusUnsupportedMediaType, "denied_type", "this file type is not allowed in a document: ."+ext)
			return docMediaUpload{}, false
		}
	}
	if !docMediaFileExt.MatchString(ext) || docMediaExtType[ext] != "" {
		ext = "bin"
	}
	return docMediaUpload{docMediaType: docMediaType{kind: "file", ext: ext, max: DocMediaMax}, name: name}, true
}

// docMediaFileName is the base name of a sent file name, control characters
// dropped, at most 255 bytes.
func docMediaFileName(n string) string {
	n = n[strings.LastIndexAny(n, `/\`)+1:]
	n = strings.Map(func(c rune) rune {
		if c < 0x20 || c == 0x7f {
			return -1
		}
		return c
	}, strings.TrimSpace(n))
	if len(n) > 255 {
		n = n[:255]
	}
	return n
}

// docMediaDeny is the cnf deny list, or DefaultDocMediaDeny.
func (s *Server) docMediaDeny() []string {
	if len(s.o.DocMediaDeny) > 0 {
		return s.o.DocMediaDeny
	}
	return DefaultDocMediaDeny
}

// docMediaStore is the store side of the media routes.
type docMediaStore interface {
	DocMediaPut(ctx context.Context, tenant string, m store.DocMedia) (store.DocMedia, bool, error)
	DocMediaDrop(ctx context.Context, tenant, doc, sha string) error
	DocMediaNamed(ctx context.Context, tenant, doc, name string) (store.DocMedia, error)
}

var _ docMediaStore = (*store.Postgres)(nil)

// docMediaDoor resolves the caller (perm), the doc (its tenant's and
// visible to the caller, else 404), the workspace's own docs store and the
// media index, or writes the refusal (C1). Tenant "system" has no own
// store: the repo docs take no media.
func (s *Server) docMediaDoor(w http.ResponseWriter, r *http.Request, perm string) (docTreeCall, string, blob.Store, docMediaStore, bool) {
	c, ok := s.docTreeCaller(w, r, perm)
	if !ok {
		return c, "", nil, nil, false
	}
	ms, on := s.o.Store.(docMediaStore)
	st, own, err := s.docAssetBucket(r.Context(), c.tenant)
	if !on || !own {
		writeErr(w, http.StatusNotFound, "media_off", "this hub or this tree has no doc media store")
		return c, "", nil, nil, false
	}
	h, err2 := c.st.DocHeadOf(r.Context(), c.tenant, r.PathValue("doc"))
	if err2 != nil {
		docTreeFail(w, err2)
		return c, "", nil, nil, false
	}
	if err != nil {
		s.docsUnavailable(w, c.tenant, "open", err)
		return c, "", nil, nil, false
	}
	return c, h.ID, st, ms, true
}

func (s *Server) handleDocTreeMediaPut(w http.ResponseWriter, r *http.Request) {
	c, doc, st, ms, ok := s.docMediaDoor(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	up, ok := s.docMediaTypeOf(w, r)
	if !ok || !s.docMediaFitsDeclared(w, r, c.tenant, up.max) {
		return
	}
	bg := context.WithoutCancel(r.Context()) // cleanup outlives a client gone mid-body
	if !docMediaStream(bg, w, r, st, &up) {
		return
	}
	s.docMediaKeep(bg, w, r, docMediaKeepIn{c: c, doc: doc, st: st, ms: ms, up: up})
}

// docMediaFitsDeclared refuses, before any byte is read, a declared length
// over the type's cap (413 too_large) or the workspace's file quota.
func (s *Server) docMediaFitsDeclared(w http.ResponseWriter, r *http.Request, tenant string, max int64) bool {
	if r.ContentLength > max {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("this type is at most %d bytes", max))
		return false
	}
	if r.ContentLength <= 0 || s.quota().FileBytes <= 0 {
		return true
	}
	if s.o.Blob == nil {
		writeErr(w, http.StatusNotFound, "files_off", "this hub has no object store")
		return false
	}
	over, err := s.fileUsage.over(r.Context(), s.o.Blob, s.quota(), tenant, r.ContentLength, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("blob prefix bytes")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return false
	}
	if over {
		writeQuota(w, "stored file bytes exceed the workspace quota")
		return false
	}
	return true
}

// docMediaStream checks the first bytes (a media kind's sniff, a file's
// executable magic), then streams the whole body, capped at the type's max,
// to a scratch key of st while hashing it. false has written the refusal.
func docMediaStream(bg context.Context, w http.ResponseWriter, r *http.Request, st blob.Store, up *docMediaUpload) bool {
	body := &readErr{r: http.MaxBytesReader(w, r.Body, up.max)}
	head := make([]byte, 512)
	k, _ := io.ReadFull(body, head)
	head = head[:k]
	switch {
	case docMediaTooLarge(body.err):
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("this type is at most %d bytes", up.max))
		return false
	case k == 0:
		writeErr(w, http.StatusBadRequest, "bad_body", "the file bytes did not arrive")
		return false
	case up.kind != "file" && !up.sniff(head):
		writeErr(w, http.StatusUnsupportedMediaType, "bad_media", "the bytes are not the type they were sent as")
		return false
	case up.kind == "file" && sniffExecutable(head):
		writeErr(w, http.StatusUnsupportedMediaType, "denied_type", "an executable is not allowed in a document")
		return false
	}
	up.tmp = docMediaScratch + uid.Hex(16)
	h := sha256.New()
	n, err := st.PutReader(r.Context(), up.tmp, io.TeeReader(io.MultiReader(bytes.NewReader(head), body), h))
	if err == nil {
		up.sha, up.n = hex.EncodeToString(h.Sum(nil)), n
		return true
	}
	st.Delete(bg, up.tmp) //nolint:errcheck // PutReader leaves nothing; belt and braces
	switch {
	case docMediaTooLarge(body.err):
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("this type is at most %d bytes", up.max))
	case body.err != nil:
		writeErr(w, http.StatusBadRequest, "bad_body", "could not read the body")
	default:
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
	}
	return false
}

func docMediaTooLarge(err error) bool {
	var mbe *http.MaxBytesError
	return errors.As(err, &mbe)
}

// docMediaKeepIn is one streamed upload on its way to its key.
type docMediaKeepIn struct {
	c   docTreeCall
	doc string
	st  blob.Store
	ms  docMediaStore
	up  docMediaUpload
}

// docMediaKeep reserves the quota, indexes the file under its doc, then
// promotes the scratch object to qto-media/<doc>/<name>. Bytes already there
// give back their reservation, restart their grace and answer 200; new ones
// 201. A failure removes the scratch object, the reservation and a row it
// wrote.
func (s *Server) docMediaKeep(bg context.Context, w http.ResponseWriter, r *http.Request, k docMediaKeepIn) {
	tenant, up := k.c.tenant, k.up
	drop := func() { k.st.Delete(bg, up.tmp) } //nolint:errcheck
	fits, err := true, error(nil)
	if s.o.Blob != nil {
		fits, err = s.fileUsage.reserve(r.Context(), s.o.Blob, s.quota(), tenant, up.n, s.o.Now())
	}
	if err != nil || !fits {
		drop()
		if err != nil {
			s.o.Log.Error().Err(err).Msg("blob prefix bytes")
			writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		} else {
			writeQuota(w, "stored file bytes exceed the workspace quota")
		}
		return
	}
	m, created, err := k.ms.DocMediaPut(r.Context(), tenant, store.DocMedia{Doc: k.doc, SHA256: up.sha, Ext: up.ext,
		Kind: up.kind, Bytes: up.n, Name: up.name, CreatedBy: k.c.who})
	if err != nil {
		drop()
		s.fileUsage.release(tenant, up.n)
		docTreeFail(w, err)
		return
	}
	key := docMediaKey(k.doc, m.FileName())
	existed, err := blob.PromoteNew(bg, k.st, up.tmp, key)
	if err != nil || existed {
		s.fileUsage.release(tenant, up.n)
	}
	if err != nil {
		drop()
		if created {
			k.ms.DocMediaDrop(bg, tenant, k.doc, up.sha) //nolint:errcheck // the sweep drops it otherwise
		}
		s.docsUnavailable(w, tenant, "promote media "+m.FileName(), err)
		return
	}
	code := http.StatusCreated
	if existed {
		code = http.StatusOK
		if err := k.st.Touch(bg, key); err != nil {
			s.o.Log.Warn().Err(err).Str("workspace", tenant).Str("name", m.FileName()).Msg("doc media touch")
		}
	}
	writeJSON(w, code, map[string]any{"name": m.FileName(), "bytes": m.Bytes, "kind": m.Kind,
		"http_path": store.DocImagePathPrefix + k.doc + "/media/" + m.FileName()})
}
