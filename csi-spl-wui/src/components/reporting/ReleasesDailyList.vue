<!-- Spec 143 2.2 T024 (SPL-2787): the Releases tab's days, newest first.
     A day header: the UTC date, its commit count, the count per kind and
     the newest deploy per env and component (prd first), or a neutral
     "Deploys: not recorded" when none is recorded (estate_deploys stays
     empty until spec 143 row 4 lands). Under it the day's commits, newest
     first: the commit time (HH:MM UTC, the git committer time: the hub
     records no push time), the short sha and the version link to /releases/<ref> (the
     release notes dialog), the area and kind chips, the subject, and a
     toggle that shows the Lay and Tech What/How/Why lines. SPL-4789: after
     the subject, the issues the commit cites and their discussions, as
     links into the workspace that owns them, or "unknown". SPL-4900 (owner
     HUM-10, t1 4d1e60b5, msg b164e955: "too much empty space"): above the phone breakpoint
     a day's commits are cards in a grid that fills the width, the subject
     on its own line; an opened commit spans its day's row. A phone keeps
     one row per commit. SPL-6397 (owner HUM-10, t1 70e18a3d, msgs 8684ee68
     and 9e3495df: "a single column list ... but a stylie one", "on the
     Desktop version"): the desktop grid is gone again; above the phone
     breakpoint the days are ONE centred column of cards, each commit a row
     aligned on a time column (time | subject over sha, version, area, kind
     | issue links and the notes toggle), with a hover state. The meta and
     links wrappers are display: contents on a phone, so its one wrapping
     line per commit is unchanged. B-7 (spec 143 releases-projects.md 7.1, SPL-5853):
     with showRepo (a project of more than one repo) each commit row and
     deploy chip also names its repo's short name. -->
<template>
  <ol class="rd-days" data-test="releases-days">
    <li v-for="g in groups" :key="g.day.date" class="rd-day" :data-date="g.day.date" data-test="releases-day">
      <header class="rd-head">
        <h3 class="rd-date" data-test="releases-day-date">{{ g.day.date }}</h3>
        <span class="rd-count muted" data-test="releases-day-count">{{ t('reporting.releases.day_commits', { n: g.day.commits_count }) }}</span>
        <span v-for="k in kindBreakdown(g.day.kinds)" :key="k.kind" class="rd-chip rd-chip--kind" data-test="releases-day-kind">{{ k.kind }}: {{ k.n }}</span>
        <template v-if="deployChips(g.day.deploys).length">
          <span
            v-for="c in deployChips(g.day.deploys)"
            :key="c.repo + c.env + c.component"
            class="rd-chip rd-chip--deploy"
            :class="['rd-chip--' + c.env, { 'rd-chip--failed': c.failed }]"
            data-test="releases-day-deploy"
          ><span v-if="showRepo && c.repo" class="rd-repo" data-test="releases-deploy-repo">{{ repoShort(c.repo) }}</span>{{ t('reporting.releases.deploy_chip', { env: c.env, component: c.component, version: c.version, time: c.time }) }}</span>
        </template>
        <span v-else class="rd-chip rd-chip--none" data-test="releases-day-no-deploys">{{ t('reporting.releases.deploys_none') }}</span>
      </header>
      <ul class="rd-rows">
        <li v-for="n in g.notes" :key="n.sha" class="rd-row" :class="{ 'rd-row--open': open.has(n.sha) }" :data-sha="n.sha" data-test="releases-commit">
          <div class="rd-line">
            <time
              v-if="utcTime(n.committed_at)"
              class="rd-time"
              :datetime="n.committed_at"
              :title="t('reporting.releases.commit_time_title', { time: utcTime(n.committed_at) })"
              data-test="releases-commit-time"
            >{{ t('reporting.releases.commit_time', { time: utcTime(n.committed_at) }) }}</time>
            <span class="rd-meta">
            <NuxtLink
              class="rd-sha"
              :to="localePath('/releases/' + n.sha)"
              :title="t('reporting.releases.open_commit', { sha: n.sha.slice(0, 7) })"
              data-test="releases-commit-sha"
            >{{ n.sha.slice(0, 7) }}</NuxtLink>
            <span v-if="showRepo && n.repo_slug" class="rd-chip rd-chip--repo" :title="n.repo_slug" data-test="releases-commit-repo">{{ repoShort(n.repo_slug) }}</span>
            <NuxtLink
              v-if="n.version"
              class="rd-chip rd-chip--version"
              :to="localePath('/releases/' + n.version)"
              :title="t('reporting.releases.open_version', { version: displayVersion(n.version) })"
              data-test="releases-commit-version"
            >{{ displayVersion(n.version) }}</NuxtLink>
            <span v-if="areaOf(n.area)" class="rd-chip" data-test="releases-commit-area">{{ areaOf(n.area) }}</span>
            <span v-if="n.kind" class="rd-chip rd-chip--kind" data-test="releases-commit-kind">{{ n.kind }}</span>
            </span>
            <span class="rd-subject" data-test="releases-commit-subject">{{ n.subject }}</span>
            <span class="rd-links">
            <ReleaseIssueLinks v-if="Array.isArray(n.issues)" :issues="n.issues" />
            <button
              v-if="hasTrailers(n)"
              type="button"
              class="rd-toggle"
              :aria-expanded="open.has(n.sha) ? 'true' : 'false'"
              data-test="releases-commit-toggle"
              @click="toggle(n.sha)"
            >{{ open.has(n.sha) ? t('reporting.releases.notes_hide') : t('reporting.releases.notes_show') }}</button>
            </span>
          </div>
          <div v-if="open.has(n.sha)" class="rd-notes" data-test="releases-commit-notes">
            <dl class="rd-trailers">
              <dt>{{ t('reporting.releases.lay_title') }}</dt>
              <dd>
                <p v-if="n.lay_what"><strong>{{ t('reporting.releases.what') }}</strong> {{ n.lay_what }}</p>
                <p v-if="n.lay_how"><strong>{{ t('reporting.releases.how') }}</strong> {{ n.lay_how }}</p>
                <p v-if="n.lay_why"><strong>{{ t('reporting.releases.why') }}</strong> {{ n.lay_why }}</p>
              </dd>
              <dt>{{ t('reporting.releases.tech_title') }}</dt>
              <dd>
                <p v-if="n.tech_what"><strong>{{ t('reporting.releases.what') }}</strong> {{ n.tech_what }}</p>
                <p v-if="n.tech_how"><strong>{{ t('reporting.releases.how') }}</strong> {{ n.tech_how }}</p>
                <p v-if="n.tech_why"><strong>{{ t('reporting.releases.why') }}</strong> {{ n.tech_why }}</p>
              </dd>
            </dl>
          </div>
        </li>
      </ul>
    </li>
  </ol>
</template>

<script setup lang="ts">
import ReleaseIssueLinks from '~/components/reporting/ReleaseIssueLinks.vue'
import { deployChips, displayVersion, hasTrailers, kindBreakdown, repoShort, utcTime, type ReleaseCommit, type ReleaseDay } from '~/utils/reporting-releases'

defineProps<{ groups: { day: ReleaseDay, notes: ReleaseCommit[] }[], showRepo?: boolean }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()

/* the commits whose notes are shown; a new Set each time so the template sees it */
const open = ref(new Set<string>())
function toggle(sha: string) {
  const next = new Set(open.value)
  if (next.has(sha)) next.delete(sha)
  else next.add(sha)
  open.value = next
}
/* a scope's first word, as the hub groups the areas ("wui, SPL-1" -> wui) */
const areaOf = (a: string) => String(a || '').split(',')[0].trim().toLowerCase().replace(/^csi-spl-/, '')
</script>

<style scoped>
.rd-days, .rd-rows { list-style: none; margin: 0; padding: 0; }
.rd-days { display: flex; flex-direction: column; gap: 14px; }
.rd-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 8px; padding: 6px 0; border-bottom: 1px solid var(--color-border); }
.rd-date { margin: 0; font-size: 0.9375rem; font-variant-numeric: tabular-nums; }
.rd-count { font-size: 0.8125rem; }
.rd-chip {
  display: inline-block; padding: 0 8px; border: 1px solid var(--color-border); border-radius: var(--radius-pill);
  font-size: 0.75rem; line-height: 1.5rem; white-space: nowrap; color: var(--color-fg); background: var(--color-bg-2);
}
.rd-chip--kind { font-family: var(--font-mono, ui-monospace, monospace); }
.rd-chip--prd { border-color: var(--color-success); }
.rd-chip--dev { border-color: var(--color-accent); }
.rd-chip--failed { border-color: var(--color-danger); color: var(--color-danger); }
.rd-chip--none { color: var(--color-muted); }
.rd-chip--version { text-decoration: none; }
.rd-chip--repo { font-family: var(--font-mono, ui-monospace, monospace); color: var(--color-muted); }
.rd-repo { font-family: var(--font-mono, ui-monospace, monospace); margin-right: 4px; }
.rd-row { padding: 6px 0; border-bottom: 1px solid var(--color-border); }
/* SPL-6611 (owner HUM-10, t1 25970d1c, msg 35543c11: "as any other one
   alternating colors"): every second commit of a day takes the house
   --color-row-alt veil (SPL-2120); the desktop hover and open fills below
   come later and paint over it. */
