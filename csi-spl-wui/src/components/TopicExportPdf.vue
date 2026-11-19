<!-- SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020):
     "Export topic to PDF", the topic header's button (row 2, beside the
     replies' height control). It prints the topic's title and every card
     the pane shows, in the order shown, through utils/msg-print-run.ts,
     which loads on the click. Lazy in both topic panes, so the first
     screen does not carry it. -->
<template>
  <button
    ref="btn"
    type="button"
    class="icon-btn topic-export-pdf"
    data-test="topic-export-pdf"
    :aria-label="t('topic.export_pdf')"
    :title="t('topic.export_pdf')"
    :disabled="busy"
    @click.stop="onExport"
  >
    <UiIcon name="file-text" :size="14" />
  </button>
</template>

<script setup lang="ts">
import { getCurrentInstance } from 'vue'
import { rowsInShownOrder } from '~/utils/msg-print'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { SpoolMessage } from '~/types/spool'

/* rows: every message the pane holds (its opener rows too); title: the topic's */
const props = defineProps<{ title: string, rows: () => (SpoolMessage | null | undefined)[] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const appContext = getCurrentInstance()?.appContext ?? null
const btn = ref<HTMLButtonElement | null>(null)
const busy = ref(false)

/* the cards this pane shows, top to bottom (a search or the clip mode does not
   matter: the print renders each one whole from its message) */
function shownIds(): string[] {
  const root = btn.value?.closest('aside')?.querySelector('[data-test=topic-root]')
  return root ? [...root.querySelectorAll('article.msg[data-msg-id]')].map((e) => e.getAttribute('data-msg-id') || '') : []
}

async function onExport() {
  if (busy.value) return
  busy.value = true
  try {
    const rows = rowsInShownOrder<SpoolMessage>(shownIds(), props.rows().filter(Boolean))
    const { printMessages } = await import('~/utils/msg-print-run')
    await printMessages({ rows, title: props.title, appContext, api })
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
/* the row's other controls are 18 px tall on desktop: the button does not grow the row */
.topic-export-pdf { flex-shrink: 0; min-width: 20px; min-height: 18px; width: 20px; height: 18px; }
@media (max-width: 820px) {
  .topic-export-pdf { min-width: 32px; min-height: 32px; width: 32px; height: 32px; }
}
</style>
