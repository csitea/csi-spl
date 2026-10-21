<!-- SPL-2027 (owner HUM-10, t1 72898ea2 msgs c4aae6fc, 1689b768): Settings ->
     Appearance -> "Thinking animation", the person's pick of the mark on a
     post that waits for an agent (components/AwaitReply.vue). Each choice
     shows its own running sample.
     SPL-2113 (owner HUM-10, t1 3aa9fac2 msgs d45ec26e, c33a028e, 1ea9f107):
     a vertical list of checkboxes, one per drawing (17); the ticked ones take
     turns, ~3 s each; at least one stays ticked (the last one cannot be
     unticked). Kept in the account (PUT /auth/preferences await_anims, per
     workspace), optimistic like Count my reading time: the claim changes as
     the box is clicked and changes back, with a status line, when the hub
     refuses. The samples load with the list (Settings is on demand).
     SPL-2795 (panel plan row 08, epic SPL-2403): ticking a drawing pops an
     accent ring round its sample once (playTapAnim, transform and opacity
     only, the ring is absolute so nothing moves); unticking plays nothing,
     reduced motion plays nothing, and the ring ends unseen. -->
<template>
  <div class="await-anim-setting" data-test="await-anim-setting">
    <span id="await-anim-label" class="await-anim-setting__label">{{ t('settings.await_anim.label') }}</span>
    <p id="await-anim-hint" class="muted await-anim-setting__hint">{{ t('settings.await_anim.hint') }}</p>
    <ul class="await-anim-setting__list" role="group" aria-labelledby="await-anim-label" aria-describedby="await-anim-hint">
      <li v-for="id in ids" :key="id">
        <label class="await-anim-setting__opt" :class="{ 'await-anim-setting__opt--on': set.includes(id) }">
          <input
            type="checkbox"
            :value="id"
            :checked="set.includes(id)"
            :disabled="saving || !signedIn || (set.length === 1 && set.includes(id))"
            :data-test="`await-anim-${id}`"
            @change="toggle(id, ($event.target as HTMLInputElement).checked, $event)"
          />
          <span class="await-anim-setting__preview">
            <LazyAwaitReply state="spin" :anim="id" preview />
            <span class="await-anim-setting__ring" aria-hidden="true" data-test="await-anim-ring" />
          </span>
          <span>{{ t('settings.await_anim.' + id) }}</span>
        </label>
      </li>
    </ul>
    <p v-if="status" class="await-anim-setting__status" role="status" aria-live="polite" data-test="await-anim-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSettingSave } from '~/composables/useSettingSave'
import { mirrorAwaitAnims, useAwaitAnim } from '~/composables/useAwaitAnim'
import { toggleAwaitAnim } from '~/utils/await-reply.mjs'
import { playTapAnim } from '~/composables/useTapAnim'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const { set, ids } = useAwaitAnim()
const { saving, status, run } = useSettingSave()
const signedIn = computed(() => session.state === 'in')

/* the ring round the sample next to a ticked box pops once; an untick plays nothing */
function popRing(ev: Event) {
  const ring = (ev.target as Element | null)?.closest('label')?.querySelector('.await-anim-setting__ring')
  if (ring instanceof HTMLElement) playTapAnim(ring, 'pop')
}

/* tick or untick one drawing: the claim at once, the save after, back on a refusal */
function toggle(id: string, on: boolean, ev: Event) {
  const next = toggleAwaitAnim(set.value, id, on)
  if (next === set.value) return
  if (on) popRing(ev)
  const prev = session.claims?.await_anims ?? null
  return run(async () => {
    mirrorAwaitAnims(session, next)
    const out = await auth.saveAwaitAnims(next)
    if (!out.ok) mirrorAwaitAnims(session, prev)
    return { ok: out.ok, out }
  })
}
</script>

<style scoped>
.await-anim-setting {
  display: grid;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
}
.await-anim-setting__label { font-weight: 600; }
.await-anim-setting__hint,
.await-anim-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.await-anim-setting__status { color: var(--color-error); }
.await-anim-setting__list {
  display: flex;
  flex-direction: column;
  margin: 0;
  padding: 0;
  list-style: none;
}
.await-anim-setting__opt {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: var(--tap, 44px);
  cursor: pointer;
}
.await-anim-setting__opt--on { color: var(--color-accent); }
/* the ring sits over the sample (absolute: 0 px layout shift) and is unseen
   unless it pops; its own keyframes add the fade to tap-pop's scale, and the
   name keeps the tap- prefix, so useTapAnim takes the classes off at the end */
.await-anim-setting__preview {
  position: relative;
  display: inline-flex;
}
.await-anim-setting__ring {
  position: absolute;
  inset-block: -4px;
  inset-inline: 0 -4px; /* the sample sits 4 px in (its margin): the ring centres on it */
  border: 2px solid var(--color-accent);
  border-radius: 50%;
  opacity: 0;
  pointer-events: none;
}
.await-anim-setting__ring.tap-anim--pop { animation-name: tap-await-ring; }
@keyframes tap-await-ring {
  0% { opacity: 0; transform: scale(.85); }
  60% { opacity: 1; transform: scale(1.18); }
  100% { opacity: 0; transform: none; }
}
</style>
