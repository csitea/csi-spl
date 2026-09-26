package search

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// Fold is the language-neutral match form of one word (1.1, CLE-34992):
// lower-cased and with its accents removed, the way Postgres unaccent does it
// in the spool_search configuration (rdb 0047). So cafe finds café, strasse
// finds Straße and resume finds résumé in every one of the 19 WUI locales,
// without guessing the language of a message. Marks are stripped from Latin
// and Greek letters only, plus ё, as unaccent.rules does; й, Hangul and
// Devanagari keep theirs, because there a mark is part of the letter.
func Fold(s string) string {
	s = strings.ToLower(s)
	if isASCII(s) {
		return s
	}
	var b strings.Builder
	var base rune = -1
	for _, r := range norm.NFD.String(s) {
		if unicode.Is(unicode.Mn, r) {
			if base >= 0 && (unicode.Is(unicode.Latin, base) || unicode.Is(unicode.Greek, base) || (base == 'е' && r == '̈')) {
				continue
			}
			b.WriteRune(r)
			continue
		}
		base = r
		if rep, ok := foldLigatures[r]; ok {
			b.WriteString(rep)
			continue
		}
		b.WriteRune(r)
	}
	return norm.NFC.String(b.String())
}

// foldLigatures are the unaccent.rules letters that do not decompose.
var foldLigatures = map[rune]string{
	'ß': "ss", 'æ': "ae", 'œ': "oe", 'ø': "o", 'đ': "d", 'ð': "d", 'ł': "l", 'ı': "i", 'ħ': "h", 'ŧ': "t",
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}
