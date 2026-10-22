<!-- SPL-2817: the topic pane's place while its chunk loads (TopicPane and
     LiveTopicPane are lazy, layouts/default.vue). On a phone the shell is at
     level 3 the moment a topic opens, and level 3 shows the topic pane only:
     until the chunk came the screen stayed blank with no Back (CI: over
     350 ms on a deep link, a held chunk 1 s). This header holds the same
     MobileBack the pane's header does, and the pane replaces it, so there is
     never a second Back. Above 820 px it renders nothing. -->
<template>
  <aside v-if="stack.isMobile.value" class="topic topic-wait" aria-busy="true" data-testid="topic-pane-wait">
    <header><MobileBack /></header>
  </aside>
</template>

<script setup lang="ts">
import { useMobileStack } from '~/composables/useMobileStack'

const stack = useMobileStack()
</script>
