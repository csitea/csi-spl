/*
 * t1 b6c742f0 (HUM-10): run one AI action picked in a person's message menu.
 * Only MessageMenu.vue imports this (and utils/msg-ai-actions.mjs), so both
 * ride in the menu's own lazy chunk: no extra request when the menu opens,
 * nothing in the initial JS. tenant-switcher and live-follow are imported
 * statically: they are in the entry already, and a dynamic import() of an
 * entry module makes the entry keep every export of it (+0.4 KB gzip).
 *
 * Debate, Spec, Implement, Analyse and Find risks post the instruction,
 * quoting the message, as the member's reply in the same topic - the
 * dispatcher desk reads every post. Turn into an issue creates an issue from
 * it and opens it on /issues; Add to calendar creates a calendar event from
 * it (POST /v1/calendar/events) and opens its week on /calendar.
 */
import type { Router } from 'vue-router'
import {
  aiAction, aiActionPost, aiCalendarRoute, aiEventBody, aiIssueBody, aiIssueRoute, aiPostTarget, createCalendarEvent, offersAiActions,
} from '~/utils/msg-ai-actions.mjs'
import { fixedTenantOption } from '~/utils/tenant-switcher.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { messageLink } from '~/utils/msg-menu.mjs'
import { useSessionStore } from '~/stores/session'
import type { useSpoolApi } from '~/composables/useSpoolApi'

export interface AiRunDeps {
  api: ReturnType<typeof useSpoolApi>
  router: Router
  localePath: (path: string) => string
  /** the channel store's send (stores/channel.ts) */
  send: (text: string, parentTaskId?: string, files?: unknown[], channelId?: string, isParent?: number) => Promise<unknown>
}

/** Runs the action; '' when done, else the i18n key of the failure to show. */
export async function runAiAction(id: string, msg: unknown, deps: AiRunDeps): Promise<string> {
  const action = aiAction(id)
  if (!action || !offersAiActions(msg)) return ''
  try {
    const path = messageLink(msg, deps.localePath)
    const where = {
      workspace: fixedTenantOption(useSessionStore().claims).label,
      link: path && typeof window !== 'undefined' ? new URL(path, window.location.origin).href : '',
    }
    if (action.mode === 'post') {
      const to = aiPostTarget(msg)
      await deps.send(aiActionPost(msg, id, where), to.taskId, [], to.channel || undefined, 0)
      return ''
    }
    const api = deps.api
    let to
    if (action.mode === 'calendar') {
      to = aiCalendarRoute(await createCalendarEvent(api, aiEventBody(msg, where)))
    } else {
      const data = await withSessionRetry(api, () => api.createIssue(aiIssueBody(msg, where)))
      const key = String(data?.issue?.key || '')
      if (!key) throw new Error('no issue key')
      to = aiIssueRoute(key)
    }
    await deps.router.push({ path: deps.localePath(to.path), query: to.query })
    return ''
  } catch {
    return 'feed.msg_menu.ai.failed'
  }
}
