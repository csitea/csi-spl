import { defineStore } from 'pinia'

export const useNotificationStore = defineStore('notification', () => {
  const permission = ref('unsupported')
  const chime = ref(true)
  const muted = ref(false)

  if (import.meta.client) {
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
  }

  async function requestPush() {
    if (typeof Notification === 'undefined') return
    permission.value = await Notification.requestPermission()
  }

  function ping(title: string, body: string) {
    if (muted.value) return
    if (chime.value && import.meta.client) {
      try {
        const ctx = new AudioContext()
        const osc = ctx.createOscillator()
        const gain = ctx.createGain()
        osc.frequency.value = 880
        gain.gain.value = 0.04
        osc.connect(gain)
        gain.connect(ctx.destination)
        osc.start()
        osc.stop(ctx.currentTime + 0.12)
      } catch {
        /* autoplay policies */
      }
    }
    if (permission.value === 'granted' && typeof Notification !== 'undefined') {
      try {
        new Notification(title, { body })
      } catch {
        /* ignore */
      }
    }
  }

  return { permission, chime, muted, requestPush, ping }
})
