import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { AWAIT_ANIM_IDS, STILL_AWAIT_ANIM, awaitAnimSet, awaitSetAt, createRotateClock, dropLegacyAwaitAnim, planAwaitMigration } from '~/utils/await-reply.mjs'

/* SPL-2113: the old browser pick moves to the account once per tab */
let migrating = false

/**
 * SPL-2113: mirror the ticked set into the session claim (optimistic; the
 * caller reverts it on a failed save). Here, not a session-store setter like
 * the others, so its bytes stay out of the entry chunk (it sits at its
 * ceiling, ci_initial_gzip_kb 155).
 */
export function mirrorAwaitAnims(session: ReturnType<typeof useSessionStore>, ids: readonly string[] | null) {
  if (session.claims) session.claims = { ...session.claims, await_anims: ids ? [...ids] : null }
}

/**
 * SPL-2113: the person's ticked "thinking" animations (Settings ->
 * Appearance), kept in the account: the hub's per-workspace `await_anims`
 * session claim (utils/await-reply.mjs). Only the lazy AwaitReply mark and
 * the setting use it, so it stays off the first screen. One shared state: a
 * tick in Settings redraws every open mark.
 *
 * The first time a signed-in person with no pick in the account is seen,
 * the SPL-2027/2043 pick this browser kept is written to the account and its
 * old key removed (kept when the save fails, for the next visit).
 */
export function useAwaitAnim() {
  const session = useSessionStore()
  const auth = useAuthClient()
  const set = computed(() => awaitAnimSet(session.claims?.await_anims))

  function migrate() {
    if (migrating || !import.meta.client || session.state !== 'in') return
    const plan = planAwaitMigration(session.claims)
    if (!plan) return
    migrating = true
    if (!plan.set) {
      dropLegacyAwaitAnim(plan.key)
      return
    }
    mirrorAwaitAnims(session, plan.set)
    void auth.saveAwaitAnims(plan.set).then((out) => {
      if (out.ok) dropLegacyAwaitAnim(plan.key)
      else mirrorAwaitAnims(session, null)
    })
  }
  onMounted(migrate)
  watch(() => session.state, migrate)

  return { set, ids: AWAIT_ANIM_IDS as readonly string[] }
}

/* SPL-2043: one clock for every rotating mark in this tab */
let clock: ReturnType<typeof createRotateClock> | null = null
const rotateStep = ref(0)

/**
 * SPL-2043/2113: the drawing a mark shows now: the ticked `set` in turn
 * while `active` (spinning, motion welcome, two or more ticked) holds; the
 * still hourglass otherwise. Every caller shares the one clock; it stops
 * when the last active mark goes (unmount included).
 */
export function useAwaitRotate(active: Ref<boolean>, set: Ref<readonly string[]>) {
  let stop: (() => void) | null = null
  const off = () => { stop?.(); stop = null }
  const on = () => {
    if (stop || !import.meta.client) return
    clock ??= createRotateClock()
    stop = clock.subscribe((step: number) => { rotateStep.value = step })
  }
  watch(active, (a) => (a ? on() : off()), { immediate: true })
  onScopeDispose(off)
  return computed(() => (active.value ? awaitSetAt(set.value, rotateStep.value) : STILL_AWAIT_ANIM))
}
