<!-- `/`, the front door. Owner HUM-10 (t1 e4bfddb1, msg a78e06c8): "Remove
     the whole topics view" - this page was the Topics list. It now lands on
     Channels: a desktop opens #lobby (a `?topic=` deep link rides along to
     open the right pane there); a phone shows the Channels list, the left
     panel (level 1), as its front door always did. -->
<template>
  <div class="feed-col" data-testid="home-redirect" />
</template>

<script setup lang="ts">
import { useMobileStack } from '~/composables/useMobileStack'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { lobbyHomeTarget, takeLoadedQuery } from '~/utils/home-target.mjs'
import { isMobileFrontDoor } from '~/utils/mobile-stack.mjs'

const route = useRoute()
const localePath = useLocalePath()
const stack = useMobileStack()
/* `/` is prerendered: on a cold load the router holds the prerendered
   route (no query) and the hydration drops the query from the address and
   restores it later, so neither is reliable when this page mounts. The
   address as loaded is (takeLoadedQuery). A cold link that names a topic
   (`/?topic=<id>`, `?in=`) loads #lobby with it, a full load out of that
   churn; anything else waits for the query to settle, then goes in-app. */
const topic = useSettledQuery('topic')

onMounted(() => {
  const loaded = takeLoadedQuery(isMobileFrontDoor)
  const cold = loaded !== null
  const query: Record<string, string> = {}
  if (cold) Object.assign(query, loaded)
  else for (const [k, v] of Object.entries(route.query)) if (typeof v === 'string') query[k] = v
  const to = lobbyHomeTarget({ phone: stack.isMobile.value, query })
  if (cold && to && (query.topic || query.in)) {
    window.location.replace(localePath(to.path) + '?' + new URLSearchParams(query).toString() + window.location.hash)
    return
  }
  let done = false
  watch(topic.settled, (ready) => {
    if (!ready || done) return
    done = true
    if (to) void navigateTo({ path: localePath(to.path), query: to.query as Record<string, string>, hash: route.hash }, { replace: true })
    else if (stack.level.value !== 1) stack.home()
  }, { immediate: true })
})
</script>
