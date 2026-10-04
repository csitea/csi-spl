/**
 * The mock tenant's Docs (NUXT_PUBLIC_USE_MOCK): a few repo-shaped docs, so
 * the section and its e2e run without a hub. Loaded lazily by the docs page.
 */

const DOCS = {
  'README.md': '# Spool\n\nThe repository root. Start with the [feature doc](./csi-spl-doc/doc/md/csi-spl.feature.md).\n',
  'csi-spl-doc/doc/md/csi-spl.feature.md': '# Spool feature\n\nHow the spool works.\n\n## Posting\n\nSee [How to post](../help/how-to-post.md) and [spec 072](../../specs/072-rapid-deployability/spec.md).\n\n| part | role |\n| --- | --- |\n| hub | relays |\n| box | runs agents |\n',
  'csi-spl-doc/doc/help/how-to-post.md': '# How to Post\n\nA post is markdown. Back to the [feature doc](../md/csi-spl.feature.md).\n\n```bash\necho hello\n```\n',
  'csi-spl-doc/specs/072-rapid-deployability/spec.md': '# Spec 072: rapid deployability\n\nA spec, published from the repo.\n',
}

const title = (md, path) => (/^#\s+(.+?)\s*$/m.exec(md) || [])[1] || path.split('/').pop()

/** The body the hub would answer for GET /v1/docs/<path>, null for a 404. */
export function mockDocs(path) {
  if (path === 'tree.json') {
    return JSON.stringify({ v: 1, files: Object.entries(DOCS).map(([p, md]) => ({ path: p, title: title(md, p) })) })
  }
  return Object.prototype.hasOwnProperty.call(DOCS, path) ? DOCS[path] : null
}