.rd-row:where(:nth-child(even of .rd-row)) { background: var(--color-row-alt); }
.rd-line { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 8px; min-width: 0; }
.rd-time { font-family: var(--font-mono, ui-monospace, monospace); font-size: 0.8125rem; font-variant-numeric: tabular-nums; color: var(--color-muted); white-space: nowrap; }
.rd-sha { font-family: var(--font-mono, ui-monospace, monospace); font-size: 0.8125rem; }
.rd-subject { flex: 1 1 260px; min-width: 0; overflow-wrap: anywhere; }
.rd-toggle { border: 0; background: none; color: var(--color-accent); font: inherit; font-size: 0.8125rem; cursor: pointer; padding: 0 2px; }
.rd-notes { margin: 6px 0 0; padding: 6px 10px; border-left: 3px solid var(--color-border-strong); background: var(--color-bg-2); }
.rd-trailers { margin: 0; }
.rd-trailers dt { font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); margin-top: 4px; }
.rd-trailers dd { margin: 0; }
.rd-trailers p { margin: 2px 0; overflow-wrap: anywhere; }
/* a phone: the wrappers vanish, so the line wraps as one flex row (as before SPL-6397) */
.rd-meta, .rd-links { display: contents; }
/* SPL-6397: the desktop is one centred column of styled day cards (a phone keeps its rows) */
@media (min-width: 821px) {
  .rd-days { gap: 20px; width: 100%; max-width: 72rem; margin-inline: auto; }
  .rd-day { border: 1px solid var(--color-border); border-radius: var(--radius-md, 12px); background: var(--color-surface); overflow: hidden; }
  .rd-head { gap: 6px 10px; padding: 10px 16px; border-bottom: 1px solid var(--color-border); border-left: 4px solid var(--color-accent); background: var(--color-bg-2); }
  .rd-date { font-size: 1rem; font-weight: 700; color: var(--color-heading, var(--color-fg)); margin-right: 4px; }
  .rd-row { padding: 10px 16px; border-bottom: 1px solid var(--color-border); transition: background-color 0.12s ease; }
  .rd-row:last-child { border-bottom: 0; }
  .rd-row:hover, .rd-row:focus-within, .rd-row--open { background: var(--color-surface-hover); }
  .rd-line {
    display: grid; grid-template-columns: 4.5rem minmax(0, 1fr) auto; grid-template-areas: "time subject subject" "time meta links";
    align-items: baseline; gap: 6px 14px;
  }
  .rd-time { grid-area: time; font-size: 0.875rem; color: var(--color-muted); }
  .rd-subject { grid-area: subject; flex: none; font-size: 0.9375rem; font-weight: 600; line-height: 1.35; }
  .rd-meta, .rd-links { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 6px; min-width: 0; }
  .rd-meta { grid-area: meta; }
  .rd-links { grid-area: links; justify-content: flex-end; }
  .rd-chip--version { border-color: var(--color-accent); color: var(--color-accent); font-weight: 600; }
  .rd-chip--version:hover { background: var(--color-accent); color: var(--color-on-accent, var(--color-bg)); }
  .rd-toggle { border: 1px solid var(--color-border); border-radius: var(--radius-pill); padding: 0 10px; line-height: 1.5rem; }
  .rd-toggle:hover { border-color: var(--color-accent); }
  .rd-notes { margin: 10px 0 0 calc(4.5rem + 14px); border-radius: var(--radius-sm, 8px); }
}
</style>
