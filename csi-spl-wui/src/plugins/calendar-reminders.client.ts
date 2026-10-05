// Spec 089 T006 (owner D4): calendar reminders are plain in-app pop-ups,
// driven by this tab's own timer (utils/calendar-reminder-timer.ts). The
// shell holds only this switch: once the app is ready and the session is in,
// it loads the timer's chunk and starts it; a sign-out stops it. No agent,
// no AI, no spool message, no notification call on the way.
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { ReminderTimer } from '~/utils/calendar-reminder-timer'

export default defineNuxtPlugin((nuxtApp) => {
  const api = useSpoolApi()
  let timer: Promise<ReminderTimer> | null = null
  const load = () => (timer ||= import('~/utils/calendar-reminder-timer').then((m) => m.createReminderTimer(nuxtApp.vueApp, api)))
  onNuxtReady(() => {
    /* the mock tenant has no sign-in; a real one waits for the session */
    if (api.mock) { void load().then((t) => t.start()); return }
    const session = useSessionStore()
    watch(() => session.state, (state) => {
      if (String(state) === 'in') void load().then((t) => t.start())
      else if (String(state) === 'out' && timer) void timer.then((t) => t.stop())
    }, { immediate: true })
  })
})
