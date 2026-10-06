package repodocs

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strings"
)

// Author sources (spec §4.1), stored on the edit row as author_source.
const (
	SourceMapping = "mapping" // rule 1: a repo_doc_authors row
	SourceHistory = "history" // rule 2: the sign-in email is in the repo history
	SourceSignin  = "signin"  // rule 3: display name + verified sign-in email
)

// Refusal reasons the PUT route answers with (spec §10 API table).
const (
	ReasonEmailUnverified      = "email_unverified"
	ReasonRequesterRequired    = "requester_required"
	ReasonRequesterInvalid     = "requester_invalid"
	ReasonAuthorNoticeRequired = "author_notice_required"
)

// Why a requester is invalid: spec §4.3 rules a-e, for the audit and the
// agent's error text. The 403 reason stays requester_invalid for all five.
const (
	RequesterNotMember    = "not_member"       // a
	RequesterNoDocsWrite  = "no_docs_write"    // b
	RequesterUnverified   = "email_unverified" // c
	RequesterAgentsOff    = "agents_off"       // d
	RequesterNotSeatHuman = "not_seat_human"   // e
)

// DocsWrite is rbac.DocsWrite; TestDocsWriteMatchesRBAC pins the two.
const DocsWrite = "docs.write"

// Refusal is a save the hub must answer with Status and Reason, writing
// nothing. Detail names the failed rule where the reason covers several.
type Refusal struct {
	Status int
	Reason string
	Detail string
}

func (r *Refusal) Error() string {
	if r.Detail == "" {
		return fmt.Sprintf("repodocs: %d %s", r.Status, r.Reason)
	}
	return fmt.Sprintf("repodocs: %d %s (%s)", r.Status, r.Reason, r.Detail)
}

func refuse(reason, detail string) *Refusal {
	return &Refusal{Status: http.StatusForbidden, Reason: reason, Detail: detail}
}

// Person is a human as the hub knows them in one workspace.
type Person struct {
	HumanID     string
	Member      bool // an active (not disabled) member of the workspace
	DisplayName string
	Email       string // the sign-in email
	// EmailVerified: Email is the verified address of one of their sign-in
	// identities.
	EmailVerified bool
}

// Mapping is the member's repo_doc_authors row (spec §4.1 rule 1, §4.3 d).
// A row may exist only to switch agent edits off: an empty GitName or
// GitEmail is no identity and falls through to rules 2 and 3.
type Mapping struct {
	GitName     string
	GitEmail    string
	Verified    bool // verified_at set: the address was proven to be theirs
	AllowAgents bool
}

// Directory is what author resolution reads; the hub implements it over the
// store (T08). ok=false is "no such row", never an error.
type Directory interface {
	Person(ctx context.Context, tenant, humanID string) (Person, error)
	Mapping(ctx context.Context, tenant, humanID string) (m Mapping, ok bool, err error)
	// KnownAuthor is the history identity of email, matched without case.
	KnownAuthor(ctx context.Context, email string) (name, gitEmail string, ok bool, err error)
	HasNotice(ctx context.Context, tenant, humanID, gitName, gitEmail string) (bool, error)
	// Can reports whether the member's role in tenant holds perm.
	Can(ctx context.Context, tenant, humanID, perm string) (bool, error)
	// SeatHuman is the for_human of the join token that seated this agent
	// seat (agent_join_tokens, rdb 0119); "" when the seat was made without
	// one.
	SeatHuman(ctx context.Context, tenant, seat string) (string, error)
}

// Author is the git identity an edit is committed under, resolved at save
// and stored on the row (spec §4.1).
type Author struct {
	Name   string
	Email  string
	Source string
}

var emailRe = regexp.MustCompile(`^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$`)

// cleanName makes a git author name: one line, no angle brackets (which
// would end the name in the commit header), spaces collapsed.
func cleanName(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || r == '<' || r == '>' {
			return ' '
		}
		return r
	}, s)
	return strings.Join(strings.Fields(s), " ")
}

func identity(name, email, source string) (Author, bool) {
	email = strings.TrimSpace(email)
	if !emailRe.MatchString(email) {
		return Author{}, false
	}
	if name = cleanName(name); name == "" {
		name = email[:strings.IndexByte(email, '@')]
	}
	return Author{Name: name, Email: email, Source: source}, true
}

