#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Spec 142 section 5.5, row B3: the drift report, read-only.
# @description Compares what is on this box with its class manifest
# @description (cnf/box-pkgs/<class>.tsv) and prints one line per difference:
# @description   NOT-IN-MANIFEST <kind> <name> [agent=<id> issue=<SPL-n> reason=<text>]
# @description   MISSING-FROM-BOX <kind> <name>
# @description On the box: `apt-mark showmanual` minus base-<class>.txt (the
# @description image's own set), and every executable in the bin dirs. The
# @description agent, issue and reason come from the box journal (spec 5.2
# @description step 4) when a journal line names the package. A manifest
# @description `apt`/`deb` row matches a package name, a `bin` row a path or a
# @description bare name; other kinds (pip, npm, go, ...) have no box probe
# @description here and are never reported missing. Exit 0 with or without
# @description drift; DRIFT_STRICT=1 exits 2 on any NOT-IN-MANIFEST; a missing
# @description input exits 1.
# @param BOX_CLASS (optional) - pc or satellite; default BOX_CLASS in
# @param        $SPOOL_BOX_ENV (default /var/spool-hub/box.env)
# @param BOX_PKG_MANIFEST_DIR (optional) - default $PROJ_PATH/cnf/box-pkgs
# @param BOX_PKG_JOURNAL (optional) - default /var/lib/csi-spl/box-pkg/journal.tsv;
# @param        a missing journal only means no agent ids
# @param BOX_PKG_BIN_DIRS (optional) - space separated, default
# @param        "/usr/local/bin $HOME/.local/bin" (the agent user's)
# @param DRIFT_STRICT (optional) - 1: exit 2 on any NOT-IN-MANIFEST
# @example BOX_CLASS=pc ./run -a do_box_pkg_drift
#------------------------------------------------------------------------------

# _box_pkg_drift_class: BOX_CLASS, else the BOX_CLASS line of the box config
_box_pkg_drift_class() {
  local v="${BOX_CLASS:-}" f="${SPOOL_BOX_ENV:-/var/spool-hub/box.env}" k val
  if [[ -z "$v" && -r "$f" ]]; then
    while IFS='=' read -r k val || [[ -n "$k" ]]; do
      [[ "$k" == BOX_CLASS ]] || continue
      val="${val%$'\r'}"; val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
      v="$val"
    done <"$f"
  fi
  printf '%s' "$v"
}

# _box_pkg_drift_box <base list> <bin dirs>: `<kind>\t<name>` lines on the box
_box_pkg_drift_box() {
  local base="$1" d f pkgs
  pkgs="$(apt-mark showmanual)" || return 1
  sort -u <<<"$pkgs" |
    comm -23 - <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$base" | sort -u) |
    sed -e '/^$/d' -e 's/^/apt\t/'
  for d in $2; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      [[ -f "$f" && -x "$f" ]] && printf 'bin\t%s\n' "$f"
    done
  done
  return 0
}

# _box_pkg_drift_journal <journal>: `<name>\t<agent>\t<issue>\t<reason>` for
# every package a journal line requested or installed; the newest line wins
_box_pkg_drift_journal() {
  [[ -r "$1" ]] || return 0
  awk -F '\t' '
    /^#/ || NF < 7 { next }
    {
      n = split($6 " " $7, p, " ")
      for (i = 1; i <= n; i++) if (p[i] != "") who[p[i]] = $3 "\t" $4 "\t" $10
    }
    END { for (k in who) print k "\t" who[k] }' "$1"
}

# _box_pkg_drift_report <manifest> <box lines> <journal lines>: the report,
# unsorted; rc 3 when it printed a NOT-IN-MANIFEST line
_box_pkg_drift_report() {
  awk -F '\t' '
    FILENAME == ARGV[1] {
      if ($0 ~ /^#/ || NF < 2) next
      k = ($1 == "deb") ? "apt" : $1
      want[k "\t" $2] = $1
      next
    }
    FILENAME == ARGV[2] {
      if (NF >= 2) who[$1] = "agent=" $2 " issue=" $3 " reason=" $4
      next
    }
    NF >= 2 {
      n = $2; sub(/.*\//, "", n)
      seen[$0] = 1; seen[$1 "\t" n] = 1
      if (($0 in want) || (($1 "\t" n) in want)) next
      w = ($2 in who) ? who[$2] : (n in who) ? who[n] : ""
      print "NOT-IN-MANIFEST " $1 " " $2 (w == "" ? "" : " " w)
      drift = 1
    }
    END {
      for (k in want) {
        split(k, kn, "\t")
        if ((kn[1] == "apt" || kn[1] == "bin") && !(k in seen))
          print "MISSING-FROM-BOX " want[k] " " kn[2]
      }
      exit drift ? 3 : 0
    }' "$1" <(printf '%s\n' "$3") <(printf '%s\n' "$2")
}

do_box_pkg_drift() {
  local class dir manifest base box journal out rc=0
  class="$(_box_pkg_drift_class)"
  [[ -n "$class" ]] || { echo "ERROR: BOX_CLASS must be set (env or ${SPOOL_BOX_ENV:-/var/spool-hub/box.env})" >&2; return 1; }
  dir="${BOX_PKG_MANIFEST_DIR:-${PROJ_PATH:-.}/cnf/box-pkgs}"
  manifest="$dir/$class.tsv" base="$dir/base-$class.txt"
  [[ -r "$manifest" ]] || { echo "ERROR: no manifest $manifest" >&2; return 1; }
  [[ -r "$base" ]] || { echo "ERROR: no base list $base" >&2; return 1; }
  box="$(_box_pkg_drift_box "$base" "${BOX_PKG_BIN_DIRS:-/usr/local/bin $HOME/.local/bin}")" ||
    { echo "ERROR: apt-mark showmanual failed" >&2; return 1; }
  journal="$(_box_pkg_drift_journal "${BOX_PKG_JOURNAL:-/var/lib/csi-spl/box-pkg/journal.tsv}")"
  out="$(_box_pkg_drift_report "$manifest" "$box" "$journal")" || rc=$?
  [[ "$rc" == 0 || "$rc" == 3 ]] || { echo "ERROR: drift report failed (rc $rc)" >&2; return 1; }
  [[ -z "$out" ]] || sort <<<"$out"
  [[ "${DRIFT_STRICT:-0}" == 1 && "$rc" == 3 ]] && return 2
  return 0
}
