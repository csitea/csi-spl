<!-- 022 §10: the right menu of a search result row. The same
     panel as the message menu (icon + name, arrows move, Escape and a click
     outside close it); a bottom sheet at <= 820 px. The items come from
     utils/search-results.mjs searchRowMenuItems. -->
<template>
  <UiPointMenu
    :open="open"
    :x="x"
    :y="y"
    :items="items"
    :label="t('search.menu.label')"
    block="msg-menu"
    testid="search-row-menu"
    @choose="emit('choose', $event)"
    @close="emit('close')"
    @escape="emit('escape')"
  />
</template>

<script setup lang="ts">
import type { PointMenuItem } from '~/components/UiPointMenu.vue'

defineProps<{
  open: boolean
  x: number
  y: number
  items: PointMenuItem[]
}>()
const emit = defineEmits<{
  close: []
  escape: []
  choose: [id: string]
}>()
const { t } = useI18n({ useScope: 'global' })
</script>
