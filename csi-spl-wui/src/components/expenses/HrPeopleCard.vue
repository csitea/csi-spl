<!-- SPL-5433 (spec 123 16.2; owner poll 2ff12c21 answer 2 B): the people the
     accountant books human costs for. A person is a code (E-01); the real
     name shows only to a costs.write member (the hub sends names = true),
     everyone else reads the codes. Add only; the hub keeps no edit route
     yet. The list is the card's (CostEntriesCard.vue), reloaded on 'added'. -->
<template>
  <details class="hr-people" data-test="hr-people">
    <summary>{{ t('expenses.hr.people', { n: people.length }) }}</summary>
    <p v-if="!names && people.length" class="muted" data-test="hr-people-codes-only">{{ t('expenses.hr.codes_only') }}</p>
    <ul class="hr-people-list">
      <li v-for="p in people" :key="p.id" data-test="hr-person">
        <strong>{{ p.code }}</strong>
        <span v-if="p.name" data-test="hr-person-name">{{ p.name }}</span>
        <span class="muted">{{ [p.department, t('expenses.hr.type.' + p.employmentType)].filter(Boolean).join(' · ') }}</span>
      </li>
    </ul>
    <form v-if="!readonly && names" class="hr-people-form" data-test="hr-person-form" novalidate @submit.prevent="submit">
      <input v-model="f.code" type="text" maxlength="8" :placeholder="t('expenses.hr.code')" :aria-label="t('expenses.hr.code')" data-test="hr-p-code">
      <input v-model="f.name" type="text" maxlength="200" :placeholder="t('expenses.hr.name')" :aria-label="t('expenses.hr.name')" data-test="hr-p-name">
      <input v-model="f.department" type="text" maxlength="100" :placeholder="t('expenses.hr.department')" :aria-label="t('expenses.hr.department')" data-test="hr-p-department">
      <select v-model="f.employmentType" :aria-label="t('expenses.hr.employment')" data-test="hr-p-type">
        <option v-for="ty in HR_EMPLOYMENT_TYPES" :key="ty" :value="ty">{{ t('expenses.hr.type.' + ty) }}</option>
      </select>
      <input v-model="f.birthYear" type="number" min="1900" max="2100" :placeholder="t('expenses.hr.birth_year')" :aria-label="t('expenses.hr.birth_year')" data-test="hr-p-birth">
      <button type="submit" class="btn" :disabled="busy" data-test="hr-p-save">{{ t('expenses.hr.add_person') }}</button>
      <span v-if="problem" class="hr-err" role="alert" data-test="hr-p-error">{{ t('expenses.hr.' + problem) }}</span>
      <span v-else-if="refused" class="hr-err" role="alert" data-test="hr-p-refused">{{ refused }}</span>
    </form>
  </details>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { checkHrPersonForm, emptyHrPersonForm, HR_EMPLOYMENT_TYPES, hrPersonBody } from '~/utils/hr-costs.mjs'

type Person = { id: string, code: string, name: string, department: string, employmentType: string }
type PeopleApi = { fleetPaid: (op: 'hr_person_create', a?: unknown) => Promise<unknown> }
const props = defineProps<{ people: Person[], names: boolean, readonly?: boolean }>()
const emit = defineEmits<{ (e: 'added'): void }>()
const { t } = useI18n({ useScope: 'global' })
const f = reactive(emptyHrPersonForm())
const problem = ref('')
const refused = ref('')
const busy = ref(false)

async function submit() {
  refused.value = ''
  problem.value = checkHrPersonForm(f, props.people)
  if (problem.value) return
  busy.value = true
  try {
    await (useSpoolApi() as unknown as PeopleApi).fleetPaid('hr_person_create', hrPersonBody(f))
    Object.assign(f, emptyHrPersonForm())
    emit('added')
  } catch (e) {
    const err = e as { detail?: string, token?: string, message?: string }
    refused.value = String(err?.detail || err?.token || err?.message || '')
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.hr-people { border: 1px solid var(--color-border); border-radius: var(--radius-md); padding: 6px 10px; }
.hr-people summary { cursor: pointer; font-weight: 600; }
.hr-people-list { list-style: none; margin: 6px 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.hr-people-list li { display: flex; flex-wrap: wrap; gap: 4px 10px; overflow-wrap: anywhere; }
.hr-people-form { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hr-people-form input, .hr-people-form select { min-width: 0; max-width: 14rem; font: inherit; }
.hr-err { color: var(--color-danger); }
</style>
