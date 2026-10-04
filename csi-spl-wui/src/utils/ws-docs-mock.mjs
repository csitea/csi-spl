/**
 * The mock tenant's workspace docs (NUXT_PUBLIC_USE_MOCK): a small in-memory
 * bucket the Docs page reads and writes as it would the hub's
 * /v1/workspace/docs routes, so the editor and its e2e run without a hub.
 * Lives for the page's life; loaded lazily by useWorkspaceDocs.
 */

const START = {
  'welcome.md': '# Welcome\n\nThe workspace\'s own docs. Members can edit them.\n\nSee the [deploy runbook](./runbooks/deploy.md).\n',
  'runbooks/deploy.md': '# Deploy\n\n1. Build\n2. Ship\n\n| env | when |\n| --- | --- |\n| dev | every push |\n| prd | after dev |\n',
}

/** A fresh bucket. get: the body, null for a 404; put: last write wins, the old body to history; del: false for a 404. */
export function createMockWsDocs(seed = START) {
  const docs = new Map(Object.entries(seed))
  const history = []
  const title = (md, path) => (/^#\s+(.+?)\s*$/m.exec(md) || [])[1] || path.split('/').pop()
  return {
    get(path) {
      if (path === 'tree.json') {
        return JSON.stringify({ v: 1, files: [...docs].map(([p, md]) => ({ path: p, title: title(md, p) })) })
      }
      return docs.has(path) ? docs.get(path) : null
    },
    put(path, body) {
      if (docs.has(path)) history.push({ path, body: docs.get(path) })
      docs.set(path, String(body))
      return true
    },
    del(path) {
      if (!docs.has(path)) return false
      history.push({ path, body: docs.get(path) })
      docs.delete(path)
      return true
    },
    history,
  }
}
