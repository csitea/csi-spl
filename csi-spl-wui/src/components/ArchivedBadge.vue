<!-- t1 8fb802cd (owner: "If a topic is archived it should be clearly marked
     as archived"): the archive glyph and the word, wherever an archived topic
     still renders (the topic pane's header, a topic row). The full stamp is
     the hover title; the word is never icon-only, so a phone shows it too.
     t1 64ce816a: the open topic header also prints the archive day
     (show-when). A row stays the word plus the hover title. -->
<template>
  <span
    class="archived-badge"
    :class="{ 'archived-badge--when': showWhen && date }"
    data-test="archived-badge"
    :title="when ? t('archive.archived_at', { when }) : undefined"
  >
    <UiIcon name="archive" :size="12" :stroke-width="2" />
    <span class="archived-badge__label">{{ t('archive.badge') }}</span>
    <span v-if="showWhen && date" class="archived-badge__when" dir="ltr">{{ date }}</span>
  </span>
</template>

<script setup lang="ts">
import { isoDate, isoDateTime } from '~/utils/date-iso.mjs'

const props = defineProps<{ at?: string | null, showWhen?: boolean }>()
const { t } = useI18n({ useScope: 'global' })
const when = computed(() => (props.at ? isoDateTime(props.at) : ''))
const date = computed(() => (props.showWhen && props.at ? isoDate(props.at) : ''))
</script>

<style scoped>
.archived-badge {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  flex: none;
  padding: 1px 6px;
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-pill);
  color: var(--color-warn);
  font-size: 0.625rem;
  font-weight: 600;
  letter-spacing: 0.06em;
  line-height: 1.4;
  text-transform: uppercase;
  white-space: nowrap;
  vertical-align: middle;
}
/* The day sits under the word, so the badge stays about as wide as the
   word alone. The title beside it keeps its room in the 380px pane and
   on a phone. The header itself stays one row (the pane CSS). */
.archived-badge--when {
  display: inline-grid;
  grid-template-columns: auto auto;
  column-gap: 3px;
  row-gap: 0;
  align-items: center;
  line-height: 1.2;
}
.archived-badge__when {
  grid-column: 1 / -1;
  letter-spacing: 0;
  text-transform: none;
}
</style>
