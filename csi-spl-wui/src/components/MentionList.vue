<!-- SPL-985 (spec 042 §2): the @ list of useMentionPicker, the same in every
     field. The host puts it next to its field inside a positioned box.
     `placement`: 'below' (default) and 'above' float over the page; 'inline'
     takes room in the flow (the omnibox, which moves it with its own rules).
     Rows swallow their mousedown, so the field keeps the focus and its blur
     (which closes the list, or saves an issue description) does not fire. -->
<template>
  <ul
    v-if="picker.open"
    :id="picker.listId"
    :ref="setList"
    class="mention-list"
    :class="'mention-list--' + (placement || 'below')"
    role="listbox"
    data-test="mention-list"
    :aria-label="t('composer.mention_suggestions')"
  >
    <li v-for="(p, i) in picker.candidates" :key="p.label || p.id">
      <button
        :id="picker.listId + '-' + i"
        type="button"
        role="option"
        class="mention-item"
        data-test="mention-option"
        :data-id="p.id"
        :class="{ active: i === picker.activeIdx }"
        :aria-selected="i === picker.activeIdx"
        tabindex="-1"
        @mousedown.prevent="picker.pick(p)"
      >
        <SpoolAvatar :id="p.id" :box="p.box" :size="20" />
        <span class="dot" :class="{ on: p.online }" />
        <HumanName class="mention-label" :id="p.id" :box="p.box" />
        <span v-if="p.owner" class="muted" data-testid="mention-owner">{{ t('composer.biz_owner') }}</span>
      </button>
    </li>
  </ul>
</template>

<script setup lang="ts">
import HumanName from '~/components/HumanName.vue'
import type { MentionPicker } from '~/composables/useMentionPicker'

const props = defineProps<{ picker: MentionPicker, placement?: 'below' | 'above' | 'inline' }>()
const { t } = useI18n({ useScope: 'global' })

function setList(el: unknown) {
  props.picker.listEl = el instanceof HTMLUListElement ? el : null
}
</script>

<style scoped>
.mention-list {
  list-style: none;
  margin: 0 0 8px;
  padding: 4px 0;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  max-height: 180px;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  max-width: 100%;
  min-width: 0;
}
.mention-list--below,
.mention-list--above {
  position: absolute;
  inset-inline: 0;
  z-index: 60;
  margin: 4px 0;
  box-shadow: 0 8px 24px rgb(0 0 0 / .25);
}
.mention-list--below { top: 100%; }
.mention-list--above { bottom: 100%; }
.mention-list li {
  margin: 0;
  padding: 0;
  max-width: 100%;
  min-width: 0;
}
.mention-item {
  border-radius: var(--radius-sm);
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  min-height: var(--tap);
  padding: 6px 10px;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  cursor: pointer;
  text-align: left;
  font-size: 0.8125rem;
  box-sizing: border-box;
}
.mention-item:hover {
  background: var(--color-surface-hover);
}
/* CLE-3427: the highlighted suggestion is a SELECTED list row - darker fill,
   one 3px marker bar in the shared ring colour. */
.mention-item.active {
  background: var(--color-selected);
  box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring);
}
.mention-label {
  min-width: 0;
  overflow-wrap: anywhere;
}
</style>
