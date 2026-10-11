// `/` lands on Channels (t1 e4bfddb1): on a cold load of `/?topic=<id>` the
// hydration drops the query from the address and restores it later, so the
// page cannot read it when it mounts. Note the address as loaded, before any
// of that (pages/index.vue takes it once).
import { noteLoadedUrl } from '~/utils/home-target.mjs'

export default defineNuxtPlugin({
  name: 'spool:loaded-url',
  enforce: 'pre',
  setup() {
    noteLoadedUrl(window.location.pathname, window.location.search)
  },
})
