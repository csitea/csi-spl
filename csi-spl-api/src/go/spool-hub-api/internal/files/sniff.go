package files

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"regexp"
	"unicode/utf8"
)

// Repairing the nameless attachments (SPL-1808, owner HUM-10 t1 4f98d07c msg
// f5564d9f "Go"): before SPL-1776 a blob attached by id was named by its own
// sha256, so the WUI, which picks preview and icon by the name's extension,
// offered every such picture as a nameless download. The bytes are intact;
// these helpers find what they are and give them a name with an extension.

// sniffLen is how much of a blob SniffExt reads: enough for every magic
// number below and for a fair look at a text file.
const sniffLen = 8192

// SniffExt is the file extension the bytes at path are, without the dot, or
// "" when they are none it knows. It reads magic numbers, never the name.
func SniffExt(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b := make([]byte, sniffLen)
	n, err := io.ReadFull(f, b)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		return "", err
	}
	return SniffBytes(b[:n], n < sniffLen), nil
}

var magics = []struct {
	at  int
	sig string
	ext string
}{
	{0, "\x89PNG\r\n\x1a\n", "png"},
	{0, "\xff\xd8\xff", "jpg"},
	{0, "GIF87a", "gif"},
	{0, "GIF89a", "gif"},
	{0, "%PDF-", "pdf"},
	{0, "PK\x03\x04", "zip"},
	{0, "PK\x05\x06", "zip"},
	{0, "\x1f\x8b", "gz"},
	{0, "BM", "bmp"},
	{0, "\x00\x00\x01\x00", "ico"},
	{0, "7z\xbc\xaf\x27\x1c", "7z"},
	{0, "\x28\xb5\x2f\xfd", "zst"},
	{0, "\xfd7zXZ\x00", "xz"},
	{0, "OggS", "ogg"},
	{0, "ID3", "mp3"},
	{0, "\x1aE\xdf\xa3", "webm"},
	{257, "ustar", "tar"},
}

// markdownLine is a line only markdown starts like: a heading, a fence, a
// table rule, a list item or a quote.
var markdownLine = regexp.MustCompile("(?m)^(#{1,6} |```|\\|?\\s*:?-{3,}:?\\s*\\||[-*] |> )")

// SniffBytes is SniffExt on bytes already read; full says b is the whole file.
func SniffBytes(b []byte, full bool) string {
	for _, m := range magics {
		if len(b) >= m.at+len(m.sig) && string(b[m.at:m.at+len(m.sig)]) == m.sig {
			return m.ext
		}
	}
	if len(b) >= 12 && string(b[0:4]) == "RIFF" {
		switch string(b[8:12]) {
		case "WEBP":
			return "webp"
		case "WAVE":
			return "wav"
		}
	}
	if len(b) >= 12 && string(b[4:8]) == "ftyp" {
		switch string(b[8:12]) {
		case "avif", "avis":
			return "avif"
		case "heic", "heix", "mif1":
			return "heic"
		case "qt  ":
			return "mov"
		}
		return "mp4"
	}
	return sniffText(b, full)
}

// sniffText names a text file: svg, json, md or txt. Bytes with a NUL or
// that are not UTF-8 are no text it names.
func sniffText(b []byte, full bool) string {
	if len(b) == 0 || bytes.IndexByte(b, 0) >= 0 {
		return ""
	}
	t := b
	for i := 0; !full && i < utf8.UTFMax && len(t) > 0 && !utf8.Valid(t); i++ {
		t = t[:len(t)-1] // a cut may split the last rune
	}
	if !utf8.Valid(t) {
		return ""
	}
	s := bytes.TrimSpace(bytes.TrimPrefix(t, []byte("\xef\xbb\xbf")))
	low := bytes.ToLower(s)
	if bytes.HasPrefix(low, []byte("<svg")) || bytes.HasPrefix(low, []byte("<?xml")) && bytes.Contains(low, []byte("<svg")) {
		return "svg"
	}
	if full && len(s) > 0 && (s[0] == '{' || s[0] == '[') && json.Valid(s) {
		return "json"
	}
	if markdownLine.Match(s) {
		return "md"
	}
	return "txt"
}

// IsHashName reports whether name is the lower-case 64-hex sha256 a by-id
// attachment was named with before SPL-1776, and that sha is the file's own.
func IsHashName(name, fileID, sha string) bool {
	return isSHA256Hex(name) && name == string(bytes.ToLower([]byte(name))) && (name == fileID || name == sha)
}

// RepairedName is the name a nameless blob gets: file-<first 12 hex>.<ext>.
func RepairedName(fileID, ext string) string {
	short := fileID
	if len(short) > 12 {
		short = short[:12]
	}
	return "file-" + short + "." + ext
}
