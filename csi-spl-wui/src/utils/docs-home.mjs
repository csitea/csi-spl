/**
 * SPL-1882 (owner HUM-10, t1 2a2a4694: "remove the simple docs section from
 * the WUI and leave only the qto docs"): /docs alone is Docs (Qto) now.
 * pages/docs.vue calls it. Node tests import this file.
 */

/** /docs or /<lang>/docs -> the same prefix + /workspace/docs; '' for any other path. */
export function docsHomeTarget(path) {
  const m = /^((?:\/[a-z]{2})?)\/docs\/?$/.exec(String(path || ''))
  return m ? m[1] + '/workspace/docs' : ''
}
