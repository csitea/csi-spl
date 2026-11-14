<!-- SPL-5433 (spec 123 16.2): an hr line's own fields in the HR tab's add
     form: the person (none = the organisation's line), the component in its
     group, where the figure comes from, the ledger account, a yearly total,
     and the closed month a late correction is for. The form object is the
     card's (CostEntriesCard.vue), edited in place. -->
<template>
  <label>
    <span>{{ t('expenses.hr.person') }}</span>
    <select v-model="form.personId" data-test="hr-f-person">
      <option value="">{{ t('expenses.hr.person_none') }}</option>
      <option v-for="p in people" :key="p.id" :value="p.id">{{ p.name ? p.code + ' · ' + p.name : p.code }}</option>
    </select>
  </label>
  <label>
    <span>{{ t('expenses.hr.component') }}</span>
    <select v-model="form.component" data-test="hr-f-component">
      <option value="">—</option>
      <optgroup v-for="g in groups" :key="g.group" :label="t('expenses.hr.group.' + g.group)">
        <option v-for="c in g.items" :key="c.component" :value="c.component">{{ c.label }}</option>
      </optgroup>
    </select>
  </label>
  <label>
    <span>{{ t('expenses.hr.source') }}</span>
    <input v-model="form.source" type="text" maxlength="200" data-test="hr-f-source">
  </label>
  <label>
    <span>{{ t('expenses.hr.account') }}</span>
    <input v-model="form.account" type="text" maxlength="20" data-test="hr-f-account">
  </label>
  <label>
    <span>{{ t('expenses.hr.kind') }}</span>
    <select v-model="form.periodKind" data-test="hr-f-kind">
      <option value="month">{{ t('expenses.hr.kind_month') }}</option>
      <option value="year">{{ t('expenses.hr.kind_year') }}</option>
    </select>
  </label>
  <label>
    <span>{{ t('expenses.hr.corrects') }}</span>
    <input v-model="form.correctsPeriod" type="month" data-test="hr-f-corrects">
  </label>
</template>

<script setup lang="ts">
import { hrComponentGroups } from '~/utils/hr-costs.mjs'

type Person = { id: string, code: string, name: string }
type Component = { component: string, group: string, label: string }
const props = defineProps<{
  form: { personId: string, component: string, source: string, account: string, periodKind: string, correctsPeriod: string }
  people: Person[]
  components: Component[]
}>()
const { t } = useI18n({ useScope: 'global' })
const groups = computed(() => hrComponentGroups(props.components))
</script>
