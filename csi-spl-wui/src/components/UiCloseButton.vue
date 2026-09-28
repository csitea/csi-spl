<!-- SPL-1133 (owner, prd t1 topic 9e0379a6): the WUI's ONE close X.

     "a User Setting to put the X's for closing the modal dialogs etc. either
     Windows style, i.e. top right, or Mac style, i.e. top left" - and "use
     the Mac style as the default". The choice is the close_buttons session
     claim (Settings -> Behaviour, hub humans.close_buttons, rdb 0077); app.vue
     mirrors it on <html data-close-buttons>.

     Every header that has a close X places this component at BOTH ends,
     `side="start"` before the title and `side="end"` after the tools, and
     exactly one of the two renders (closeButtonShown). So the X is in the
     DOM where it is drawn, and Tab reaches it first (Mac) or last (Windows),
     never out of order the way a CSS `order` would leave it. Attributes
     (class, data-test, @click) fall through to the <button>, so each
     header keeps its own selectors and styles. -->
<template>
  <button
    v-if="shown"
    type="button"
    class="ui-close"
    :data-close-side="side"
    :title="label || t('common.close')"
    :aria-label="label || t('common.close')"
  >
    <UiIcon name="x" :size="size" />
  </button>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { closeButtonShown } from '~/utils/view-prefs.mjs'

const props = withDefaults(defineProps<{
  /** 'start' = top left (Mac style), 'end' = top right (Windows style). */
  side: 'start' | 'end'
  size?: number
  label?: string
}>(), { size: 18, label: '' })

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const shown = computed(() => closeButtonShown(props.side, session.claims?.close_buttons))
</script>
