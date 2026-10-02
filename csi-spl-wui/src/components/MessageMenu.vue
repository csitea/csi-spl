<!-- Right-click menu on a message. Same panel as a channel row: icon plus
     the action name, Escape and a click outside close it, arrows move.
     SPL-991: at <= 820 px it is a bottom sheet (long-press or the ⋯ button),
     over a dimmed page a tap on which closes it. -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="msg-menu"
      :class="{ 'touch-sheet': sheet }"
      data-testid="msg-menu"
      @keydown="onMenuKey"
      @contextmenu.prevent
    >
      <ul role="menu" class="msg-menu__items" :aria-label="t('feed.msg_menu.label')">
        <li v-for="item in items" :key="item.id" role="none">
          <button
            type="button"
            role="menuitem"
            tabindex="-1"
            class="msg-menu__item"
            :class="{ 'msg-menu__item--off': item.disabled }"
            :data-testid="'msg-menu-' + item.id"
            :data-disabled="item.disabled ? 'true' : undefined"
            :aria-disabled="item.disabled ? 'true' : undefined"
            :aria-describedby="item.disabled ? hintId + item.id : undefined"
            :title="item.disabled && item.hintKey ? t(item.hintKey) : undefined"
            @click.stop="choose(item.id, item.disabled)"
          >
            <UiIcon :name="item.icon" :size="16" />
            <span class="msg-menu__text">
              <span>{{ t(item.labelKey) }}</span>
              <!-- CLE-77891: a locked entry says why (the tooltip on a desktop;
                   a finger has no hover, so the sheet shows it under the name) -->
              <small
                v-if="item.disabled && item.hintKey"
                :id="hintId + item.id"
                class="msg-menu__why"
                :class="{ 'sr-only': !sheet }"
                data-testid="msg-menu-why"
              >{{ t(item.hintKey) }}</small>
            </span>
          </button>
        </li>
      </ul>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { msgMenuItems } from '~/utils/msg-menu.mjs'
import type { TopicMenuLocks } from '~/utils/topic-menu.mjs'
import { usePointMenu } from '~/composables/usePointMenu'

const props = defineProps<{
  open: boolean
  x: number
  y: number
  editable?: boolean
  mergePrev?: boolean
  mergeNext?: boolean
  /** a thread line: offer Open parent section */
  parent?: boolean
  /** SPL-983: a topic card the viewer may archive / delete (both) */
  topic?: boolean
  /** SPL-983 / CLE-77819: offer Archive (author, addressee, owner or admin) */
  topicArchive?: boolean
  /** SPL-983: offer Delete the topic (author, owner or admin) */
  topicDelete?: boolean
  /** SPL-991: the viewer may re-type this message (the sheet's Kind item) */
  kind?: boolean
  /** SPL-1024: a card the viewer may move to another channel */
  moveChannel?: boolean
  /** SPL-1024: a reply the viewer may move to another topic */
  moveTopic?: boolean
  /** 714c7028: a card the viewer may merge into another topic */
  mergeTopic?: boolean
  /** 8f588edd: a reply the viewer may promote into a new topic of its own */
  promoteTopic?: boolean
  /** CLE-77891: a topic card's entries the viewer may not use, shown disabled with the reason */
  locks?: Partial<TopicMenuLocks>
}>()

const emit = defineEmits<{
  close: []
  escape: []
  open: []
  parent: []
  edit: []
  copy: []
  'merge-prev': []
  'merge-next': []
  delete: []
  archive: []
  'delete-topic': []
  reply: []
  react: []
  'copy-text': []
  kind: []
  'move-channel': []
  'move-topic': []
  'merge-topic': []
  'promote-topic': []
}>()

const { t } = useI18n({ useScope: 'global' })
const { root, sheet, onMenuKey } = usePointMenu({
  open: () => props.open, x: () => props.x, y: () => props.y,
  close: () => emit('close'), escape: () => emit('escape'),
})
const items = computed(() => msgMenuItems({
  touch: sheet.value,
  kind: props.kind,
  editable: props.editable,
  mergePrev: props.mergePrev,
  mergeNext: props.mergeNext,
  parent: props.parent,
  topic: props.topic,
  topicArchive: props.topicArchive,
  topicDelete: props.topicDelete,
  moveChannel: props.moveChannel,
  moveTopic: props.moveTopic,
  mergeTopic: props.mergeTopic,
  promoteTopic: props.promoteTopic,
  locks: props.locks,
}))
const hintId = useId() + '-why-'

function choose(id: string, disabled?: boolean) {
  /* a disabled entry does nothing and keeps the menu open: its reason stays readable */
  if (disabled) return
  if (id === 'open') emit('open')
  else if (id === 'parent') emit('parent')
  else if (id === 'edit') emit('edit')
  else if (id === 'copy') emit('copy')
  else if (id === 'merge-prev') emit('merge-prev')
  else if (id === 'merge-next') emit('merge-next')
  else if (id === 'delete') emit('delete')
  else if (id === 'archive') emit('archive')
  else if (id === 'delete-topic') emit('delete-topic')
  else if (id === 'reply') emit('reply')
  else if (id === 'react') emit('react')
  else if (id === 'copy-text') emit('copy-text')
  else if (id === 'kind') emit('kind')
  else if (id === 'move-channel') emit('move-channel')
  else if (id === 'move-topic') emit('move-topic')
  else if (id === 'merge-topic') emit('merge-topic')
  else if (id === 'promote-topic') emit('promote-topic')
  emit('close')
}
</script>

<style scoped>
.msg-menu {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  max-height: calc(100dvh - 16px);
  overflow-y: auto;
  overscroll-behavior: contain;
  z-index: var(--z-overlay);
  min-width: 10rem;
  max-width: min(16rem, 70vw);
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px 0;
}
.msg-menu__items { list-style: none; margin: 0; padding: 0; }
.msg-menu__item {
  appearance: none;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 8px;
  width: 100%;
  text-align: start;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  padding: 8px 12px;
  cursor: pointer;
  min-height: 36px;
}
.msg-menu__item .ui-icon { flex: 0 0 auto; }
.msg-menu__text { display: flex; flex-direction: column; min-width: 0; }
.msg-menu__item--off { color: var(--color-muted); opacity: .7; cursor: not-allowed; }
.msg-menu__why { font-size: 0.75rem; line-height: 1.3; white-space: normal; }
.msg-menu__item:hover,
.msg-menu__item:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
</style>
