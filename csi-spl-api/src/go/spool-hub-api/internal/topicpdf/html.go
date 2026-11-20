// SPDX-License-Identifier: AGPL-3.0-only

// Package topicpdf is the hub half of spec 183 (an agent exports a topic to
// PDF): the self-contained HTML of a topic as the WUI prints it (html.go,
// template.html, markdown.go), its title and file name (title.go, slug.go),
// and the seam to the renderer service that turns the HTML into a PDF
// (render.go). The renderer program itself is cmd/spool-pdf. No function
// here reads the store or the clock: the hub route (internal/hub, spec 183
// row P1) reads the rows and calls HTML, then a Renderer.
package topicpdf

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"html/template"
	"regexp"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// PictureMaxBytes is the largest picture that prints inline: the WUI's
// PREVIEW_MAX_BYTES (csi-spl-wui/src/utils/file-preview.ts). A larger one
// prints as its name.
const PictureMaxBytes = 10 * 1024 * 1024

// PicturesMaxBytes bounds the base64 of every picture of one export
// together (spec 183 7.1.6: 32 MiB of pictures in a body of at most 40 MiB).
// A picture past it prints as its name.
const PicturesMaxBytes = msg.MaxFileBytes

//go:embed template.html
var pageSource string

var page = template.Must(template.New("page").Parse(pageSource))

// imageExt is the WUI's IMAGE_EXT: the names that are fetched as pictures.
var imageExt = regexp.MustCompile(`(?i)\.(png|jpe?g|gif|webp|avif|bmp|ico|svg)$`)

// Option changes what HTML prints (spec 183 7.1.5).
type Option func(*htmlOpts)

type htmlOpts struct {
	link template.URL
}

// WithTopicLink sets url, the topic in the WUI, as the link printed after
// each attachment that is not inlined (spec 183 7.1.3). Without it, or with
// a url that is not http(s), an attachment prints its name only.
func WithTopicLink(url string) Option {
	return func(o *htmlOpts) {
		if strings.HasPrefix(url, "https://") || strings.HasPrefix(url, "http://") {
			o.link = template.URL(url) //nolint:gosec // G203: scheme checked above
		}
	}
}

type view struct {
	Title string
	Link  template.URL
	Cards []card
}

type card struct {
	MsgID, Author, ISO, Time, Kind string
	Body                           template.HTML
	Pictures                       []picture
	Files                          []string
}

type picture struct {
	Name string
	Src  template.URL
}

// HTML is the topic's self-contained page (spec 183 7.1.3, 7.1.5): the title,
// then one card per row in the order given (author, time, kind, the body's
// markdown), each picture inline as a data: URL read through blob, every
// other attachment as its name. It holds no remote resource. It answers the
// page and how many pictures it inlined. blob may be nil (no pictures); a
// picture blob fails to read, does not match its sha256, is not a picture or
// is over a cap: it prints as its name, never fails the export.
func HTML(rows []store.EditableMessage, title string, blob func(fileID string) ([]byte, error), opts ...Option) ([]byte, int, error) {
	if title == "" {
		title = "topic" // spec 183 v0.4 7.1.3: an empty title prints as "topic"
	}
	var o htmlOpts
	for _, opt := range opts {
		opt(&o)
	}
	v := view{Title: title, Link: o.link}
	budget, pictures := PicturesMaxBytes, 0
	for _, r := range rows {
		c := card{MsgID: r.MsgID, Author: r.FromID, ISO: r.TS.UTC().Format(time.RFC3339),
			Time: r.TS.UTC().Format("2006-01-02 15:04 UTC"), Kind: r.Kind, Body: Markdown(r.Body)}
		for _, a := range attachments(r.Msg) {
			src := pictureSrc(a, blob, budget)
			if src == "" {
				c.Files = append(c.Files, a.Name)
				continue
			}
			budget -= len(src)
			pictures++
			c.Pictures = append(c.Pictures, picture{Name: a.Name, Src: template.URL(src)}) //nolint:gosec // G203: built by pictureSrc from a sniffed type and base64
		}
		v.Cards = append(v.Cards, c)
	}
	var buf bytes.Buffer
	if err := page.Execute(&buf, v); err != nil {
		return nil, 0, err
	}
	return buf.Bytes(), pictures, nil
}

// attachments are the files of a stored inner message; none when it does not
// parse (the row still prints its body).
func attachments(inner []byte) []msg.Attachment {
	var m struct {
		Files []msg.Attachment `json:"files"`
	}
	if json.Unmarshal(inner, &m) != nil {
		return nil
	}
	return m.Files
}

// pictureSrc is a's data: URL, or "" when a prints as its name: not a blob
// file with a picture's name, over PictureMaxBytes or the budget left, a blob
// that fails to read, bytes that do not hash to its id, or no picture type.
func pictureSrc(a msg.Attachment, blob func(string) ([]byte, error), budget int) string {
	if blob == nil || a.Mode != "blob" || a.Kind == "dir" || a.FileID == "" ||
		!imageExt.MatchString(a.Name) || a.Bytes > PictureMaxBytes {
		return ""
	}
	data, err := blob(a.FileID)
	if err != nil || len(data) > PictureMaxBytes {
		return ""
	}
	want := a.SHA256
	if want == "" {
		want = a.FileID
	}
	sum := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(sum[:]), want) {
		return ""
	}
	mime := imageMime(data)
	if mime == "" {
		return ""
	}
	src := "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data)
	if len(src) > budget {
		return ""
	}
	return src
}

// imageMime is the Go port of the WUI's previewImageMime (file-preview.ts):
// the picture type the bytes start with, "" when none.
func imageMime(b []byte) string {
	switch {
	case bytes.HasPrefix(b, []byte{0x89, 'P', 'N', 'G'}):
		return "image/png"
	case bytes.HasPrefix(b, []byte{0xff, 0xd8, 0xff}):
		return "image/jpeg"
	case bytes.HasPrefix(b, []byte("GIF8")):
		return "image/gif"
	case bytes.HasPrefix(b, []byte("RIFF")) && len(b) >= 12 && string(b[8:12]) == "WEBP":
		return "image/webp"
	case len(b) >= 12 && (string(b[4:12]) == "ftypavif" || string(b[4:12]) == "ftypavis"):
		return "image/avif"
	case bytes.HasPrefix(b, []byte("BM")) && len(b) > 14:
		return "image/bmp"
	case bytes.HasPrefix(b, []byte{0, 0, 1, 0}):
		return "image/x-icon"
	}
	return svgMime(b)
}

var svgOpen = regexp.MustCompile(`<svg[\s>]`)

func svgMime(b []byte) string {
	head := b[:min(len(b), 1024)]
	s := strings.TrimLeft(strings.TrimPrefix(string(head), "\uFEFF"), " \t\r\n\f\v")
	if (strings.HasPrefix(s, "<svg") || strings.HasPrefix(s, "<?xml") || strings.HasPrefix(s, "<!--")) && svgOpen.MatchString(s) {
		return "image/svg+xml"
	}
	return ""
}
