<!-- t1 8fb802cd (owner: "If a topic is archived it should be clearly marked
     as archived"): the archive glyph and the word, wherever an archived topic
     still renders (the topic pane's header, a topic row). The date is the
     hover title; the word is never icon-only, so a phone shows it too. -->
<template>
  <span
    class="archived-badge"
    data-test="archived-badge"
    :title="when ? t('archive.archived_at', { when }) : undefined"
  >
    <UiIcon name="archive" :size="12" :stroke-width="2" />
    <span class="archived-badge__label">{{ t('archive.badge') }}</span>
  </span>
</template>

<script setup lang="ts">
import { isoDateTime } from '~/utils/date-iso.mjs'

const props = defineProps<{ at?: string | null }>()
const { t } = useI18n({ useScope: 'global' })
const when = computed(() => (props.at ? isoDateTime(props.at) : ''))
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
</style>
