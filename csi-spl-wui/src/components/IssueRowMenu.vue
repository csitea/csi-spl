<!-- SPL-1226: the issue context menu. A right-click (or long-press on touch)
     opens it AT the pointer, clamped inside the viewport; Escape and a click
     outside close it, arrows move. At <= 820 px it is a bottom sheet over a
     dimmed page (the same shape as MessageMenu). The parent passes the items
     and handles `choose`; this component is generic (rows and the epics
     sidebar both use it). -->
<template>
  <UiPointMenu
    :open="open"
    :x="x"
    :y="y"
    :items="items"
    :label="t('issues_menu.label')"
    block="issue-menu"
    testid="issue-menu"
    data-test="issues-ctxmenu"
    wide
    :over-modal="overModal"
    follow-point
    @choose="emit('choose', $event)"
    @close="emit('close')"
  />
</template>

<script setup lang="ts">
import type { PointMenuItem } from '~/components/UiPointMenu.vue'

export type IssueMenuItem = PointMenuItem

defineProps<{
  open: boolean
  x: number
  y: number
  items: IssueMenuItem[]
  /** CLE-77806: lift above the issue modal (the actions menu opened from its
      header). The desktop popover sits at --z-overlay, below --z-modal. */
  overModal?: boolean
}>()
const emit = defineEmits<{
  close: []
  choose: [id: string]
}>()
const { t } = useI18n({ useScope: 'global' })
</script>
