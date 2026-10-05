<!-- "Issues: default sort" (Settings → Behaviour, SPL-1181): the column and
     direction the Issues list opens in. The hub keeps it PER TENANT
     (tenant_memberships.settings, rdb 0078, PUT /api/v1/auth/preferences) and
     answers it as the issues_sort session claim, which the Issues page reads on
     load; a column-header click still re-sorts the current view (SPL-972/1027).
     No stored value = the product default, priority ascending (1 at the top).
     Optimistic like the other Behaviour controls: the claim flips as a radio is
     clicked and flips back with a status line if the hub refuses the save. -->
<template>
  <div v-if="signedIn" class="issues-sort" data-test="issues-sort-setting">
    <span :id="`${uid}-label`" class="issues-sort__label">{{ t('settings.issues_sort.label') }}</span>
    <div class="issues-sort__row">
      <div class="issues-sort__opts" role="radiogroup" :aria-labelledby="`${uid}-label`">
        <label
          v-for="c in COLUMNS"
          :key="c"
          class="issues-sort__opt"
          :class="{ 'issues-sort__opt--on': current.col === c }"
        >
          <input
            type="radio"
            :name="`issues-sort-col`"
            :value="c"
            :checked="current.col === c"
            :disabled="saving"
            :data-test="`issues-sort-col-${c}`"
            @change="pick(c, current.dir)"
          />
          <span>{{ t(`issues.sort_${c}`) }}</span>
        </label>
      </div>
      <div class="issues-sort__opts" role="radiogroup" :aria-labelledby="`${uid}-label`">
        <label
          v-for="d in DIRS"
          :key="d"
          class="issues-sort__opt"
          :class="{ 'issues-sort__opt--on': current.dir === d }"
        >
          <input
            type="radio"
            :name="`issues-sort-dir`"
            :value="d"
            :checked="current.dir === d"
            :disabled="saving"
            :data-test="`issues-sort-dir-${d}`"
            @change="pick(current.col, d)"
          />
          <span>{{ t(`settings.issues_sort.${d}`) }}</span>
        </label>
      </div>
    </div>
    <p :id="`${uid}-hint`" class="muted issues-sort__hint">{{ t('settings.issues_sort.hint') }}</p>
    <p v-if="status" class="issues-sort__status" role="status" aria-live="polite" data-test="issues-sort-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'

/* the columns a default sort may name — the hub's own sorts, which have a
   sort_<col> label (issues-view.mjs ISSUE_SORTS). priority ascending is the
   product default. */
const COLUMNS = ['priority', 'level', 'deadline', 'updated', 'created'] as const
const DIRS = ['asc', 'desc'] as const

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const copy = useAuthCopy()
const uid = useId()
const signedIn = computed(() => session.state === 'in')
const saving = ref(false)
const status = ref('')

/* the stored default, else the product default (priority ascending). */
const current = computed(() => {
  const s = session.claims?.issues_sort
  if (s && typeof s.col === 'string' && typeof s.dir === 'string') return { col: s.col, dir: s.dir }
  return { col: 'priority', dir: 'asc' }
})

async function pick(col: string, dir: string) {
  if (!signedIn.value || saving.value) return
  if (current.value.col === col && current.value.dir === dir) return
  saving.value = true
  status.value = ''
  const prev = session.claims?.issues_sort ?? null
  const next = { col, dir }
  session.setIssuesSort(next) // optimistic: reverted on !ok (and on a throw)
  let res: Awaited<ReturnType<typeof auth.saveIssuesSort>>
  try {
    res = await auth.saveIssuesSort(next)
  } catch (err) {
    session.setIssuesSort(prev) // revert
    throw err
  } finally {
    saving.value = false
  }
  if (!res.ok) {
    session.setIssuesSort(prev) // revert
    status.value = copy.nativeError(res as Parameters<typeof copy.nativeError>[0]) || t('settings.language.failed')
  }
}

// The settings page can mount before the app's session probe has run; start it here.
onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.issues-sort {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.issues-sort__label { font-weight: 600; }
.issues-sort__row {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 24px;
}
.issues-sort__opts { display: grid; gap: 2px; }
.issues-sort__opt {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
  overflow-wrap: anywhere;
}
.issues-sort__opt--on { color: var(--color-accent); }
.issues-sort__hint,
.issues-sort__status { margin: 0; overflow-wrap: anywhere; }
.issues-sort__status { color: var(--color-error); }
</style>
