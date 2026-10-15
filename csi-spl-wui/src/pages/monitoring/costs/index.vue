<!-- SPL-2048: Monitoring -> Costs (spec 123 section 5 + 8).
     A month picker, a table of cost parts, and an inline-SVG pie chart.
     Visible only to users with `costs.read`; 403 otherwise. -->
<template>
  <div class="monitoring-costs" data-test="monitoring-costs">
    <div v-if="!hasPermission" class="monitoring-403">
      <p>{{ t('monitoring.costs.no_permission') }}</p>
    </div>
    <template v-else>
      <div class="monitoring-costs-header">
        <h3>{{ t('monitoring.costs.title') }}</h3>
        <div class="monitoring-costs-month-picker">
          <select v-model="selectedMonth" @change="fetchCosts">
            <option v-for="month in availableMonths" :key="month.value" :value="month.value">
              {{ month.label }} {{ month.soFar ? t('monitoring.costs.so_far') : '' }}
            </option>
          </select>
        </div>
      </div>

      <div v-if="loading" class="monitoring-costs-loading">
        {{ t('common.loading') }}
      </div>

      <div v-else-if="error" class="monitoring-costs-error">
        {{ error }}
      </div>

      <template v-else>
        <div v-if="!costs || costs.parts.length === 0" class="monitoring-costs-empty">
          <p>{{ t('monitoring.costs.no_data') }}</p>
          <div v-if="costs && costs.coverage">
            <p v-for="source in costs.coverage" :key="source.source">
              {{ t('monitoring.costs.no_data_source', { source: source.source }) }}: {{ source.ok }}/{{ source.days }} {{ t('monitoring.costs.days_complete') }}
            </p>
          </div>
        </div>

        <template v-else>
          <div class="monitoring-costs-table">
            <table>
              <thead>
                <tr>
                  <th>{{ t('monitoring.costs.table.source') }}</th>
                  <th>{{ t('monitoring.costs.table.project_vendor') }}</th>
                  <th>{{ t('monitoring.costs.table.kind') }}</th>
                  <th>{{ t('monitoring.costs.table.usd') }}</th>
                  <th>{{ t('monitoring.costs.table.eur') }}</th>
                  <th>{{ t('monitoring.costs.table.pct') }}</th>
                  <th>{{ t('monitoring.costs.table.list_price') }}</th>
                  <th>{{ t('monitoring.costs.table.hand') }}</th>
                  <th>{{ t('monitoring.costs.table.coverage') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="part in costs.parts" :key="`${part.source}-${part.project_or_vendor}-${part.kind}`">
                  <td>{{ part.source }}</td>
                  <td>{{ part.project_or_vendor }}</td>
                  <td>{{ part.kind }}</td>
                  <td>{{ formatMoney(part.usd_micros, 'USD') }}</td>
                  <td>{{ formatMoney(part.eur_micros, 'EUR') }}</td>
                  <td>{{ formatPercentage(part.pct) }}</td>
                  <td>{{ part.list_value_micros > 0 ? formatMoney(part.list_value_micros, 'USD') : '-' }}</td>
                  <td>{{ part.hand ? t('monitoring.costs.table.hand_yes') : '-' }}</td>
                  <td>
                    {{ coverageFor(part.source) }}
                  </td>
                </tr>
                <tr class="monitoring-costs-total">
                  <td colspan="3">{{ t('monitoring.costs.table.total') }}</td>
                  <td>{{ formatMoney(costs.total.usd_micros, 'USD') }}</td>
                  <td>{{ formatMoney(costs.total.eur_micros, 'EUR') }}</td>
                  <td>100%</td>
                  <td>-</td>
                  <td>-</td>
                  <td>-</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="monitoring-costs-pie">
            <CostsPieChart :parts="costs.parts" />
          </div>
        </template>
      </template>
    </template>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { useOperatorPane } from '~/stores/operator-pane'
import CostsPieChart from '~/components/CostsPieChart.vue'
import { formatMoney, formatPercentage } from './utils.mjs'

const { t } = useI18n({ useScope: 'global' })
const operator = useOperatorPane()

const hasPermission = ref<boolean>(false)

// Simulate costs.read permission for dev
function checkPermission() {
  hasPermission.value = operator.visible // In prod, this would call the API
}
const selectedMonth = ref<string>('')
const availableMonths = ref<Array<{ value: string, label: string, soFar: boolean }>>([])
const costs = ref<any>(null)
const loading = ref<boolean>(false)
const error = ref<string | null>(null)

// Generate month options (current month + past 11 months)
function generateMonthOptions() {
  const months = []
  const now = new Date()
  for (let i = 0; i < 12; i++) {
    const date = new Date(now.getFullYear(), now.getMonth() - i, 1)
    const value = date.toISOString().slice(0, 7) // YYYY-MM
    const label = date.toLocaleString('default', { month: 'long', year: 'numeric' })
    const soFar = i === 0 // Only the current month is "so far"
    months.push({ value, label, soFar })
  }
  availableMonths.value = months
  selectedMonth.value = months[0].value
}

// Fetch cost data for the selected month
async function fetchCosts() {
  if (!hasPermission.value) return
  
  loading.value = true
  error.value = null
  
  try {
    const response = await fetch(`/v1/tenant/costs?month=${selectedMonth.value}`)
    if (!response.ok) {
      if (response.status === 403) {
        hasPermission.value = false
        return
      }
      throw new Error(`HTTP ${response.status}`)
    }
    costs.value = await response.json()
  } catch (err) {
    error.value = t('monitoring.costs.fetch_error')
    console.error('Failed to fetch costs:', err)
  } finally {
    loading.value = false
  }
}

// Get coverage text for a source
function coverageFor(source: string): string {
  if (!costs.value?.coverage) return '-'
  const cov = costs.value.coverage.find((c: any) => c.source === source)
  if (!cov) return '-'
  return t('monitoring.costs.coverage', { ok: cov.ok, days: cov.days })
}

onMounted(() => {
  checkPermission()
  generateMonthOptions()
  fetchCosts()
})
</script>

<style scoped>
.monitoring-costs {
  padding: 1rem;
}

.monitoring-costs-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1rem;
}

.monitoring-costs-month-picker select {
  padding: 0.5rem;
  border-radius: 4px;
  border: 1px solid #ccc;
}

.monitoring-costs-table table {
  width: 100%;
  border-collapse: collapse;
  margin-bottom: 2rem;
}

.monitoring-costs-table th,
.monitoring-costs-table td {
  padding: 0.75rem;
  text-align: left;
  border-bottom: 1px solid #eee;
}

.monitoring-costs-table th {
  background-color: #f9f9f9;
}

.monitoring-costs-total {
  font-weight: bold;
}

.monitoring-costs-pie {
  margin-top: 2rem;
}
</style>
