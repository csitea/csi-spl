package main

import (
	"fmt"
	"regexp"
	"strings"
)

// The Markdown export of a workspace document: a port of the WUI's
// "export to md" (csi-spl-wui/src/components/workspace-docs/-doctree-export.ts
// branchToMarkdown, with -doc-pics.ts for the pictures and the en strings
// ws_doctree.untitled / ws_doctree.figure), so a copy made by the CLI is the
// file the WUI saves. Change both together.
//
// Per item, in document order: a heading (# by level, from the branch's top
// level, at most ######) with the outline number and the title; the body
// with each picture token followed by its "*Figure N: caption*" line; the
// code block (attrs.src) fenced with ``` (the WUI writes no language); the
// section image (attrs.img_http_path) as a token and its figure line. Figure
// numbers run through the whole document, inline pictures first, then the
// item's image.

const (
	docTreeUntitled = "Untitled"   // en ws_doctree.untitled
	docTreeFigure   = "Figure %d:" // en ws_doctree.figure
)

// docTreePicRe is -doc-pics.ts TOKEN: ![caption](/v1/workspace/doctree/<doc>/images/<sha256>.<ext>).
var docTreePicRe = regexp.MustCompile(`!\[([^\]\n]*)\]\((/v1/workspace/doctree/([^/\s()]+)/images/[0-9a-f]{64}\.(?:png|jpg|gif|webp))\)`)

var spaceRunRe = regexp.MustCompile(`\s+`)

// cleanCaption is -doc-pics.ts cleanCaption: one line, no square brackets.
func cleanCaption(caption string) string {
	caption = strings.NewReplacer("[", "", "]", "").Replace(caption)
	return strings.TrimSpace(spaceRunRe.ReplaceAllString(caption, " "))
}

// picToken is -doc-pics.ts picToken.
func picToken(caption, path string) string {
	return "![" + cleanCaption(caption) + "](" + path + ")"
}

// picRun is one run of a body: text, or one of the doc's pictures.
type picRun struct {
	pic           bool
	text, caption string
	path          string
}

// picRuns is -doc-pics.ts picRuns: another document's token stays text.
func picRuns(body, doc string) []picRun {
	var out []picRun
	at := 0
	for _, m := range docTreePicRe.FindAllStringSubmatchIndex(body, -1) {
		if body[m[6]:m[7]] != doc {
			continue
		}
		if m[0] > at {
			out = append(out, picRun{text: body[at:m[0]]})
		}
		out = append(out, picRun{pic: true, caption: strings.TrimSpace(body[m[2]:m[3]]), path: body[m[4]:m[5]]})
		at = m[1]
	}
	if at < len(body) {
		out = append(out, picRun{text: body[at:]})
	}
	return out
}

// docFig is one item's figure numbers: its first inline picture, its image (0 = none).
type docFig struct{ first, image int }

// figureNumbers is -doc-pics.ts figureNumbers, over the whole document.
func figureNumbers(items []dtItem, doc string) map[string]docFig {
	out := make(map[string]docFig, len(items))
	n := 0
	for _, it := range items {
		first := n + 1
		for _, r := range picRuns(it.Body, doc) {
			if r.pic {
				n++
			}
		}
		image := 0
		if it.attr("img_http_path") != "" {
			n++
			image = n
		}
		out[it.ID] = docFig{first: first, image: image}
	}
	return out
}

func figureLabel(n int) string { return fmt.Sprintf(docTreeFigure, n) }

// bodyWithFigures is the paragraph with each picture's token followed by its figure line.
func bodyWithFigures(it dtItem, doc string, figs map[string]docFig) string {
	n := 1
	if f, ok := figs[it.ID]; ok {
		n = f.first
	}
	var b strings.Builder
	for _, r := range picRuns(it.Body, doc) {
		if !r.pic {
			b.WriteString(r.text)
			continue
		}
		fmt.Fprintf(&b, "%s\n\n*%s %s*\n", picToken(r.caption, r.path), figureLabel(n), r.caption)
		n++
	}
	return b.String()
}

// docTreeBranch is the item and everything under it (WorkspaceDocView branchOf).
func docTreeBranch(items []dtItem, item string) ([]dtItem, error) {
	if item == "" {
		return items, nil
	}
	var top *dtItem
	for i := range items {
		if items[i].ID == item {
			top = &items[i]
		}
	}
	if top == nil {
		return nil, fmt.Errorf("404: no item %s in the document", item)
	}
	var out []dtItem
	for _, x := range items {
		if x.ID == top.ID || strings.HasPrefix(x.Outline, top.Outline+".") {
			out = append(out, x)
		}
	}
	return out, nil
}

// docTreeMarkdown is branchToMarkdown over the whole document's items (in
// document order, without the hidden root), for item's branch ("" = all).
func docTreeMarkdown(items []dtItem, doc, item string) (string, error) {
	branch, err := docTreeBranch(items, item)
	if err != nil || len(branch) == 0 {
		return "", err
	}
	figs := figureNumbers(items, doc)
	base := branch[0].Depth
	for _, it := range branch {
		base = min(base, it.Depth)
	}
	var out []string
	for _, it := range branch {
		title := it.Title
		if title == "" {
			title = docTreeUntitled
		}
		level := min(6, it.Depth-base+1)
		out = append(out, strings.Repeat("#", level)+" "+it.Outline+" "+title, "")
		if body := strings.TrimSpace(bodyWithFigures(it, doc, figs)); body != "" {
			out = append(out, body, "")
		}
		if src := it.attr("src"); src != "" {
			out = append(out, "```", src, "```", "")
		}
		if img, n := it.attr("img_http_path"), figs[it.ID].image; img != "" && n > 0 {
			name := it.attr("img_name")
			out = append(out, picToken(name, img), "", "*"+figureLabel(n)+" "+name+"*", "")
		}
	}
	return strings.Join(out, "\n"), nil
}
