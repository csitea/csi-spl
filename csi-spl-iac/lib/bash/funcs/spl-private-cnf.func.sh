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

# spl_private_add <slug> -> hides a NEW slug: appends the next placeholder
# line to the overlay's workspaces: section and prints the placeholder. An
# already hidden slug prints its placeholder and changes nothing.
spl_private_add() {
  local slug="$1" f map n tok
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "FATAL not a workspace slug: '$slug'" >&2; return 1; }
  f="$(spl_private_cnf_path)"
  map="$(spl_private_map)" || return 1
  tok="$(awk -F'\t' -v s="$slug" '$2 == s { print $1 }' <<<"$map")"
  [[ -n "$tok" ]] && { printf '%s\n' "$tok"; return 0; }
  n="$(awk -F'\t' '{ sub(/^ws-hidden-/, "", $1); if ($1 + 0 > m) m = $1 + 0 } END { print m + 1 }' <<<"$map")"
  tok="$(printf 'ws-hidden-%02d' "$n")"
  # after the last line of the workspaces: section
  awk -v l="  $tok: $slug" '
    /^[^[:space:]#]/ { if (inw) { print l; done = 1 } inw = ($0 ~ /^workspaces:/) }
    { print }
    END { if (inw && !done) print l }
  ' "$f" >"$f.tmp.$$" && chmod 600 "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
  [[ "$(spl_private_token "$slug")" == "$tok" ]] || { echo "FATAL $f: adding $slug did not take" >&2; return 1; }
  printf '%s\n' "$tok"
}

# spl_private_gate_patterns [base_domain] -> one PCRE per line, every form of
# every hidden name the hygiene gate refuses:
#   a workspaces: slug   anywhere, as a word (the default)
#   a forms_only slug    only as a workspace: an entry of a list whose key
#                        names workspaces / tenants / fqdns (cnf, tfvars),
#                        a DNS record name, <slug>.[dev.]<base_domain>
#                        (spool is also the product word)
#   each deny: entry     as written (PCRE)
spl_private_gate_patterns() {
  local base="${1:-}" map forms slug b
  map="$(spl_private_map)" || return 1
  forms=" $(spl_private_list forms_only | tr '\n' ' ') "
  b="${base//./\\.}"
  while IFS=$'\t' read -r _ slug; do
    [[ -n "$slug" ]] || continue
    if [[ "$forms" == *" $slug "* ]]; then
      printf '%s\n' "(?i)(?:workspaces|tenants|fqdns)\\b.*[\\[,]\\s*\"?$slug\"?\\s*(?=[,\\]])" \
        "(?i)\"name\":\\s*\"$slug\""
      [[ -n "$b" ]] && printf '%s\n' "(?i)(?<![a-z0-9-])$slug\\.(?:dev\\.)?$b"
    else
      printf '%s\n' "(?i)(?<![a-z0-9])$slug(?![a-z0-9])"
    fi
  done <<<"$map"
  spl_private_list deny
}
