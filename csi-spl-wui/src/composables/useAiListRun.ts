/*
 * t1 b6c742f0 (HUM-10 14dc0232: "add those same actions to every msg card in
 * every view"): run an AI action picked on a message ENTRY of a list - a Flow
 * entry, a search hit, or (643c30a8) a topic row. Such an entry is a short
 * copy: no full body (a search hit has a snippet, a Flow entry a cut text, a
 * topic row its title) and not the page the
 * post belongs to (a reply to a direct message goes to the page's peer). So
 * the pick first opens the message in its original place, as a click does,
 * then runs the action on the full message there - the post lands in that
 * topic, in front of the member. The runner is loaded on the pick.
 */
import { useOpenMessage } from '~/composables/useOpenMessage'
import { useChannelStore } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { withSessionRetry } from '~/utils/live-follow.mjs'

/** How long the opened place may take to hold the message. */
const FIND_MS = 5000

export function useAiListRun() {
  const { openMessage } = useOpenMessage()
  const channel = useChannelStore()
  const deps = { api: useSpoolApi(), router: useRouter(), localePath: useLocalePath(), send: channel.send }

  async function held(msgId: string) {
    const t0 = Date.now()
    for (;;) {
      const m = channel.messages.find((r) => String(r.msg_id || '') === msgId)
      if (m || Date.now() - t0 > FIND_MS) return m || null
      await new Promise((r) => setTimeout(r, 100))
    }
  }

  /**
   * Opens `row` where it lives and runs action `id` on it.
   * '' when done (or the open failed: the shell shows that notice), else the
   * i18n key of the failure to show.
   */
  async function run(id: string, entry: object): Promise<string> {
    const row = entry as { msg_id?: string | null, task_id?: string | null, parent_task_id?: string | null, channel?: string | null }
    const [{ aiAction, aiPostTarget }, { runAiAction }] = await Promise.all([import('~/utils/msg-ai-actions.mjs'), import('~/utils/msg-ai-run')])
    const action = aiAction(id)
    if (!action) return ''
    const out = await openMessage(row)
    if (!out.ok) return ''
    const msg = await held(String(row.msg_id || ''))
    /* a reply to a direct message needs the page on its DM: not found there, it is not sent */
    if (!msg && action.mode === 'post' && !aiPostTarget(row).channel) return 'feed.msg_menu.ai.failed'
    return runAiAction(id, msg || row, deps)
  }

  /**
   * HUM-10 643c30a8: a topic row's pick (the sidebar Topics tab, the home
   * topic list). The row holds the topic's id and title, not its text: read
   * the topic's opening message, then open it and run on it as above.
   */
  async function runTopic(id: string, taskId: string): Promise<string> {
    let root: object | undefined
    try {
      root = ((await withSessionRetry(deps.api, () => deps.api.getTopic(taskId, { limit: 1 }))).messages || [])[0]
    } catch {
      root = undefined
    }
    if (!root) return 'feed.msg_menu.ai.failed'
    return run(id, root)
  }

  return { run, runTopic }
}
