// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Tags on channel topics (spec 196 v0.3 sections 2.1-2.3, row T1, rdb 0328,
// SPL-6562). A workspace has one tag list (form dece6b4a #2A); a tag is its
// canonical slug only, always lower case (form 115fd5b2 #2A), made the first
// time someone types it on a topic (dece6b4a #3A) and pruned when no topic
// uses it any more. Who may tag a topic, and that it is a channel topic, is
// the hub's (row T3).

// Topic tag bounds (spec 196 2.3, rdb 0328's CHECK).
const (
	TopicTagMaxRunes = 40
	TopicTagMaxBytes = 128
	TopicTagsMax     = 10 // per topic, as calendar tags (rdb 0296)
)

// ErrBadTopicTag refuses a tag that does not normalise to a slug (the hub
// answers 400 bad_tag).
var ErrBadTopicTag = errors.New("store: bad topic tag")

// ErrTooManyTopicTags refuses an 11th tag on a topic (400 too_many_tags).
var ErrTooManyTopicTags = errors.New("store: a topic has at most 10 tags")

// NormalizeTopicTag is the one slug rule of every tag write and query: NFC,
// trimmed, leading '#' stripped, lower case (NFC again, so a decomposed e +
// U+0301 equals é), whitespace runs one '-', '-' runs one '-', no '-' at
// either end. What is left is letters, digits, '-', '_', '.' and the
// combining marks that follow a letter (Turkish i + U+0307 from 'İ'), with
// at least one letter or digit, 1..40 runes and 128 bytes. A ',' is refused:
// it separates the tags of a multi-tag URL (spec 196 D3, D8).
func NormalizeTopicTag(raw string) (string, error) {
	s := strings.TrimSpace(norm.NFC.String(raw))
	s = strings.TrimSpace(strings.TrimLeft(s, "#"))
	s = norm.NFC.String(strings.ToLower(s))
	s = strings.Trim(dashRuns(s), "-")
	if !topicTagRunes(s) {
		return "", ErrBadTopicTag
	}
	if n := utf8.RuneCountInString(s); n < 1 || n > TopicTagMaxRunes || len(s) > TopicTagMaxBytes {
		return "", ErrBadTopicTag
	}
	return s, nil
}

// dashRuns makes each run of whitespace and '-' one '-'.
func dashRuns(s string) string {
	var b strings.Builder
	dash := false
	for _, r := range s {
		if unicode.IsSpace(r) || r == '-' {
			dash = true
			continue
		}
		if dash {
			b.WriteByte('-')
			dash = false
		}
		b.WriteRune(r)
	}
	if dash {
		b.WriteByte('-')
	}
	return b.String()
}

// topicTagRunes: only the allowed runes, a mark only after a letter or a
// mark, and at least one letter or digit.
func topicTagRunes(s string) bool {
	word, prevLetter := false, false
	for _, r := range s {
		switch {
		case unicode.IsLetter(r) || unicode.IsNumber(r):
			word, prevLetter = true, unicode.IsLetter(r)
		case unicode.Is(unicode.Mn, r) && prevLetter:
		case r == '-' || r == '_' || r == '.':
			prevLetter = false
		default:
			return false
		}
	}
	return word
}

// TopicTagLink is one tag of a topic: its slug, who added it and when.
type TopicTagLink struct {
	Slug    string
	AddedBy string
	AddedAt time.Time
}

// TopicTagChange is what an add or a remove did: the slug it normalised to,
// whether it changed the topic (false: already there, or not there), and
// the topic's slugs after it, sorted.
type TopicTagChange struct {
	TaskID  string
	Slug    string
	Changed bool
	Tags    []string
}

