#!/bin/bash
#------------------------------------------------------------------------------
# @description The PRIVATE overlay (SPL-1874): the hidden workspace slugs that
# @description never enter this PUBLIC repo. Owner HUM-10 (poll 6c701ac9):
# @description "csitea and relishbg visible, and the rest not visible".
# @description The public cnf and the rendered tfvars carry a placeholder
# @description (ws-hidden-NN) where a hidden slug stands; the overlay maps each
# @description placeholder to its slug, and only what needs the real value
# @description resolves it: terraform (do_tf_init), the runtime cnf
# @description (do_spl_cloud_cnf) and the hygiene gate (the 10 ci Sweep).
# @description The overlay is ONE file, never in git:
# @description   ${SPL_PRIVATE_CNF:-$HOME/.gcp/.csi/csi-spl-private.yaml}
# @description beside the project SA keys, so the tf-runner sees it through
# @description its ~/.gcp mount. CI reads the same content from the secret
# @description SPL_PRIVATE_CNF_YAML. Format and backup:
# @description csi-spl-doc/doc/md/private-overlay.md.
# @description Pure bash + GNU sed/awk: it runs inside the tf-runner too.
# @example spl_private_resolve in.tfvars out.tfvars || return 1
#------------------------------------------------------------------------------

SPL_PRIVATE_TOKEN_RE='ws-hidden-[0-9][0-9]+'

# spl_private_cnf_path -> the overlay file path (it may not exist)
spl_private_cnf_path() {
  printf '%s\n' "${SPL_PRIVATE_CNF:-$HOME/.gcp/.csi/csi-spl-private.yaml}"
}

# spl_private_require -> 0 when the overlay is readable, else a FATAL naming it
spl_private_require() {
  local f
  f="$(spl_private_cnf_path)"
  [[ -r "$f" && -s "$f" ]] && return 0
  echo "FATAL the private overlay is missing: $f (SPL-1874; set SPL_PRIVATE_CNF or restore it, csi-spl-doc/doc/md/private-overlay.md)" >&2
  return 1
}

# spl_private_map -> "placeholder<TAB>slug" per line of the workspaces:
# section; non-zero on a malformed line or a duplicate (never a partial map).
spl_private_map() {
  spl_private_require || return 1
  awk '
    /^[^[:space:]#]/ { sec = $0; sub(/:.*/, "", sec); next }
    sec != "workspaces" || /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/[[:space:]]+#.*$/, "", line)
      if (line !~ /^  ws-hidden-[0-9][0-9]+: [a-z0-9][a-z0-9-]*[[:space:]]*$/) { bad = bad NR " "; next }
      split(line, kv, /: /); k = kv[1]; v = kv[2]
      gsub(/[[:space:]]/, "", k); gsub(/[[:space:]]/, "", v)
      if ((k in seenk) || (v in seenv)) { bad = bad NR " "; next }
      seenk[k] = 1; seenv[v] = 1; print k "\t" v
    }
    END { if (bad != "") { print "FATAL bad or duplicate workspaces line(s) " bad "in " FILENAME > "/dev/stderr"; exit 1 } }
  ' "$(spl_private_cnf_path)"
}

