// SPL-4789: the issue and discussion links of a release note.
declare module '~/utils/release-issue-links.mjs' {
  export type ReleaseIssueLinkCtx = { pageTenant?: string, siteUrl?: string, apexTenant?: string, pathFor?: (p: string) => string }
  export type ReleaseIssueLink = { key: string, tenant: string, found: boolean, href: string, external: boolean }
  export type ReleaseDiscussionLink = { id: string, key: string, tenant: string, title: string, canOpen: boolean, membersOnly: boolean, href: string, external: boolean }
  export function releaseIssueLinks(issues: unknown, ctx?: ReleaseIssueLinkCtx): { unknown: boolean, issues: ReleaseIssueLink[], discussions: ReleaseDiscussionLink[] }
}
