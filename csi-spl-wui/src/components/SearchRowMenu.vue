<!-- 022 §10: the right menu of a search result row. The same
     panel as the message menu (icon + name, arrows move, Escape and a click
     outside close it); a bottom sheet at <= 820 px. The items come from
     utils/search-results.mjs searchRowMenuItems.
     t1 b6c742f0: a Flow entry's menu too (`label`, `testid`), and on a
     person's message (`aiMsg`) both end with the AI actions group, the same
     rule as the card's MessageMenu (composables/useAiMenuGroup.ts). The
     parent runs an AI pick (composables/useAiListRun.ts). -->
<template>
  <UiPointMenu
    :open="open"
    :x="x"
    :y="y"
    :items="shown"
    :label="label || t('search.menu.label')"
    block="msg-menu"
    :testid="testid || 'search-row-menu'"
    @choose="choose"
    @close="onClose"
    @escape="emit('escape')"
  />
</template>

<script setup lang="ts">
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import { useAiMenuGroup } from '~/composables/useAiMenuGroup'

const props = defineProps<{
  open: boolean
  x: number
  y: number
  items: PointMenuItem[]
  /** t1 b6c742f0: the message, for the AI actions group (a person's message only) */
  aiMsg?: unknown
  label?: string
  testid?: string
}>()
const emit = defineEmits<{
  close: []
  escape: []
  choose: [id: string]
}>()
const { t } = useI18n({ useScope: 'global' })
const ai = useAiMenuGroup(() => props.aiMsg)
const shown = computed(() => ai.items(props.items) as PointMenuItem[])
function choose(id: string) {
  if (!ai.more(id)) emit('choose', id)
}
function onClose() {
  if (!ai.keep()) emit('close')
}
</script>