# spl_private_list <section> -> the items of a top-level list section
# (forms_only, deny), one per line, quotes stripped
spl_private_list() {
  spl_private_require || return 1
  awk -v want="$1" -v q="'" '
    /^[^[:space:]#]/ { sec = $0; sub(/:.*/, "", sec); next }
    sec == want && /^  - / {
      v = substr($0, 5); sub(/[[:space:]]+$/, "", v)
      if ((substr(v, 1, 1) == q && substr(v, length(v)) == q) || v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print v
    }
  ' "$(spl_private_cnf_path)"
}

# spl_private_list_strict <section> -> spl_private_list, or rc 2 when the
# overlay is not valid YAML (or no yq can prove it is), when a line of the
# section is not '  - item', when a column-0 line in the section is not
# 'name:' or when the section's header carries a value (spl_private_list drops
# each of those silently, and with a column-0 line every list line after it)
spl_private_list_strict() {
  spl_private_require || return 1
  yq . "$(spl_private_cnf_path)" >/dev/null 2>&1 || return 2
  awk -v want="$1" '
    /^[^[:space:]#]/ {
      if (sec == want && !/^[A-Za-z0-9_-]+:([[:space:]]|$)/) exit 2
      sec = $0; sub(/:.*/, "", sec)
      if (sec == want && !/^[^:]+:[[:space:]]*(#.*)?$/) exit 2
      next
    }
    sec == want && !/^[[:space:]]*(#|$)/ && !/^  - [^[:space:]]/ { exit 2 }
  ' "$(spl_private_cnf_path)" || return 2
  spl_private_list "$1"
}

# spl_private_has_tokens <file> -> 0 when the file holds a placeholder
spl_private_has_tokens() {
  grep -qE "(^|[^a-z0-9-])$SPL_PRIVATE_TOKEN_RE\b" "$1"
}

# spl_private_resolve <in> <out> -> <out> is <in> with every placeholder
# replaced by its slug (mode 600). FATAL on a missing overlay or on a
# placeholder the overlay does not map: a half-resolved file is never written.
spl_private_resolve() {
  local in="$1" out="$2" map script left
  map="$(spl_private_map)" || return 1
  script="$(awk -F'\t' '{ printf "s/(^|[^a-z0-9-])%s\\b/\\1%s/g\n", $1, $2 }' <<<"$map")"
  # twice: a match consumes the char before it, so in "a,b" the second of two
  # adjacent placeholders is only reached by the second pass
  (umask 077 && sed -E "$script" "$in" | sed -E "$script" >"$out.tmp.$$") || { rm -f "$out.tmp.$$"; return 1; }
  left="$(grep -oE "(^|[^a-z0-9-])$SPL_PRIVATE_TOKEN_RE\b" "$out.tmp.$$" | grep -oE "$SPL_PRIVATE_TOKEN_RE" | sort -u | paste -sd' ')"
  if [[ -n "$left" ]]; then
    rm -f "$out.tmp.$$"
    echo "FATAL $in names placeholder(s) the private overlay does not map: $left ($(spl_private_cnf_path))" >&2
    return 1
  fi
  mv -f "$out.tmp.$$" "$out"
}

# spl_private_token <slug> -> the slug's placeholder when it is hidden, else
# the slug itself. No overlay: the slug (nothing is known to be hidden).
spl_private_token() {
  local t
  [[ -s "$(spl_private_cnf_path)" ]] || { printf '%s\n' "$1"; return 0; }
  t="$(spl_private_map | awk -F'\t' -v s="$1" '$2 == s { print $1 }')" || return 1
  printf '%s\n' "${t:-$1}"
}

# spl_private_add <slug> [comment] -> hides a NEW slug: appends the next
# placeholder line to the overlay's workspaces: section (with `  # <comment>`
# after it when given, e.g. the reserve's `reserved <ts>`) and prints the
# placeholder. An already hidden slug prints its placeholder and changes
# nothing. Under an exclusive lock on <overlay>.lock (spec 158 H4: the reserve
# cron and a person both add here), waiting up to SPL_PRIVATE_LOCK_WAIT
# seconds (default 30): two adds never take the same number or drop a line.
spl_private_add() {
  local slug="$1" note="${2:-}" f
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "FATAL not a workspace slug: '$slug'" >&2; return 1; }
  [[ "$note" =~ ^[A-Za-z0-9:._\ -]*$ ]] || { echo "FATAL an overlay line comment is letters, digits, spaces and :._- only" >&2; return 1; }
  command -v flock >/dev/null || { echo "FATAL spl_private_add needs flock (the overlay lock)" >&2; return 1; }
  spl_private_require || return 1
  f="$(spl_private_cnf_path)"
  (
    umask 077
    exec {lk}>"$f.lock" || exit 1
    flock -w "${SPL_PRIVATE_LOCK_WAIT:-30}" "$lk" ||
      { echo "FATAL another writer holds $f.lock (waited ${SPL_PRIVATE_LOCK_WAIT:-30} s): nothing added" >&2; exit 1; }
    _spl_private_add_locked "$slug" "$note" "$f"
  )
}

# _spl_private_add_locked <slug> <comment> <file>: spl_private_add's body,
# run while the caller holds the overlay lock
_spl_private_add_locked() {
  local slug="$1" note="$2" f="$3" map n tok
  map="$(spl_private_map)" || return 1
  tok="$(awk -F'\t' -v s="$slug" '$2 == s { print $1 }' <<<"$map")"
  [[ -n "$tok" ]] && { printf '%s\n' "$tok"; return 0; }
  n="$(awk -F'\t' '{ sub(/^ws-hidden-/, "", $1); if ($1 + 0 > m) m = $1 + 0 } END { print m + 1 }' <<<"$map")"
  tok="$(printf 'ws-hidden-%02d' "$n")"
  # after the last line of the workspaces: section
  awk -v l="  $tok: $slug${note:+  # $note}" '
    /^[^[:space:]#]/ { if (inw) { print l; done = 1 } inw = ($0 ~ /^workspaces:/) }
    { print }
    END { if (inw && !done) print l }
  ' "$f" >"$f.tmp.$$" && chmod 600 "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
  [[ "$(spl_private_token "$slug")" == "$tok" ]] || { echo "FATAL $f: adding $slug did not take" >&2; return 1; }
  printf '%s\n' "$tok"
}

# spl_private_reserved_at <slug|placeholder> -> the <ts> of its workspaces:
# line's `# reserved <ts>` comment (written by do_spl_tenant_host_reserve,
# spec 158 H4); empty when the line has none (an add by hand), non-zero when
# the overlay has no such line
spl_private_reserved_at() {
  spl_private_require || return 1
  awk -v w="$1" '
    /^[^[:space:]#]/ { sec = $0; sub(/:.*/, "", sec); next }
    sec != "workspaces" { next }
    match($0, /^  ws-hidden-[0-9][0-9]+: [a-z0-9][a-z0-9-]*/) {
      split(substr($0, 3, RLENGTH - 2), kv, /: /)
      if (kv[1] != w && kv[2] != w) next
      found = 1
      if (match($0, /#[[:space:]]*reserved [^[:space:]]+/)) { r = substr($0, RSTART, RLENGTH); sub(/^#[[:space:]]*reserved /, "", r); print r }
      exit
    }
    END { exit !found }
  ' "$(spl_private_cnf_path)"
}

# spl_private_gate_patterns [base_domain] -> one PCRE per line, every form of
# every hidden name the hygiene gate refuses:
#   a workspaces: slug   anywhere, as a word (the default)
#   a forms_only slug    only as a workspace: an entry of a list whose key
#                        names workspaces / tenants / fqdns (cnf, tfvars),
#                        a DNS record name, <slug>.[dev.]<base_domain>
#                        (spool is also the product word)
#   each deny: entry     as written (PCRE)
# A word boundary is a Unicode letter or digit (\p{L}\p{N}), never ASCII
# only: after "í" a slug that ends a Spanish word is no word (SPL-4249). Run
# them with grep -P under LC_ALL="$(spl_private_gate_locale)", or \p{L} reads
# bytes and the accented letter is a boundary again.
# The word slugs share ONE line, one lookbehind and one lookahead around
# (?:s1|s2|...) in map order: the same hits as one lookaround per slug, but
# grep tries the boundary once per position instead of once per slug, and
# this is the gate's costliest sweep (perf round 9 row 01, about -47%).
spl_private_gate_patterns() {
  local base="${1:-}" map forms slug b words=""
  map="$(spl_private_map)" || return 1
  forms=" $(spl_private_list forms_only | tr '\n' ' ') "
  b="${base//./\\.}"
  while IFS=$'\t' read -r _ slug; do
    [[ -n "$slug" ]] || continue
    if [[ "$forms" == *" $slug "* ]]; then
      printf '%s\n' "(?i)(?:workspaces|tenants|fqdns)\\b.*[\\[,]\\s*\"?$slug\"?\\s*(?=[,\\]])" \
        "(?i)\"name\":\\s*\"$slug\""
      [[ -n "$b" ]] && printf '%s\n' "(?i)(?<![\\p{L}\\p{N}-])$slug\\.(?:dev\\.)?$b"
    else
      words+="${words:+|}$slug"
    fi
  done <<<"$map"
  [[ -n "$words" ]] && printf '%s\n' "(?i)(?<![\\p{L}\\p{N}])(?:$words)(?![\\p{L}\\p{N}])"
  spl_private_list deny
}

# spl_private_gate_locale -> a locale under which grep -P matches UTF-8
# characters, not bytes (the gate patterns need it whatever the caller's
# LC_ALL / LANG, e.g. C in cron or CI); non-zero when the box has none, so
# the gate can refuse instead of sweeping bytes (SPL-4249)
spl_private_gate_locale() {
  local l
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    # "é" is two bytes: one \p{L} only in a UTF-8 locale
    printf '\303\251\n' | LC_ALL="$l" grep -qxP '\p{L}' 2>/dev/null && { printf '%s\n' "$l"; return 0; }
  done
  echo "FATAL no UTF-8 locale for grep -P (tried C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8): the hidden-workspace patterns need one (SPL-4249)" >&2
  return 1
}
