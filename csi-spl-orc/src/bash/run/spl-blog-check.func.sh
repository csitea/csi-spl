#!/bin/bash
#------------------------------------------------------------------------------
# @description The blog post check (spec 111 section 4.4): the gate a post must
# @description pass BEFORE it is pushed, because the repository is public and a
# @description pushed post stays in its history. Run by do_spl_blog_post,
# @description do_spl_blog_translate, the pre-push gate (part "blog", when
# @description csi-spl-doc/blog/** changes) and CI. Every row of 4.4:
# @description   frontmatter  a missing field, an unknown type, id != file name,
# @description                lang != dir, image without image_alt, a bad image
# @description                key, a hand-set published, no agy_review
# @description   size         body over env.blog.max_words, summary over 160 chars
# @description   hygiene      the 10 ci distribution-hygiene Sweep (read out of
# @description                the workflow, never a copy) plus the release-note
# @description                ban list, a Secret Manager slot read as the per-env
# @description                SA: unreadable or empty FAILS CLOSED, and a hit
# @description                names the file and line, never the pattern
# @description   public-safe  an email, a phone number, an internal host, a box
# @description                name, a /home/ path, a person in image_prompt
# @description   hex tokens   any 7+ hex token (with a digit) or uuid that is not
# @description                a commit on BLOG_CHECK_REF (default origin/master)
# @description   facts        a v<X.Y.Z> tag that is not on BLOG_CHECK_REF
# @description   author       not an agent id (spec 061 grammar) or the site name
# @description   digest       a second digest for a date; published outside
# @description                23:00-24:00 in env.blog.tz
# @description   commit shape (BLOG_CHECK_RANGE) a commit touching a post and
# @description                any other path, or more than one post id
# @description "published" is hand-set when a NEW en file's stamp is more than
# @description BLOG_PUBLISHED_SKEW s (3600) from now, an existing file's stamp
# @description differs from BLOG_CHECK_REF's, or a locale copy's differs from
# @description its en file's. Letters-only hex runs ("defaced") are English
# @description words, not tokens. Exit 0 = every file passes, 1 = a refusal
# @description (one "REFUSE <file>:<line> <row>: <why>" line each) or an
# @description unreadable ban list. No post file and no range: nothing to
# @description check, exit 0 without reading the secret.
# @param BLOG_FILES (optional) - newline/space list of post files (repo-relative or absolute), or "none"; default every csi-spl-doc/blog/posts/<lang>/*.md
# @param BLOG_TREE (optional) - the checkout, default $APP_PATH
# @param BLOG_CHECK_REF (optional) - default origin/master
# @param BLOG_CHECK_RANGE (optional) - a rev range for the commit-shape row, e.g. origin/master..HEAD
# @param BLOG_CHECK_ENV (optional) - dev or prd, whose ban-list slot and cnf are read; default $ENV, else prd
# @param BLOG_CHECK_NOW (optional) - epoch seconds standing in for now (tests)
# @param BLOG_PUBLISHED_SKEW (optional) - seconds, default 3600
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise)
# @example ./run -a do_spl_blog_check
# @example BLOG_FILES=csi-spl-doc/blog/posts/en/2026-10-09-hello.md ./run -a do_spl_blog_check
# @example BLOG_CHECK_RANGE=origin/master..HEAD ./run -a do_spl_blog_check
#------------------------------------------------------------------------------
do_spl_blog_check() {
  do_require_bin yq jq perl git || return 1
  local tree="${BLOG_TREE:-$APP_PATH}" ref="${BLOG_CHECK_REF:-origin/master}"
  local posts_rel="csi-spl-doc/blog/posts" f rel n=0
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 || { do_log "FATAL blog check: $tree is not a git checkout"; return 1; }
  local -a files=()
  if [[ "${BLOG_FILES:-}" == none ]]; then
    :
  elif [[ -n "${BLOG_FILES:-}" ]]; then
    for f in ${BLOG_FILES}; do
      rel="${f#"$tree"/}"
      [[ -f "$tree/$rel" ]] || { do_log "FATAL blog check: no post file $rel"; return 1; }
      files+=("$rel")
    done
  else
    while IFS= read -r f; do files+=("${f#"$tree"/}"); done < <(find "$tree/$posts_rel" -mindepth 2 -maxdepth 2 -name '*.md' 2>/dev/null | sort)
  fi
  local -a refusals=()
  [[ -n "${BLOG_CHECK_RANGE:-}" ]] && { spl_blog_shape "$tree" "$BLOG_CHECK_RANGE" || return 1; }
  if (( ${#files[@]} == 0 )); then
    spl_blog_verdict 0
    return
  fi
  local h; h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/bans 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  spl_blog_cnf "$tree" || return 1
  spl_blog_bans_read "$h/bans" || return 1
  git -C "$tree" rev-parse -q --verify "$ref^{commit}" >/dev/null ||
    { do_log "FATAL blog check: $ref is unknown in $tree (git fetch first): hex tokens and tags cannot be resolved"; return 1; }
  spl_blog_hygiene "$tree" "$h" "${files[@]}" || return 1
  for rel in "${files[@]}"; do
    spl_blog_file "$tree" "$rel" "$ref"
    spl_blog_bans_scan "$h/bans" "$tree" "$rel"
    spl_blog_public_safe "$tree" "$rel"
    spl_blog_tokens "$tree" "$rel" "$ref"
    n=$((n + 1))
  done
  spl_blog_verdict "$n"
}

# spl_blog_refuse <file> <line> <row> <why> - one refusal line, collected.
spl_blog_refuse() {
  refusals+=("REFUSE $1:$2 $3: $4")
  echo "REFUSE $1:$2 $3: $4"
}

# spl_blog_verdict <n-files> - the summary line and the exit code.
spl_blog_verdict() {
  if (( ${#refusals[@]} )); then
    do_log "FAIL blog check: ${#refusals[@]} refusal(s) over $1 post file(s): fix every file:line above, do not push"
    return 1
  fi
  do_log "OK blog check: $1 post file(s) pass every row of spec 111 4.4${BLOG_CHECK_RANGE:+ (commit shape over $BLOG_CHECK_RANGE)}"
}

# spl_blog_cnf <tree> - the env cnf: SPL_CNF, the blog values, the locales, the
# site name and the box names. env.blog is T001's; until it lands the spec
# values hold.
spl_blog_cnf() {
  local e="${BLOG_CHECK_ENV:-${ENV:-prd}}"
  ENV="$e" do_spl_cloud_cnf || return 1
  local -a v=()
  mapfile -t v < <(yq -r '[.env.blog.tz // "Europe/Helsinki", .env.blog.max_words // 450,
      (.env.i18n.locales // [] | join(" ")), .env.dns.BASE_DOMAIN // ""] | .[]' "$SPL_CNF")
  (( ${#v[@]} == 4 )) || { do_log "FATAL blog check: cannot read env.blog / env.i18n out of $SPL_CNF"; return 1; }
  BLOG_TZ="${v[0]}" BLOG_MAX_WORDS="${v[1]}" BLOG_LOCALES="${v[2]}" BLOG_SITE="${v[3]}"
  [[ -n "$BLOG_LOCALES" && "$BLOG_MAX_WORDS" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL blog check: env.i18n.locales is empty or env.blog.max_words is not a number"; return 1; }
  BLOG_BOXES="$(cat "$1"/csi-spl-cnf/csi-spl/*.env.yaml 2>/dev/null |
    sed -nE 's/^[[:space:]]*vm_hostname:[[:space:]]*"?([A-Za-z0-9-]+).*/\1/p' | sort -u | tr '\n' ' ')"
  BLOG_BOXES+=" ${SPOOL_BOX_TAG:-} ${BOX_TAGS:-}"
}

# spl_blog_bans_read <dest> - the release-note ban list into a 0600 file, as
# the pinned per-env SA. Unreadable or empty: FAIL CLOSED. Never printed.
spl_blog_bans_read() {
  local slot
  slot="$(yq -r '.env.hub.release_note_bans.secret_env.SPOOL_HUB_RELEASE_NOTE_BANS // ""' "$SPL_CNF")"
  [[ -n "$slot" ]] || { do_log "FATAL blog check: cnf names no release-note ban slot: fail closed"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || { do_log "FATAL blog check: no identity to read $slot: fail closed"; return 1; }
  (umask 077 && gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" \
    --account="$GCP_ACCOUNT" >"$1" 2>/dev/null) ||
    { do_log "FATAL blog check: the ban list $slot is unreadable in $SPL_PROJECT: fail closed"; return 1; }
  grep -q '[^[:space:]]' "$1" || { do_log "FATAL blog check: the ban list $slot is empty: fail closed"; return 1; }
}

# spl_blog_bans_scan <bans> <tree> <rel> - one refusal per hit line. perl reads
# the patterns from the file (never argv) and prints line numbers only.
spl_blog_bans_scan() {
  local ln
  while IFS= read -r ln; do
    spl_blog_refuse "$3" "$ln" hygiene "a release-note ban list pattern matches (the pattern is a secret, not shown)"
  done < <(perl -e '
    open(my $b, "<", $ARGV[0]) or exit 2; my @p;
    while (<$b>) { chomp; next unless /\S/; my $r = eval { qr/$_/ }; push @p, $r if $r; }
    open(my $f, "<", $ARGV[1]) or exit 2; my %hit;
    while (my $l = <$f>) { for my $r (@p) { if ($l =~ $r) { $hit{$.} = 1; last; } } }
    print "$_\n" for sort { $a <=> $b } keys %hit;' "$1" "$2/$3")
}

# spl_blog_hygiene <tree> <scratch> <rel>... - the 10 ci distribution-hygiene
# Sweep over a copy of the post files only. Its own hit lines name file:line.
spl_blog_hygiene() {
  local tree="$1" h="$2" rel line label=""; shift 2
  local wf="$tree/.github/workflows/10_ci-quality.yml"
  yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$wf" >"$h/sweep.sh" 2>/dev/null
  grep -q 'allow_line=' "$h/sweep.sh" 2>/dev/null ||
    { do_log "FATAL blog check: no distribution-hygiene Sweep step in $wf: fail closed"; return 1; }
  mkdir -p "$h/tree"
  for rel in "$@"; do mkdir -p "$h/tree/$(dirname "$rel")" && cp "$tree/$rel" "$h/tree/$rel"; done
  while IFS= read -r line; do
    if [[ "$line" =~ ^::error::hygiene:\ (.*)\ --\  ]]; then label="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^\ +\./([^:]+):([0-9]+)$ ]]; then
      spl_blog_refuse "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" hygiene "the distribution-hygiene sweep refuses it (${label:-sweep})"
    elif [[ "$line" == ::error::* ]]; then
      spl_blog_refuse "-" 0 hygiene "${line#::error::}"
    fi
  done < <(cd "$h/tree" && bash "$h/sweep.sh" 2>&1)
  return 0
}

# spl_blog_fm <tree> <rel> - the frontmatter as one JSON object on stdout.
spl_blog_fm() {
  awk 'NR == 1 { if ($0 != "---") exit 3; next } $0 == "---" { exit } { print }' "$1/$2" | yq -o=json '. // {}' 2>/dev/null
}

# spl_blog_line <tree> <rel> <key> - the line of a frontmatter key (1 if none).
spl_blog_line() {
  local l; l="$(grep -n -m1 -E "^$3:" "$1/$2" | cut -d: -f1)"
  echo "${l:-1}"
}

# spl_blog_file <tree> <rel> <ref> - the frontmatter, size, author and digest
# rows of one post file.
spl_blog_file() {
  local tree="$1" rel="$2" ref="$3" fm k v
  local lang id; lang="$(basename "$(dirname "$rel")")"; id="$(basename "$rel" .md)"
  fm="$(spl_blog_fm "$tree" "$rel")"
  [[ "$(head -1 "$tree/$rel")" == --- && "$(jq -r type <<<"$fm" 2>/dev/null)" == object ]] ||
    { spl_blog_refuse "$rel" 1 frontmatter "no readable --- frontmatter block"; return 0; }
  _bf() { jq -r --arg k "$1" '.[$k] // "" | if type == "array" then join(",") else tostring end' <<<"$fm"; }
  for k in id lang type title summary date published author agy_review; do
    [[ -n "$(_bf "$k")" ]] || spl_blog_refuse "$rel" 1 frontmatter "missing field '$k'"
  done
  v="$(_bf type)"
  case "$v" in digest | news | event | "") ;; *) spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" type)" frontmatter "unknown type '$v' (digest, news or event)" ;; esac
  [[ "$v" == event && -z "$(_bf event_start)" ]] && spl_blog_refuse "$rel" 1 frontmatter "an event needs event_start"
  for k in event_start event_end; do
    v="$(_bf "$k")"; [[ -z "$v" || "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$ ]] ||
      spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" "$k")" frontmatter "$k is not ISO 8601 UTC (Z)"
  done
  v="$(_bf id)"
  [[ -z "$v" || "$v" == "$id" ]] || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" id)" frontmatter "id '$v' does not match the file name '$id'"
  [[ "$id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || spl_blog_refuse "$rel" 1 frontmatter "the file name is not <yyyy-mm-dd>-<slug>.md"
  [[ -z "$(_bf date)" || "$id" == "$(_bf date)"-* ]] || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" date)" frontmatter "date does not start the id"
  [[ "$(_bf type)" != digest || "$id" == *-digest ]] || spl_blog_refuse "$rel" 1 frontmatter "a digest id is <date>-digest"
  v="$(_bf lang)"
  [[ -z "$v" || "$v" == "$lang" ]] || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" lang)" frontmatter "lang '$v' does not match the dir '$lang'"
  [[ " $BLOG_LOCALES " == *" $lang "* ]] || spl_blog_refuse "$rel" 1 frontmatter "'$lang' is not a supported locale (env.i18n.locales)"
  v="$(_bf image)"
  if [[ -n "$v" ]]; then
    [[ -n "$(_bf image_alt)" ]] || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" image)" frontmatter "image without image_alt"
    [[ "$v" =~ ^${id}(-og)?\.webp$ ]] || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" image)" frontmatter "image must be $id.webp or $id-og.webp"
  fi
  spl_blog_author "$tree" "$rel" "$(_bf author)" "$(_bf agy_review)"
  spl_blog_published "$tree" "$rel" "$ref" "$(_bf published)"
  spl_blog_size "$tree" "$rel" "$(_bf summary)"
  spl_blog_prompt "$tree" "$rel" "$(_bf image_prompt)"
  [[ "$(_bf type)" == digest ]] && spl_blog_digest "$tree" "$rel" "$(_bf date)" "$(_bf published)"
  unset -f _bf
  return 0
}

# spl_blog_author <tree> <rel> <author> <agy_review> - spec 061 ids, no box.
spl_blog_author() {
  [[ -z "$3" || "$3" =~ ^[acgmq]-[0-9]{3}$ || ( -n "$BLOG_SITE" && "$3" == "$BLOG_SITE" ) ]] ||
    spl_blog_refuse "$2" "$(spl_blog_line "$1" "$2" author)" author "'$3' is not an agent id (^[acgmq]-[0-9]{3}\$, no box) or the site name"
  [[ -z "$4" || "$4" =~ ^a-[0-9]{3}$ ]] ||
    spl_blog_refuse "$2" "$(spl_blog_line "$1" "$2" agy_review)" frontmatter "agy_review '$4' is not an agy seat id (a-NNN)"
}

# spl_blog_stamp <file> - the published value of a post's frontmatter.
spl_blog_stamp() {
  awk 'NR > 1 && $0 == "---" { exit } /^published:/ { sub(/^published:[[:space:]]*/, ""); gsub(/["\047]/, ""); print }' "$1" 2>/dev/null
}

# spl_blog_published <tree> <rel> <ref> <published> - UTC, and never hand-set.
spl_blog_published() {
  local tree="$1" rel="$2" ref="$3" p="$4" l old en now t skew="${BLOG_PUBLISHED_SKEW:-3600}"
  [[ -n "$p" ]] || return 0
  l="$(spl_blog_line "$tree" "$rel" published)"
  if [[ ! "$p" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || ! t="$(date -u -d "$p" +%s 2>/dev/null)"; then
    spl_blog_refuse "$rel" "$l" frontmatter "published '$p' is not ISO 8601 UTC (yyyy-mm-ddThh:mm:ssZ)"; return 0
  fi
  old="$(git -C "$tree" show "$ref:$rel" 2>/dev/null | spl_blog_stamp /dev/stdin)"
  if [[ "$rel" != */en/* ]]; then
    en="$(spl_blog_stamp "$tree/${rel%/*/*}/en/${rel##*/}")"
    [[ "$p" == "$en" ]] || spl_blog_refuse "$rel" "$l" frontmatter "a hand-set published: a locale copy keeps its en file's stamp (${en:-no en file})"
  elif [[ -n "$old" ]]; then
    [[ "$p" == "$old" ]] || spl_blog_refuse "$rel" "$l" frontmatter "a hand-set published: an edit keeps the stamp on $ref ($old)"
  else
    now="${BLOG_CHECK_NOW:-$(date -u +%s)}"
    (( t - now <= skew && now - t <= skew )) ||
      spl_blog_refuse "$rel" "$l" frontmatter "a hand-set published: a new post is stamped by do_spl_blog_post, within $skew s of now"
  fi
}

# spl_blog_size <tree> <rel> <summary> - body words and summary chars.
spl_blog_size() {
  local words chars
  words="$(awk 'f >= 2 { print } $0 == "---" { f++ }' "$1/$2" | wc -w)"
  (( words <= BLOG_MAX_WORDS )) || spl_blog_refuse "$2" 1 size "the body is $words words (max $BLOG_MAX_WORDS)"
  chars="$(printf '%s' "$3" | LC_ALL=C.UTF-8 wc -m)"
  (( chars <= 160 )) || spl_blog_refuse "$2" "$(spl_blog_line "$1" "$2" summary)" size "the summary is $chars chars (max 160)"
}

# spl_blog_prompt <tree> <rel> <image_prompt> - no real or named person: a
# people word, or two capitalised words in a row (a name).
spl_blog_prompt() {
  [[ -n "$3" ]] || return 0
  local re='(?i)\b(person|persons|people|man|men|woman|women|boy|girl|child|children|kids?|humans?|faces?|portrait|selfie|celebrity|crowd|employee|ceo|founder|politician|president|minister|king|queen|photo of)\b'
  if grep -qP "$re" <<<"$3" || grep -qP '\b[A-Z][a-z]+ [A-Z][a-z]+\b' <<<"$3"; then
    spl_blog_refuse "$2" "$(spl_blog_line "$1" "$2" image_prompt)" public-safe "image_prompt asks for a real or named person"
  fi
}

# spl_blog_digest <tree> <rel> <date> <published> - one digest per date and
# lang, published 23:00-24:00 in env.blog.tz.
spl_blog_digest() {
  local tree="$1" rel="$2" d="$3" p="$4" f n=0 hr
  for f in "$tree/${rel%/*}"/*.md; do
    awk -v d="$d" 'NR > 1 && $0 == "---" { exit }
      /^type:[[:space:]]*"?digest"?[[:space:]]*$/ { t = 1 }
      $0 ~ "^date:[[:space:]]*\"?" d "\"?[[:space:]]*$" { m = 1 }
      END { exit !(t && m) }' "$f" && n=$((n + 1))
  done
  (( n <= 1 )) || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" date)" digest "a second digest for $d ($n in ${rel%/*})"
  [[ -n "$p" ]] || return 0
  hr="$(TZ="$BLOG_TZ" date -d "$p" +%H 2>/dev/null)"
  [[ "$hr" == 23 ]] || spl_blog_refuse "$rel" "$(spl_blog_line "$tree" "$rel" published)" digest "a digest is published 23:00-24:00 $BLOG_TZ (this one at ${hr:-?}h)"
}

# spl_blog_public_safe <tree> <rel> - "matrix" only: no email, phone, internal
# host, box name or /home/ path. (Personal names: the hygiene Sweep's list.)
spl_blog_public_safe() {
  local tree="$1" rel="$2" b re ln
  local -a rows=(
    'an email address|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
    'a phone number|(\+|\btel:)\d[\d ().-]{6,}\d|\b0\d{1,3}[ -]\d{3,4}[ -]\d{3,4}\b'
    'an internal host|\b[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(internal|local|lan|corp|intranet)\b|\blocalhost\b|\b(10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|\b192\.168\.\d{1,3}\.\d{1,3}\b|\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b'
    'a box name|\b[acgmq]-\d{3}@[A-Za-z0-9-]+'
    'a /home/ path|/home/'
  )
  for b in $BLOG_BOXES; do [[ "$b" =~ ^[A-Za-z0-9-]+$ ]] && rows+=("a box name|(?i)\\b${b}\\b"); done
  for re in "${rows[@]}"; do
    while IFS= read -r ln; do
      spl_blog_refuse "$rel" "$ln" public-safe "${re%%|*}"
    done < <(grep -nP -- "${re#*|}" "$tree/$rel" | cut -d: -f1 | sort -un)
  done
}

# spl_blog_tokens <tree> <rel> <ref> - hex tokens and v<X.Y.Z> tags must be on
# the ref. A message id and a short sha look alike: none is told apart.
spl_blog_tokens() {
  local tree="$1" rel="$2" ref="$3" ln tok c
  while IFS=' ' read -r ln tok; do
    if [[ "$tok" == *-* ]]; then
      spl_blog_refuse "$rel" "$ln" "hex tokens" "a uuid is never a commit on $ref"
      continue
    fi
    tok="${tok,,}"
    c="$(git -C "$tree" rev-parse -q --verify "$tok^{commit}" 2>/dev/null)" &&
      git -C "$tree" merge-base --is-ancestor "$c" "$ref" 2>/dev/null ||
      spl_blog_refuse "$rel" "$ln" "hex tokens" "'$tok' is not a commit on $ref"
  done < <(perl -ne '
    my $u = qr/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/;
    while (/(?<![0-9A-Za-z-])($u)(?![0-9A-Za-z-])/g) { print "$. $1\n" }
    s/$u//g;
    while (/(?<![0-9A-Za-z])([0-9a-fA-F]{7,})(?![0-9A-Za-z])/g) { my $t = $1; print "$. $t\n" if $t =~ /[0-9]/ }' "$tree/$rel")
  while IFS=' ' read -r ln tok; do
    c="$(git -C "$tree" rev-parse -q --verify "refs/tags/$tok^{commit}" 2>/dev/null)" &&
      git -C "$tree" merge-base --is-ancestor "$c" "$ref" 2>/dev/null ||
      spl_blog_refuse "$rel" "$ln" facts "tag '$tok' is not on $ref (git fetch --tags?)"
  done < <(perl -ne 'while (/(?<![0-9A-Za-z.])(v\d+\.\d+\.\d+)(?![0-9A-Za-z])/g) { print "$. $1\n" }' "$tree/$rel")
}

# spl_blog_shape <tree> <range> - every commit that touches a post touches that
# post's files only: posts/*/<id>.md, one id.
spl_blog_shape() {
  local tree="$1" c paths others ids revs
  revs="$(git -C "$tree" rev-list "$2" 2>/dev/null)" ||
    { do_log "FATAL blog check: cannot list the commits of $2"; return 1; }
  for c in $revs; do
    paths="$(git -C "$tree" diff-tree --no-commit-id --name-only -r "$c")"
    grep -q '^csi-spl-doc/blog/posts/' <<<"$paths" || continue
    others="$(grep -vcE '^csi-spl-doc/blog/posts/[^/]+/[^/]+\.md$' <<<"$paths")"
    ids="$(grep -E '^csi-spl-doc/blog/posts/' <<<"$paths" | sed 's|.*/||' | sort -u | grep -c .)"
    (( others == 0 )) || spl_blog_refuse "commit:${c:0:12}" 0 "commit shape" "a post commit also touches $others other path(s)"
    (( ids <= 1 )) || spl_blog_refuse "commit:${c:0:12}" 0 "commit shape" "a post commit touches $ids post ids"
  done
  return 0
}
