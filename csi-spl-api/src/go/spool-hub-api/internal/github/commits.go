package github

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
)

// CommitInfo is one commit of the branch history, as the commit list shows it.
type CommitInfo struct {
	SHA     string
	Message string
	Author  Identity
}

// commitsPage is GitHub's page cap for the commit list.
const commitsPage = 100

// Commits lists up to n commits of the branch, newest first. The edit worker
// reads it for a commit naming an edit_id before it pushes a reclaimed edit
// again, and for the daily refresh of the history's authors (spec §4.1, §11).
func (c *Client) Commits(ctx context.Context, n int) ([]CommitInfo, error) {
	var out []CommitInfo
	for page := 1; len(out) < n; page++ {
		var got []struct {
			SHA    string `json:"sha"`
			Commit struct {
				Message string   `json:"message"`
				Author  Identity `json:"author"`
			} `json:"commit"`
		}
		q := url.Values{"sha": {c.branch}, "per_page": {strconv.Itoa(commitsPage)}, "page": {strconv.Itoa(page)}}
		if err := c.call(ctx, "commits", http.MethodGet, c.repoPath("/commits?"+q.Encode()), nil, &got); err != nil {
			return nil, err
		}
		for _, g := range got {
			out = append(out, CommitInfo{SHA: g.SHA, Message: g.Commit.Message, Author: g.Commit.Author})
		}
		if len(got) < commitsPage {
			break
		}
	}
	if len(out) > n {
		out = out[:n]
	}
	return out, nil
}
