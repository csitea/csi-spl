#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Remove the old per-env + per-step terraform plugin caches
# @description (SPL-2821). do_tf_init kept one cache per
# @description plugin-cache/<org>/<app>/<env>/<step>, so every step held its own
# @description copy of the same providers (6.0 GB in the tf-runner on sat,
# @description 2026-10-22); it now uses the one shared plugin-cache dir. This
# @description removes ONLY <org>/<app>/<env>/<step> dirs: four plain name
# @description levels (no dot, so never a registry host or a provider version
# @description of the shared cache) and a step named like the terraform steps
# @description (NNN-...). The shared cache and anything else stay.
# @description Prints one line per dir, then a total in bytes. Run it where the
# @description cache is, in the tf-runner (see the example).
# @param TF_PLUGIN_CACHE_ROOT (optional) - default $HOME/.terraform.d/plugin-cache
# @param DRY_RUN (optional) - default 1: print what it would remove and the
# @param   bytes; 0 removes
# @example docker exec con-csi-csi-spl-tf-runner ./run -a do_remove_tf_plugin_cache_per_step
# @example docker exec -e DRY_RUN=0 con-csi-csi-spl-tf-runner ./run -a do_remove_tf_plugin_cache_per_step
#------------------------------------------------------------------------------
do_remove_tf_plugin_cache_per_step() {
  local root="${TF_PLUGIN_CACHE_ROOT:-$HOME/.terraform.d/plugin-cache}" dry="${DRY_RUN:-1}"
  local d rel bytes total=0 n=0 verb="WOULD REMOVE"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { echo "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 1; }
  [[ "$dry" == 0 ]] && verb="REMOVED"
  if [[ ! -d "$root" ]]; then
    echo "TF_PLUGIN_CACHE per-step dirs=0 bytes=0 dry_run=$dry (no $root)"
    return 0
  fi
  root="$(cd "$root" && pwd -P)"
  while IFS= read -r rel; do
    d="$root/$rel"
    bytes=$(du -sb -- "$d" 2>/dev/null | cut -f1)
    if [[ "$dry" == 0 ]]; then
      rm -rf -- "$d" || { echo "FAIL could not remove $d"; return 1; }
    fi
    echo "$verb ${bytes:-0} $rel"
    total=$((total + ${bytes:-0})); n=$((n + 1))
  done < <(tf_plugin_cache_per_step_dirs "$root")
  echo "TF_PLUGIN_CACHE per-step dirs=$n bytes=$total ($(numfmt --to=iec "$total" 2>/dev/null || echo "$total B")) dry_run=$dry root=$root"
}

# tf_plugin_cache_per_step_dirs <root>: the <org>/<app>/<env>/<step> dirs
# under root, relative, sorted. Real dirs only (find does not follow links).
tf_plugin_cache_per_step_dirs() {
  local name='[a-z0-9][a-z0-9_-]*' rel
  find "$1" -mindepth 4 -maxdepth 4 -type d -printf '%P\n' 2>/dev/null | sort |
    while IFS= read -r rel; do
      [[ "$rel" =~ ^$name/$name/$name/[0-9]{3}-[a-z0-9_-]+$ ]] && echo "$rel"
    done
}
