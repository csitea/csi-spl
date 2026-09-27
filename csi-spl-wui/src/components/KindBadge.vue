<!-- SPL-952: a message's kind as an icon. The word stays as the hover title and
     the aria-label; a kind without a glyph shows as its word. Given a `msg`
     the viewer may re-type (the author, a biz_owner or an admin), the badge is
     a button that opens KindPicker, as the smile button opens EmojiPicker. -->
<template>
  <button
    v-if="settable"
    type="button"
    class="kind kind-btn"
    :class="['kind-' + shown, { 'kind--icon': icon }]"
    :data-kind="shown"
    data-testid="kind-badge-btn"
    :title="t('feed.kind_set.change', { kind: label })"
    :aria-label="t('feed.kind_set.change', { kind: label })"
    aria-haspopup="menu"
    :aria-expanded="open ? 'true' : 'false'"
    :disabled="busy"
    @click.stop="toggle"
    @keydown.enter.stop
    @keydown.space.stop
  >
    <UiIcon v-if="icon" :name="icon" :size="14" :stroke-width="2" />
    <template v-else>{{ label }}</template>
  </button>
  <span
    v-else
    class="kind"
    :class="['kind-' + shown, { 'kind--icon': icon }]"
    :data-kind="shown"
    :title="label"
    :role="icon ? 'img' : undefined"
    :aria-label="icon ? label : undefined"
  >
    <UiIcon v-if="icon" :name="icon" :size="14" :stroke-width="2" />
    <template v-else>{{ label }}</template>
  </span>
  <KindPicker
    v-if="settable"
    :open="open"
    :x="at.x"
    :y="at.y"
    :current="shown"
    @close="open = false"
    @choose="setKind"
  />
</template>

<script setup lang="ts">
import type { SpoolMessage } from '~/types/spool'
import type { UiIconName } from '~/utils/uiIcons'
import { canSetKind, kindIcon } from '~/utils/msg-kind.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { noteError } from '~/composables/errorJournal.mjs'

const props = defineProps<{ kind: string, msg?: SpoolMessage | null }>()
const { t, te } = useI18n({ useScope: 'global' })

/* the kind this badge shows: the row's, or the one just set while the hub's
   frame is on its way */
const pending = ref('')
watch(() => props.kind, () => { pending.value = '' })
const shown = computed(() => pending.value || props.kind)
const label = computed(() => (te('feed.kind.' + shown.value) ? t('feed.kind.' + shown.value) : shown.value))
const icon = computed(() => kindIcon(shown.value) as UiIconName | '')

const access = props.msg ? useAccessStore() : null
const edit = props.msg ? useMessageEdit() : null
const settable = computed(() => Boolean(props.msg && edit
  && canSetKind(props.msg, edit.viewerId.value, access?.me?.role ?? null)))

const open = ref(false)
const busy = ref(false)
const at = ref({ x: 0, y: 0 })

function toggle(ev: MouseEvent) {
  if (open.value) {
    open.value = false
    return
  }
  const el = ev.currentTarget
  if (!(el instanceof HTMLElement)) return
  const r = el.getBoundingClientRect()
  at.value = { x: r.left, y: r.bottom + 4 }
  open.value = true
}

async function setKind(kind: string) {
  const m = props.msg
  if (!m || !m.msg_id || kind === shown.value || busy.value) return
  busy.value = true
  pending.value = kind
  try {
    const row = await useSpoolApi().setMessageKind(String(m.msg_id), kind)
    edit?.applyEverywhere(row)
  } catch (err) {
    pending.value = ''
    noteError({ source: 'kind-set', message: t('feed.kind_set.failed'), code: (err as { token?: string })?.token, error: err })
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.kind-btn {
  cursor: pointer;
  font: inherit;
  font-size: 0.625rem;
  background: transparent;
}
.kind-btn.kind-blocker { background: var(--color-danger); }
.kind-btn:hover:not(:disabled) { filter: brightness(1.15); }
/* SPL-991 phone: the badge keeps its look; an invisible 44 px hit area
   around it takes the finger */
@media (max-width: 820px) {
  .kind-btn { position: relative; }
  .kind-btn::before {
    content: "";
    position: absolute;
    left: 50%;
    top: 50%;
    width: var(--tap);
    height: var(--tap);
    transform: translate(-50%, -50%);
  }
}
</style>
