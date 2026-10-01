<!-- CLE-77886 (HUM-24, csitea 7930dfbf: "there is no exit from the Issues
     window"): a section page's way out on a desktop - the WUI's one close X
     (UiCloseButton, at the side Settings -> Behaviour picks; place it at
     BOTH ends of the header like every other closable header). It goes back
     to the conversation the reader left (useSectionExit), the lobby when
     there was none. Not on a phone: there the section strip is the way. -->
<template>
  <UiCloseButton
    v-if="!stack.isMobile.value"
    :side="side"
    class="icon-btn section-close"
    data-test="section-close"
    @click="exit"
  />
</template>

<script setup lang="ts">
import { useMobileStack } from '~/composables/useMobileStack'
import { useSectionExit } from '~/composables/useSectionExit'

defineProps<{ side: 'start' | 'end' }>()
const stack = useMobileStack()
const { target } = useSectionExit()
const localePath = useLocalePath()

function exit() {
  const to = target()
  void navigateTo(to.startsWith('/lobby') ? localePath(to) : to)
}
</script>

<style scoped>
.section-close[data-close-side='end'] { margin-inline-start: auto; }
</style>
