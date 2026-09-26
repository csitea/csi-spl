<!-- SPL-952: a message's kind as an icon. The word stays as the hover title
     and the aria-label; a kind without a glyph shows as its word. -->
<template>
  <span
    class="kind"
    :class="['kind-' + kind, { 'kind--icon': icon }]"
    :data-kind="kind"
    :title="label"
    :role="icon ? 'img' : undefined"
    :aria-label="icon ? label : undefined"
  >
    <UiIcon v-if="icon" :name="icon" :size="14" :stroke-width="2" />
    <template v-else>{{ label }}</template>
  </span>
</template>

<script setup lang="ts">
import type { UiIconName } from '~/utils/uiIcons'
import { kindIcon } from '~/utils/msg-kind.mjs'

const props = defineProps<{ kind: string }>()
const { t, te } = useI18n({ useScope: 'global' })
const label = computed(() => (te('feed.kind.' + props.kind) ? t('feed.kind.' + props.kind) : props.kind))
const icon = computed(() => kindIcon(props.kind) as UiIconName | '')
</script>
