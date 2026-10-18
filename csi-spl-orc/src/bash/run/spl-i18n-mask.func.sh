#!/bin/bash
#------------------------------------------------------------------------------
# @description The MASKED copy of spec 115 (section 2, T9; owner decision Q2
# @description "2b"): multilingual text that carries personal data
# @description (LANE_MIX_SENSITIVE=1 on an i18n task) is drafted by claude,
# @description grok or mistral under the data rule; agy then reviews a copy
# @description with the personal data replaced, and never the original.
# @description What counts as personal data for the mask (the build-time
# @description list of spec 115):
# @description   email  - any address, by pattern
# @description   phone  - +<country> numbers, and national numbers that start
# @description            with 0 in two or more digit groups (040 123 4567)
# @description   name, workspace, other - the terms listed in I18N_MASK_TERMS,
# @description            one `<name|workspace|other> <term>` per line; a term
# @description            matches case-insensitively at a word start, with any
# @description            letters after it (inflected forms: Henkilö -> Henkilölle)
# @description Each distinct match becomes a token [EMAIL_1], [PHONE_1],
# @description [NAME_1], [WORKSPACE_1], [OTHER_1]. Writes, under I18N_MASK_OUT:
# @description   agy/      the masked copy, same relative paths: the ONLY path an
# @description             agy lane is given (printed as agy_review_dir=)
# @description   map.tsv   token -> original, mode 0600, for do_spl_i18n_unmask
# @description             it stays with the drafter, never in an agy brief
# @description Before agy/ exists the copy is checked: every pattern and term
# @description again, and every original value of map.tsv as a plain string,
# @description must be 0 hits; else exit 3, the hits as `<file>:<line> <class>`
# @description (never the value) and no agy/ at all. Binary files are left out.
# @description A term the list does not name is NOT masked: the list is the
# @description drafter's to complete (names, workspace names, anything else).
# @param I18N_MASK_SRC - required: the drafted text, a file or a directory
# @param I18N_MASK_TERMS - required: the term list (may be empty, must exist)
# @param I18N_MASK_OUT (optional) - default $SPOOL_ROOT/dispatch/<LANE_MIX_TASK>/i18n-mask
# @param LANE_MIX_TASK (optional) - the task_id, for the default I18N_MASK_OUT
# @example I18N_MASK_SRC=<work>/locales I18N_MASK_TERMS=<work>/pii-terms.txt LANE_MIX_TASK=<task_id> ./run -a do_spl_i18n_mask
#------------------------------------------------------------------------------
do_spl_i18n_mask() {
  do_require_bin perl || return 1
  local src="${I18N_MASK_SRC:-}" terms="${I18N_MASK_TERMS:-}" out rel f hits
  out="$(_spl_i18n_mask_out)" || return 1
  [[ -e "$src" ]] || { do_log "FATAL I18N_MASK_SRC must name the drafted text, a file or a directory, got '$src'"; return 1; }
  [[ -f "$terms" && -r "$terms" ]] || {
    do_log "FATAL I18N_MASK_TERMS must name the term list (<name|workspace|other> <term> per line; empty is allowed), got '$terms'"; return 1; }
  src="$(realpath -m "$src")" terms="$(realpath -m "$terms")" out="$(realpath -m "$out")"
  _spl_i18n_mask_apart "$src" "$out" || return 1
  spl_refuse_desk_cron_tree do_spl_i18n_mask "$out" || return 1
  mkdir -p "$out" && chmod 0700 "$out" || return 1
  rm -rf "$out/agy" "$out/agy.tmp" "$out/map.tsv"
  mkdir -p "$out/agy.tmp"
  local list="$out/files.lst"
  _spl_i18n_mask_files "$src" >"$list"
  while IFS= read -r rel; do
    f="$src"; [[ -d "$src" ]] && f="$src/$rel"
    mkdir -p "$(dirname "$out/agy.tmp/$rel")"
    printf '%s\0%s\0' "$f" "$out/agy.tmp/$rel"
  done <"$list" | (umask 077; perl -e "$_SPL_I18N_MASK_PL" mask "$terms" "$out/map.tsv") || {
    do_log "FATAL the mask step failed"; rm -rf "$out/agy.tmp"; return 1; }
  if ! hits="$(cd "$out/agy.tmp" && _spl_i18n_mask_check "$terms" "$out/map.tsv" "$list")"; then
    rm -rf "$out/agy.tmp"
    printf '%s\n' "$hits"
    do_log "FATAL the masked copy still carries personal data (hits above, values never printed): no agy/ written"
    return 3
  fi
  mv "$out/agy.tmp" "$out/agy"
  printf 'masked: files=%s %s\n' "$(wc -l <"$list")" "$(_spl_i18n_mask_counts "$out/map.tsv")"
  rm -f "$list"
  printf 'check: 0 hits for every pattern, term and original value in agy/\n'
  printf 'agy_review_dir=%s\n' "$out/agy"
  printf 'map=%s (0600; stays with the drafter, never in an agy brief)\n' "$out/map.tsv"
}

