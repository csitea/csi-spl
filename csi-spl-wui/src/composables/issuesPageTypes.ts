import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useLive } from '~/composables/useLive'

/* The shapes pages/issues.vue hands its composables (r13-06: the page's
   script was split into useIssueOpen, useIssueCells, useIssuePicker,
   useIssueActions, useIssueSwipe, useIssueBulk, useIssueComments and
   useIssueKeys; each takes the refs and calls it reads, never the page). */
export type IssuesApi = ReturnType<typeof useSpoolApi>
export type IssuesLive = ReturnType<typeof useLive>
/* the open picker: which list, on which row (bulk: every checked row) */
export type IssuePickerMenu = { kind: string, key: string, bulk?: boolean }
export type IssueSave = (key: string, body: Record<string, unknown>) => Promise<void>
