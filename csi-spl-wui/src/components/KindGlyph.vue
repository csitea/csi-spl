<!-- SPL-952 / CLE-77804: a message kind as its icon (or its word when the kind
     has no glyph), non-interactive. KindPicker renders one per option. It is a
     leaf on purpose: KindPicker used to render the whole KindBadge for each
     option, and KindBadge renders KindPicker for its popup, so the two imported
     each other. That circular import crashed the minified, code-split build
     with `ReferenceError: Cannot access 'X' before initialization` (a temporal
     dead zone, surfaced to the error journal as source "vue"). Pulling the
     shared glyph out breaks the cycle: KindBadge -> KindPicker -> KindGlyph. -->
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
