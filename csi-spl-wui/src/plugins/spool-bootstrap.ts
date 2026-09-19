import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'

export default defineNuxtPlugin(async () => {
  const channel = useChannelStore()
  const roster = useRosterStore()
  try {
    await Promise.all([channel.loadChannels(), roster.refresh()])
  } catch {
    /* mock still hydrates; live hub without WUI routes is expected in M1 */
  }
})