// TopicTagStore is implemented by Memory and Postgres, in the workspace's
// own scope. Every write first takes the topic's topic_tag_stamps row (the
// per-topic lock, spec 196 2.3 rule 1), so two writes on one topic run one
// after the other and the cap of 10 holds.
type TopicTagStore interface {
	// AddTopicTag links raw's slug to the topic, creating the workspace tag
	// on first use. ErrBadTopicTask / ErrBadTopicTag before any write;
	// ErrTooManyTopicTags: the topic has 10; ErrNotFound: no such workspace.
	AddTopicTag(ctx context.Context, tenant, taskID, raw, by string, at time.Time) (TopicTagChange, error)
	// RemoveTopicTag unlinks raw's slug from the topic and prunes the
	// workspace tag when no topic uses it any more (spec 196 2.2).
	RemoveTopicTag(ctx context.Context, tenant, taskID, raw, by string, at time.Time) (TopicTagChange, error)
	// TopicTagLinks answers the asked topics' tags, keyed by the stored
	// (lower case) task id, each sorted by slug; an untagged topic is absent.
	TopicTagLinks(ctx context.Context, tenant string, taskIDs []string) (map[string][]TopicTagLink, error)
}

var (
	_ TopicTagStore = (*Memory)(nil)
	_ TopicTagStore = (*Postgres)(nil)
)

// checkTopicTag validates a write before it reaches a store: the stored
// task id and the slug.
func checkTopicTag(tenant, taskID, raw string) (string, string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", "", err
	}
	if !isUUID(taskID) {
		return "", "", ErrBadTopicTask
	}
	slug, err := NormalizeTopicTag(raw)
	if err != nil {
		return "", "", err
	}
	return strings.ToLower(taskID), slug, nil
}

// topicTagKeys are the distinct stored forms of the uuid ids.
func topicTagKeys(taskIDs []string) []string {
	_, keys := defaultTopicPriorities(taskIDs)
	return keys
}

// ---- Memory driver -----------------------------------------------------------

// memTopicTags is one Memory store's three tables, under s.mu.
type memTopicTags struct {
	tags   map[[2]string]string                  // (tenant, slug) -> tag_id
	links  map[[2]string]map[string]TopicTagLink // (tenant, task) -> slug -> link
	stamps map[[2]string]time.Time               // (tenant, task) -> updated_at
}

var memTopicTagRows sync.Map // *Memory -> *memTopicTags

// topicTagsLocked is s's rows, made on first use. The caller holds s.mu.
func (s *Memory) topicTagsLocked() *memTopicTags {
	v, _ := memTopicTagRows.LoadOrStore(s, &memTopicTags{tags: map[[2]string]string{},
		links: map[[2]string]map[string]TopicTagLink{}, stamps: map[[2]string]time.Time{}})
	return v.(*memTopicTags)
}

// slugs is the topic's sorted slugs.
func (tt *memTopicTags) slugs(tenant, task string) []string {
	out := []string{}
	for slug := range tt.links[[2]string{tenant, task}] {
		out = append(out, slug)
	}
	sort.Strings(out)
	return out
}

// prune drops each slug's workspace tag that no topic links any more.
func (tt *memTopicTags) prune(tenant string, slugs []string) {
	for _, slug := range slugs {
		used := false
		for k, l := range tt.links {
			if _, ok := l[slug]; ok && k[0] == tenant {
				used = true
				break
			}
		}
		if !used {
			delete(tt.tags, [2]string{tenant, slug})
		}
	}
}

