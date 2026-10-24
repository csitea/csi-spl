<!-- SPL-2075 (owner HUM-10, t1 dbf2f39b, msg fd5a2bf4: "remove the Agents
     and the Boxes icons both from mobile and on desktop"): the two sections
     are in Monitoring now. SPL-3250 (t1 463d7692): so is the Event log, /events
     (its `#<id>` kept) lands on Monitoring -> Events. An old link (/agents, /agents/<id@box>, /boxes,
     /boxes/<id>, e.g. in an old post) lands on the matching Monitoring route,
     its `?r=` and seat hash kept (utils/monitoring-tabs.mjs
     legacyMonitoringPath). In the browser only: the WUI is `nuxt generate`
     on static hosting, where no server redirect runs, and the prerendered
     page stays this empty line, never a redirect loop. -->
<template>
  <div class="feed-col" data-test="legacy-redirect" />
</template>

<script setup lang="ts">
import { legacyMonitoringPath } from '~/utils/monitoring-tabs.mjs'

const route = useRoute()
const localePath = useLocalePath()

onMounted(() => {
  const to = legacyMonitoringPath(route.path)
  if (to) void navigateTo({ path: localePath(to), query: route.query, hash: route.hash }, { replace: true })
})
</script>
