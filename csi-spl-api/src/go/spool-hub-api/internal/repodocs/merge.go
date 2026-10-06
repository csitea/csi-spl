package repodocs

import (
	"bytes"
	"sort"
)

// The worker's 3-way merge (spec 075 repo-edit §8): base is the text the
// editor started from, theirs is master's head, mine is the save. A change on
// one side only is taken; the same change on both sides is taken once; any
// other two changes that overlap or touch is a conflict, and nothing is
// pushed. Line based, like diff3 and git: two edits on adjacent lines
// conflict.

// maxMergeEdits bounds the diff of one side against base. A save that
// rewrites more lines than this while master also moved is a conflict: the
// editor resolves it by hand instead of the worker guessing.
const maxMergeEdits = 4000

// hunk replaces base lines [o1, o2) by side lines [s1, s2).
type hunk struct {
	o1, o2, s1, s2 int
	side           int // 0 theirs, 1 mine
}

// Merge3 merges theirs and mine over base. ok false: a conflict.
func Merge3(base, theirs, mine []byte) ([]byte, bool) {
	if bytes.Equal(theirs, mine) || bytes.Equal(base, mine) {
		return theirs, true
	}
	if bytes.Equal(base, theirs) {
		return mine, true
	}
	o, sides := splitKeep(base), [2][]string{splitKeep(theirs), splitKeep(mine)}
	var hs []hunk
	for side, lines := range sides {
		h, ok := diffHunks(o, lines, side)
		if !ok {
			return nil, false
		}
		hs = append(hs, h...)
	}
	sort.SliceStable(hs, func(i, j int) bool { return hs[i].o1 < hs[j].o1 })
	var out bytes.Buffer
	pos := 0
	for i := 0; i < len(hs); {
		j, lo, hi := groupEnd(hs, i)
		writeLines(&out, o[pos:lo])
		text, ok := resolveGroup(o, sides, hs[i:j], lo, hi)
		if !ok {
			return nil, false
		}
		out.WriteString(text)
		pos, i = hi, j
	}
	writeLines(&out, o[pos:])
	return out.Bytes(), true
}

// groupEnd joins hunks whose base ranges overlap or touch, from i on; it
// returns the end index and the group's base range.
func groupEnd(hs []hunk, i int) (int, int, int) {
	lo, hi := hs[i].o1, hs[i].o2
	j := i + 1
	for ; j < len(hs) && hs[j].o1 <= hi; j++ {
		if hs[j].o2 > hi {
			hi = hs[j].o2
		}
	}
	return j, lo, hi
}

// resolveGroup is the text of base [lo, hi) after the group's hunks: one
// side's when only one side changed it, the shared text when both sides made
// the same change, else a conflict.
func resolveGroup(o []string, sides [2][]string, g []hunk, lo, hi int) (string, bool) {
	var by [2][]hunk
	for _, h := range g {
		by[h.side] = append(by[h.side], h)
	}
	var text [2]string
	for side := range by {
		text[side] = applyHunks(o, sides[side], by[side], lo, hi)
	}
	switch {
	case len(by[0]) == 0:
		return text[1], true
	case len(by[1]) == 0:
		return text[0], true
	case text[0] == text[1]:
		return text[0], true
	}
	return "", false
}

// applyHunks is base [lo, hi) with one side's hunks applied.
func applyHunks(o, side []string, hs []hunk, lo, hi int) string {
	var b bytes.Buffer
	pos := lo
	for _, h := range hs {
		writeLines(&b, o[pos:h.o1])
		writeLines(&b, side[h.s1:h.s2])
		pos = h.o2
	}
	writeLines(&b, o[pos:hi])
	return b.String()
}

func writeLines(b *bytes.Buffer, lines []string) {
	for _, l := range lines {
		b.WriteString(l)
	}
}

// splitKeep splits after each newline, keeping it, so the merged bytes keep
// the text's own line ends and its last line with or without one.
func splitKeep(b []byte) []string {
	var out []string
	for len(b) > 0 {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			out = append(out, string(b))
			break
		}
		out = append(out, string(b[:i+1]))
		b = b[i+1:]
	}
	return out
}

// diffHunks is the change of side against base as hunks; ok false when the
// diff is longer than maxMergeEdits.
func diffHunks(o, s []string, side int) ([]hunk, bool) {
	pre := 0
	for pre < len(o) && pre < len(s) && o[pre] == s[pre] {
		pre++
	}
	suf := 0
	for suf < len(o)-pre && suf < len(s)-pre && o[len(o)-1-suf] == s[len(s)-1-suf] {
		suf++
	}
	pairs, ok := myersPairs(o[pre:len(o)-suf], s[pre:len(s)-suf])
	if !ok {
		return nil, false
	}
	var hs []hunk
	oi, si := 0, 0
	for _, p := range append(pairs, [2]int{len(o) - pre - suf, len(s) - pre - suf}) {
		if p[0] > oi || p[1] > si {
			hs = append(hs, hunk{o1: pre + oi, o2: pre + p[0], s1: pre + si, s2: pre + p[1], side: side})
		}
		oi, si = p[0]+1, p[1]+1
	}
	return hs, true
}

// myersPairs is the matched line pairs (i in a, j in b) of a shortest edit
// script (Myers 1986), in order; ok false past maxMergeEdits edits.
func myersPairs(a, b []string) ([][2]int, bool) {
	n, m := len(a), len(b)
	off := n + m + 1
	v := make([]int, 2*off+1)
	var trace [][]int
	for d := 0; d <= n+m; d++ {
		if d > maxMergeEdits {
			return nil, false
		}
		trace = append(trace, append([]int(nil), v[off-d:off+d+1]...))
		for k := -d; k <= d; k += 2 {
			x := v[off+k-1] + 1
			if k == -d || (k != d && v[off+k-1] < v[off+k+1]) {
				x = v[off+k+1]
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x, y = x+1, y+1
			}
			v[off+k] = x
			if x >= n && y >= m {
				return backtrack(trace, n, m), true
			}
		}
	}
	return nil, true
}

// backtrack walks the trace from (n, m) back to (0, 0), collecting the
// diagonal (matched) moves. trace[d] holds v[-d..d] as it was before step d.
func backtrack(trace [][]int, n, m int) [][2]int {
	var rev [][2]int
	x, y := n, m
	for d := len(trace) - 1; d >= 0; d-- {
		v := func(k int) int { return trace[d][k+d] }
		k := x - y
		pk := k - 1
		if k == -d || (k != d && v(k-1) < v(k+1)) {
			pk = k + 1
		}
		px := 0
		if d > 0 {
			px = v(pk)
		}
		py := px - pk
		if d == 0 {
			py = 0
		}
		for x > px && y > py {
			x, y = x-1, y-1
			rev = append(rev, [2]int{x, y})
		}
		x, y = px, py
	}
	out := make([][2]int, len(rev))
	for i := range rev {
		out[i] = rev[len(rev)-1-i]
	}
	return out
}
