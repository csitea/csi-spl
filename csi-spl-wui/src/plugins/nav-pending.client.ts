import type { RouteLocationRaw } from 'vue-router'
import { navEnded, navPending, navStarted } from '~/utils/nav-pending'

/* a plugin, not the page: a move can start before the page it leaves has set up
   (a tapped alert's, on boot). Marked where it is asked for: a guard runs only
   after Nuxt's async one, and a replace in that gap would cancel the move. The
   guards are for what no call starts: Back and Forward. */
export default defineNuxtPlugin(() => {
  const router = useRouter()
  for (const verb of ['push', 'replace'] as const) {
    const go = router[verb]
    router[verb] = (to: RouteLocationRaw) => {
      const mark = { path: router.resolve(to).path }
      navStarted(mark)
      const moved = go(to)
      const end = () => navEnded(mark)
      moved.then(end, end)
      return moved
    }
  }
  router.beforeEach((to) => { if (!navPending()) navStarted(to) })
  router.afterEach((to) => { navEnded(to) })
})
