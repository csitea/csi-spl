// SPL-1006: the running build vs the deployed one (utils/build-watch.mjs has
// the rules). One shared state: plugins/build-watch.client.ts fills it,
// BuildUpdateBar shows the prompt, the sidebar version pop-up says when a
// newer build is live.
import { GUARD_KEY, normCommit } from '~/utils/build-watch.mjs'

export interface BuildWatchState {
  /** the commit this tab runs (baked in at build time); '' in lde */
  running: string
  /** the deployed commit from the last /build.json read; '' until read */
  live: string
  /** show the "new version" bar */
  prompt: boolean
}

export function useBuildWatch() {
  return useState<BuildWatchState>('build-watch', () => ({
    running: normCommit(useRuntimeConfig().public.buildCommit),
    live: '',
    prompt: false,
  }))
}

export function readReloadGuard(): string {
  try { return sessionStorage.getItem(GUARD_KEY) || '' } catch { return '' }
}

/** Reload into the live build, remembering that this tab did so for it. */
export function reloadForBuild(live: string) {
  try { sessionStorage.setItem(GUARD_KEY, live) } catch { /* storage blocked */ }
  window.location.reload()
}