# _spl_i18n_mask_out -> the mask directory: I18N_MASK_OUT, else
# $SPOOL_ROOT/dispatch/<LANE_MIX_TASK>/i18n-mask
_spl_i18n_mask_out() {
  if [[ -n "${I18N_MASK_OUT:-}" ]]; then echo "${I18N_MASK_OUT%/}"; return 0; fi
  [[ "${LANE_MIX_TASK:-}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    do_log "FATAL set I18N_MASK_OUT, or LANE_MIX_TASK (the task_id) for the default" >&2; return 1; }
  echo "${SPOOL_ROOT:-/var/spool-hub}/dispatch/$LANE_MIX_TASK/i18n-mask"
}

# _spl_i18n_mask_apart <a> <b> -> refuses when either path holds the other:
# the masked copy and the original never share a tree
_spl_i18n_mask_apart() {
  local a b
  a="$(realpath -m "$1")" b="$(realpath -m "$2")"
  if [[ "$a" == "$b" || "$b/" == "$a/"* || "$a/" == "$b/"* ]]; then
    do_log "FATAL $2 and $1 overlap: the masked copy and the original must be apart"; return 1
  fi
}

# _spl_i18n_mask_files <src> -> the text files to mask, relative to <src>
# (a file: its own name), sorted; binary files and .git are left out
_spl_i18n_mask_files() {
  if [[ -f "$1" ]]; then basename "$1"; return 0; fi
  (cd "$1" && find . -name .git -prune -o -type f -printf '%P\n' | sort | while IFS= read -r f; do
     if [[ ! -s "$f" ]] || grep -Iq . "$f"; then printf '%s\n' "$f"; fi
   done)
}

# _spl_i18n_mask_check <terms> <map> <list> -> run in the masked copy: one
# `<file>:<line> <class>` line per hit and exit 1, or nothing and exit 0
_spl_i18n_mask_check() {
  local rel
  while IFS= read -r rel; do printf '%s\0' "$rel"; done <"$3" \
    | perl -e "$_SPL_I18N_MASK_PL" check "$1" "$2"
}

# _spl_i18n_mask_counts <map> -> `email=N phone=N name=N workspace=N other=N`
_spl_i18n_mask_counts() {
  awk -F'\t' '{ c = tolower($1); sub(/^\[/, "", c); sub(/_[0-9]+\]$/, "", c); n[c]++ }
    END { printf "email=%d phone=%d name=%d workspace=%d other=%d\n", n["email"], n["phone"], n["name"], n["workspace"], n["other"] }' "$1"
}

# The one matcher of mask, check and unmask. Paths come NUL-separated on
# stdin: mask and unmask read <in> <out> pairs, check one path per file.
_SPL_I18N_MASK_PL='
use strict; use warnings;
use open qw(:encoding(UTF-8));
binmode STDOUT, ":encoding(UTF-8)";
my ($mode, @a) = @ARGV;
my $L = qr/[\p{L}\p{N}_]/;
my $EMAIL = qr/[\p{L}\p{N}._%+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+/;
my $PHONE = qr/(?<![\p{N}+])(?:\+[0-9][0-9 ().-]{6,18}[0-9]|0[0-9]{1,4}[ -][0-9]{2,4}(?:[ -]?[0-9]{2,4}){1,2})(?![\p{N}])/;
sub terms {
  my @t;
  open(my $fh, "<", $_[0]) or die "cannot read the term list\n";
  while (<$fh>) {
    s/\r?\n$//; next if /^\s*(#|$)/;
    /^\s*(name|workspace|other)\s+(\S.*?)\s*$/ or die "term list line $.: want <name|workspace|other> <term>\n";
    push @t, [uc $1, $2];
  }
  return sort { length($b->[1]) <=> length($a->[1]) } @t;
}
sub slurp { open(my $fh, "<", $_[0]) or die "cannot read $_[0]\n"; local $/; my $s = <$fh>; return defined $s ? $s : ""; }
sub spew { open(my $fh, ">", $_[0]) or die "cannot write $_[0]\n"; print $fh $_[1]; close $fh or die "cannot write $_[0]\n"; }
sub paths { local $/ = "\0"; my @p = <STDIN>; chomp @p; return @p; }
sub alt { return @_ ? join("|", map { quotemeta $_->[1] } @_) : "(?!)"; }
if ($mode eq "mask") {
  my ($terms, $map) = @a; my @t = terms($terms); my $T = alt(@t);
  my (%tok, %n, @order);
  my $take = sub { my ($c, $v) = @_; return $tok{$v} //= do { push @order, $v; "[" . $c . "_" . ++$n{$c} . "]" }; };
  my $class = sub { my $m = lc $_[0]; for (@t) { return $_->[0] if index($m, lc $_->[1]) == 0 } return "OTHER"; };
  my @p = paths();
  while (my ($in, $out) = splice(@p, 0, 2)) {
    my $s = slurp($in);
    $s =~ s/($EMAIL)|($PHONE)|(?<!$L)((?:$T)\p{L}*)/defined $1 ? $take->("EMAIL", $1) : defined $2 ? $take->("PHONE", $2) : $take->($class->($3), $3)/gie;
    spew($out, $s);
  }
  spew($map, join("", map { "$tok{$_}\t$_\n" } @order));
} elsif ($mode eq "check") {
  my ($terms, $map) = @a; my @t = terms($terms); my $hits = 0;
  my @orig = map { s/\n$//r } map { (split /\t/, $_, 2)[1] } grep { /\t/ } split /^/m, slurp($map);
  for my $f (paths()) {
    my $ln = 0;
    for my $line (split /\n/, slurp($f)) {
      $ln++; my @c;
      push @c, "email" if $line =~ $EMAIL;
      push @c, "phone" if $line =~ $PHONE;
      for (@t) { my $q = quotemeta $_->[1]; push @c, lc $_->[0] if $line =~ /(?<!$L)$q/i }
      for (@orig) { push @c, "original" if index(lc $line, lc $_) >= 0 }
      for (@c) { print "$f:$ln $_\n"; $hits++ }
    }
  }
  exit($hits ? 1 : 0);
} elsif ($mode eq "unmask") {
  my ($map) = @a; my (%v, %seen);
  for (split /^/m, slurp($map)) { s/\n$//; my ($k, $o) = split /\t/, $_, 2; $v{$k} = $o if defined $o }
  my @p = paths();
  while (my ($in, $out) = splice(@p, 0, 2)) {
    my $s = slurp($in);
    $s =~ s/(\[(?:EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\])/exists $v{$1} ? do { $seen{$1} = 1; $v{$1} } : $1/ge;
    spew($out, $s);
  }
  my @miss = grep { !$seen{$_} } sort keys %v;
  print "missing $_\n" for @miss;
  exit(@miss ? 4 : 0);
} else { die "mode must be mask, check or unmask\n"; }
'