// ResolveAuthor is the git identity of humanID's saves (spec §4.1): a
// mapping row, else the history identity of their verified sign-in email,
// else their display name and that email. An unverified or missing address
// is never published: 403 email_unverified. A mapping row whose address was
// not verified is refused too, rather than falling back to an identity the
// member chose not to publish.
func ResolveAuthor(ctx context.Context, d Directory, tenant, humanID string) (Author, error) {
	m, ok, err := d.Mapping(ctx, tenant, humanID)
	if err != nil {
		return Author{}, err
	}
	if ok && m.GitName != "" && m.GitEmail != "" {
		a, valid := identity(m.GitName, m.GitEmail, SourceMapping)
		if !m.Verified || !valid {
			return Author{}, refuse(ReasonEmailUnverified, SourceMapping)
		}
		return a, nil
	}
	p, err := d.Person(ctx, tenant, humanID)
	if err != nil {
		return Author{}, err
	}
	email := strings.TrimSpace(p.Email)
	if !p.EmailVerified || !emailRe.MatchString(email) {
		return Author{}, refuse(ReasonEmailUnverified, SourceSignin)
	}
	name, gitEmail, ok, err := d.KnownAuthor(ctx, email)
	if err != nil {
		return Author{}, err
	}
	if ok {
		if a, valid := identity(name, gitEmail, SourceHistory); valid {
			return a, nil
		}
	}
	a, _ := identity(p.DisplayName, email, SourceSignin)
	return a, nil
}

// NeedsNotice reports whether humanID has not yet consented to publishing
// exactly this identity (spec §4.2): the save then answers 428
// author_notice_required. A changed name or email asks again.
func NeedsNotice(ctx context.Context, d Directory, tenant, humanID string, a Author) (bool, error) {
	ok, err := d.HasNotice(ctx, tenant, humanID, a.Name, a.Email)
	return !ok, err
}

// NoticeRequired is the 428 refusal; the route answers it with the author's
// {git_name, git_email, author_source}.
func NoticeRequired() *Refusal {
	return &Refusal{Status: http.StatusPreconditionRequired, Reason: ReasonAuthorNoticeRequired}
}

// CheckRequester validates the X-Spool-Requester an agent names (spec §4.3)
// and returns the requester's human id: the edit's author and owner. seat
// is the agent's seat (the box of its upload token).
func CheckRequester(ctx context.Context, d Directory, tenant, seat, requester string) (string, error) {
	requester = strings.TrimSpace(requester)
	if requester == "" {
		return "", refuse(ReasonRequesterRequired, "")
	}
	p, err := d.Person(ctx, tenant, requester)
	if err != nil {
		return "", err
	}
	if !p.Member {
		return "", refuse(ReasonRequesterInvalid, RequesterNotMember)
	}
	can, err := d.Can(ctx, tenant, requester, DocsWrite)
	if err != nil {
		return "", err
	}
	if !can {
		return "", refuse(ReasonRequesterInvalid, RequesterNoDocsWrite)
	}
	if !p.EmailVerified || !emailRe.MatchString(strings.TrimSpace(p.Email)) {
		return "", refuse(ReasonRequesterInvalid, RequesterUnverified)
	}
	m, ok, err := d.Mapping(ctx, tenant, requester)
	if err != nil {
		return "", err
	}
	if ok && !m.AllowAgents {
		return "", refuse(ReasonRequesterInvalid, RequesterAgentsOff)
	}
	forHuman, err := d.SeatHuman(ctx, tenant, seat)
	if err != nil {
		return "", err
	}
	if forHuman != "" && forHuman != requester {
		return "", refuse(ReasonRequesterInvalid, RequesterNotSeatHuman)
	}
	return requester, nil
}

// Edit is what a commit message names.
type Edit struct {
	Env       string // dev | prd
	Workspace string
	Path      string
	EditID    string
	AgentID   string // "" for a member's own edit
	Author    Author
}

// oneLine keeps a value on one line, so it can never open a line of its own
// (a trailer) in the message.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// CommitMessage is the subject and body of an edit's commit (spec §4.4):
// "docs: edit <path>" on prd, "docs(<env>): edit <path>" on every other env;
// the body names the workspace, env and edit id, plus the agent line of
// §4.3. Never a Co-Authored-By, Generated with or session trailer, and no
// [skip ci] (§3).
func CommitMessage(e Edit) (subject, body string) {
	env := oneLine(e.Env)
	prefix := "docs"
	if env != "prd" {
		prefix = "docs(" + env + ")"
	}
	subject = prefix + ": edit " + oneLine(e.Path)
	body = fmt.Sprintf("Edited in the Docs section of workspace %s (%s). Edit %s.",
		oneLine(e.Workspace), env, oneLine(e.EditID))
	if e.AgentID != "" {
		body += fmt.Sprintf("\n\nEdited by agent %s for %s.", oneLine(e.AgentID), oneLine(e.Author.Name))
	}
	return subject, body
}
