#!/bin/bash
#------------------------------------------------------------------------------
# @description Build the /opt/tf provider layout under $TF_MIRROR_ROOT for a CI
# @description runner that lacks /opt/tf: a read-only filesystem mirror of the
# @description google + google-beta providers the terraform steps declare, and
# @description a terraformrc that serves them from it (everything else direct).
# @description Without it every run downloads the providers again and
# @description tf-steps-render-and-validate.tst.sh outgrows its 120 s (run
# @description 37020039069, runner without /opt/tf). Idempotent: when an offline
# @description init of the steps' provider constraints already resolves against
# @description the mirror nothing is downloaded. Concurrent builders are
# @description serialised by a lock; the mirror only ever gains files, so a
# @description reader is never handed a half-written tree.
# @description The CI iac-suite job (10_ci-quality.yml) runs this action.
# @param TF_MIRROR_ROOT - required, no default: e.g. $RUNNER_TOOL_CACHE/csi-spl-tf
# @param TF_BIN (optional) - default: terraform on PATH
# @example TF_MIRROR_ROOT=$HOME/.cache/csi-spl/tf ./run -a do_setup_tf_mirror
#------------------------------------------------------------------------------
do_setup_tf_mirror() {
  : "${TF_MIRROR_ROOT:?TF_MIRROR_ROOT must be set (no default) -- e.g. \$RUNNER_TOOL_CACHE/csi-spl-tf}"
  local root="$TF_MIRROR_ROOT" tf="${TF_BIN:-$(command -v terraform 2>/dev/null)}"
  local tree="$PROJ_PATH/src/terraform" probe platform p c names=() rc=0
  [[ -n "$tf" && -x "$tf" ]] || { do_log "FATAL no terraform (TF_BIN or PATH)"; return 1; }
  [[ -d "$tree" ]] || { do_log "FATAL no terraform tree at $tree"; return 1; }
  export CHECKPOINT_DISABLE=1
  platform=$("$tf" version | sed -n 's/^on //p' | head -1)
  [[ "$platform" =~ ^[a-z0-9]+_[a-z0-9]+$ ]] || { do_log "FATAL cannot read the platform from '$tf version'"; return 1; }
  mkdir -p "$root/mirror" || return 1

  probe=$(mktemp -d) || return 1
  # the constraints the steps declare, per provider, joined: init must meet all
  { echo 'terraform {'; echo '  required_providers {'
    for p in google google-beta; do
      c=$(grep -rh -A1 "source *= *\"hashicorp/$p\"" "$tree" --include='*.tf' \
          | sed -n 's/^ *version *= *"\([^"]*\)".*/\1/p' | sort -u | paste -sd, - | sed 's/,/, /g')
      [[ -n "$c" ]] || continue
      names+=("$p"); printf '    %s = {\n      source  = "hashicorp/%s"\n      version = "%s"\n    }\n' "$p" "$p" "$c"
    done
    echo '  }'; echo '}'; } >"$probe/main.tf"
  (( ${#names[@]} )) || { do_log "FATAL no hashicorp/google provider declared under $tree"; rm -rf "$probe"; return 1; }

  local inc; inc=$(printf '"registry.terraform.io/hashicorp/%s", ' "${names[@]}"); inc="[${inc%, }]"
  printf '%s\n' \
    "# CI provider source for csi-spl, written by do_setup_tf_mirror (the /opt/tf layout)." \
    "provider_installation {" \
    "  filesystem_mirror {" \
    "    path    = \"$root/mirror\"" \
    "    include = $inc" \
    "  }" \
    "  direct {" \
    "    exclude = $inc" \
    "  }" \
    "}" >"$root/terraformrc.new" && mv -f "$root/terraformrc.new" "$root/terraformrc" || { rm -rf "$probe"; return 1; }

  # resolves <- an init of the probe against the mirror alone, no plugin cache
  resolves() {
    rm -rf "$probe/.terraform" "$probe/.terraform.lock.hcl"
    env -u TF_PLUGIN_CACHE_DIR TF_CLI_CONFIG_FILE="$root/terraformrc" \
      "$tf" -chdir="$probe" init -backend=false -input=false -no-color >"$probe.init.log" 2>&1
  }
  exec 9>"$root.lock" && flock 9 || { do_log "FATAL cannot lock $root.lock"; rm -rf "$probe"; return 1; }
  if resolves; then
    do_log "INFO provider mirror $root/mirror already serves ${names[*]} ($platform)"
  else
    do_log "INFO downloading ${names[*]} ($platform) into $root/mirror"
    rm -rf "$root/mirror.new"
    if ! env -u TF_CLI_CONFIG_FILE -u TF_PLUGIN_CACHE_DIR "$tf" -chdir="$probe" providers mirror \
         -platform="$platform" "$root/mirror.new" >"$probe.mirror.log" 2>&1; then
      do_log "FATAL terraform providers mirror failed: $(tail -3 "$probe.mirror.log" | tr '\n' ' ')"; rc=1
    elif ! cp -a "$root/mirror.new/." "$root/mirror/"; then
      do_log "FATAL cannot copy the downloaded providers into $root/mirror"; rc=1
    elif ! resolves; then
      do_log "FATAL the mirror still does not serve ${names[*]}: $(tail -3 "$probe.init.log" | tr '\n' ' ')"; rc=1
    else
      do_log "INFO provider mirror $root/mirror now serves ${names[*]} ($platform)"
    fi
    rm -rf "$root/mirror.new"
  fi
  flock -u 9; exec 9>&-
  rm -rf "$probe" "$probe.init.log" "$probe.mirror.log"
  return "$rc"
}