// AddTopicTag implements TopicTagStore.
func (s *Memory) AddTopicTag(_ context.Context, tenant, taskID, raw, by string, at time.Time) (TopicTagChange, error) {
	task, slug, err := checkTopicTag(tenant, taskID, raw)
	if err != nil {
		return TopicTagChange{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return TopicTagChange{}, ErrNotFound
	}
	tt, k := s.topicTagsLocked(), [2]string{tenant, task}
	ch := TopicTagChange{TaskID: task, Slug: slug}
	if _, ok := tt.links[k][slug]; !ok {
		if len(tt.links[k]) >= TopicTagsMax {
			return TopicTagChange{}, ErrTooManyTopicTags
		}
		if _, ok := tt.tags[[2]string{tenant, slug}]; !ok {
			tt.tags[[2]string{tenant, slug}] = uuid.New()
		}
		if tt.links[k] == nil {
			tt.links[k] = map[string]TopicTagLink{}
		}
		tt.links[k][slug] = TopicTagLink{Slug: slug, AddedBy: by, AddedAt: at.UTC()}
		tt.stamps[k], ch.Changed = at.UTC(), true
	}
	ch.Tags = tt.slugs(tenant, task)
	return ch, nil
}

// RemoveTopicTag implements TopicTagStore.
func (s *Memory) RemoveTopicTag(_ context.Context, tenant, taskID, raw, _ string, at time.Time) (TopicTagChange, error) {
	task, slug, err := checkTopicTag(tenant, taskID, raw)
	if err != nil {
		return TopicTagChange{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tt, k := s.topicTagsLocked(), [2]string{tenant, task}
	ch := TopicTagChange{TaskID: task, Slug: slug}
	if _, ok := tt.links[k][slug]; ok {
		delete(tt.links[k], slug)
		tt.prune(tenant, []string{slug})
		tt.stamps[k], ch.Changed = at.UTC(), true
	}
	ch.Tags = tt.slugs(tenant, task)
	return ch, nil
}

// TopicTagLinks implements TopicTagStore.
func (s *Memory) TopicTagLinks(_ context.Context, tenant string, taskIDs []string) (map[string][]TopicTagLink, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tt, out := s.topicTagsLocked(), map[string][]TopicTagLink{}
	for _, task := range topicTagKeys(taskIDs) {
		for _, slug := range tt.slugs(tenant, task) {
			out[task] = append(out[task], tt.links[[2]string{tenant, task}][slug])
		}
	}
	return out, nil
}

// dropTopicTagsLocked is DeleteTopic's part (spec 196 2.2): the topics'
// links and stamps go, then the tags no topic uses. The caller holds s.mu.
func (s *Memory) dropTopicTagsLocked(tenant string, tasks []string) {
	tt := s.topicTagsLocked()
	var slugs []string
	for _, task := range tasks {
		k := [2]string{tenant, strings.ToLower(task)}
		for slug := range tt.links[k] {
			slugs = append(slugs, slug)
		}
		delete(tt.links, k)
		delete(tt.stamps, k)
	}
	tt.prune(tenant, slugs)
}

// mergeTopicTagsLocked is MergeTopic's part (spec 196 2.2): the target
// keeps all its tags and takes the source's others, earliest added first
// (slug breaks a tie), while it has fewer than 10; the source's go. The
// caller holds s.mu.
func (s *Memory) mergeTopicTagsLocked(tenant, src, target string, at time.Time) {
	tt := s.topicTagsLocked()
	sk, tk := [2]string{tenant, strings.ToLower(src)}, [2]string{tenant, strings.ToLower(target)}
	if len(tt.links[sk]) == 0 {
		delete(tt.stamps, sk)
		return
	}
	var from []TopicTagLink
	for _, l := range tt.links[sk] {
		from = append(from, l)
	}
	sortTopicTagLinks(from)
	if tt.links[tk] == nil {
		tt.links[tk] = map[string]TopicTagLink{}
	}
	var slugs []string
	for _, l := range from {
		slugs = append(slugs, l.Slug)
		if _, ok := tt.links[tk][l.Slug]; !ok && len(tt.links[tk]) < TopicTagsMax {
			tt.links[tk][l.Slug] = l
		}
	}
	delete(tt.links, sk)
	delete(tt.stamps, sk)
	tt.stamps[tk] = at.UTC()
	tt.prune(tenant, slugs)
}

// sortTopicTagLinks orders links by added_at, then slug: the merge's fill
// order (spec 196 2.2).
func sortTopicTagLinks(ls []TopicTagLink) {
	sort.Slice(ls, func(i, j int) bool {
		if !ls[i].AddedAt.Equal(ls[j].AddedAt) {
			return ls[i].AddedAt.Before(ls[j].AddedAt)
		}
		return ls[i].Slug < ls[j].Slug
	})
}
