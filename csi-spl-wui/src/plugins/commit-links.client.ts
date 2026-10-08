// Commit hashes in a message link to this instance's repository (HUM-10):
// cnf env.wui.repo_web_url + repo_commit_path, read from /config.json. Either
// unset = nothing loads and a hash stays text. The matcher is its own chunk
// (dynamic import), so the initial script does not grow; a body rendered
// before it arrives re-renders, because the provider reads a ref. Spec 109
// T006: asked once the app is ready, not during the boot before mount.
import { setCommitLinkProvider } from '~/utils/commit-link-hook.mjs'

type Linker = { blocks: (b: unknown[]) => unknown[], markdown: (s: string) => string } | null

export default defineNuxtPlugin(() => {
  const pub = useRuntimeConfig().public as Record<string, unknown>
  const webUrl = String(pub.repoWebUrl || '').trim()
  const commitPath = String(pub.repoCommitPath || '').trim()
  if (!webUrl || !commitPath) return
  const linker = shallowRef<Linker>(null)
  setCommitLinkProvider(() => linker.value)
  onNuxtReady(() => {
    import('~/utils/commit-links.mjs')
      .then((m) => { linker.value = m.commitLinker(webUrl, commitPath) })
      .catch(() => { /* hashes stay text */ })
  })
})
