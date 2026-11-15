#!/bin/bash
#------------------------------------------------------------------------------
# @description Build a job-application pack from a vacancy link and the master
# @description CVs (SPL-5555; csitea weekly item 12): 5 documents (CV,
# @description highlights, projects per requirement, requirements per project,
# @description why-letter) per language, each html + pdf + docx, an index per
# @description language, one zip to send, and a fit table. One versioned tool,
# @description src/bash/scripts/job-pack.py, in place of the generator each
# @description pack lane copied and edited by hand. The code holds no personal
# @description data: the name, the CV text and the per-vacancy wording are read
# @description at run time from MASTER_CV_DIR and CONTENT, both outside git;
# @description the pack goes to OUT_DIR, refused inside a git checkout.
# @description Each step runs when its input is set: VACANCY_URL fetches the ad
# @description to OUT_DIR/vacancy/ (text + contact addresses), MASTER_CV_DIR
# @description picks the base CV per language (OUT_DIR/internal/pick.md),
# @description CONTENT builds OUT_DIR/out/ and OUT_DIR/internal/{fit,files}.md.
# @description Without CONTENT it stops after the pick and says what is next.
# @description The CONTENT contract: csi-spl-doc/doc/md/job-pack.md section 3.
# @param OUT_DIR (required) - the pack's work dir, e.g. the topic's work dir
# @param VACANCY_URL (optional) - the ad (https:// or file://); default the
# @param   OUT_DIR/vacancy/vacancy.txt of an earlier run
# @param MASTER_CV_DIR (optional) - dir of base CV html files (*cv*.html)
# @param CONTENT (optional) - the per-vacancy content file (python)
# @param JOB_PACK_PANDOC (optional) - default pandoc
# @param JOB_PACK_CHROME (optional) - default google-chrome
# @param JOB_PACK_PDFINFO (optional) - default pdfinfo (page counts only)
# @example OUT_DIR=/srv/pack VACANCY_URL=https://example.com/job/1 MASTER_CV_DIR=/srv/cvs ./run -a do_job_pack
# @example OUT_DIR=/srv/pack MASTER_CV_DIR=/srv/cvs CONTENT=/srv/pack/content.py ./run -a do_job_pack
#------------------------------------------------------------------------------

# Exit: 0 done, 1 a usage refusal, 2 a build refusal, 3 the vacancy could
# not be fetched.
do_job_pack() {
  local orc out
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  out="${OUT_DIR:-}"
  [[ -n "$out" ]] || { echo "FATAL job-pack: OUT_DIR must be set, e.g. OUT_DIR=/srv/pack"; return 1; }
  [[ -n "${VACANCY_URL:-}${MASTER_CV_DIR:-}${CONTENT:-}" ]] ||
    { echo "FATAL job-pack: set at least one of VACANCY_URL, MASTER_CV_DIR, CONTENT"; return 1; }
  [[ -z "${MASTER_CV_DIR:-}" || -d "$MASTER_CV_DIR" ]] || { echo "FATAL job-pack: MASTER_CV_DIR $MASTER_CV_DIR is not a dir"; return 1; }
  [[ -z "${CONTENT:-}" || -f "$CONTENT" ]] || { echo "FATAL job-pack: CONTENT $CONTENT is not a file"; return 1; }
  job_pack_out_not_in_git "$out" || return 1
  mkdir -p "$out" || { echo "FATAL job-pack: cannot make OUT_DIR $out"; return 1; }
  python3 "$orc/src/bash/scripts/job-pack.py" --out "$out" \
    --vacancy-url "${VACANCY_URL:-}" --master-cv-dir "${MASTER_CV_DIR:-}" --content "${CONTENT:-}" \
    --pandoc "${JOB_PACK_PANDOC:-pandoc}" --chrome "${JOB_PACK_CHROME:-google-chrome}" \
    --pdfinfo "${JOB_PACK_PDFINFO:-pdfinfo}"
}

# job_pack_out_not_in_git <dir>: refuse a dir inside a git checkout (the
# pack carries personal data; it must never be one `git add` away). The dir
# may not exist yet: its nearest existing parent is checked.
job_pack_out_not_in_git() {
  local d="$1"
  while [[ ! -d "$d" && "$d" == */* ]]; do d="${d%/*}"; [[ -n "$d" ]] || d=/; done
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FATAL job-pack: OUT_DIR $1 is inside a git checkout ($(git -C "$d" rev-parse --show-toplevel)): the pack holds personal data, put it outside git"
    return 1
  fi
}
