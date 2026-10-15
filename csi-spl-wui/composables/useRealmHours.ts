// WUI/composables/useRealmHours.ts
// Spec 118 T005: Cross-workspace hours state, today's provisional timer span, limit warning.

import { ref, computed, onMounted, onUnmounted } from 'vue';
import type { PersonalDay } from '../utils/hours-across.mjs';
import { fetchRealmHours } from '../utils/realm-hours-api.mjs';

export function useRealmHours() {
  const days = ref([] as PersonalDay[]);
  const totals = ref({} as Record<string, number>);
  const loading = ref(false);
  const error = ref(null as Error | null);
  const tz = ref('UTC');
  const tz_source = ref('UTC');
  const limit_day = ref(0);
  const limit_week = ref(0);
  const warning_threshold = computed(() => limit_week.value * 0.9);

  // Today's provisional timer span (start, end, workspace)
  const provisionalTimer = ref({
    start: '',
    end: '',
    workspace: ''
  });

  // Fetch realm hours for a date range
  const fetch = async (from: string, to: string) => {
    loading.value = true;
    error.value = null;

    try {
      const response = await fetchRealmHours(from, to);
      days.value = (response.days || []) as PersonalDay[];
      totals.value = (response.totals || {}) as Record<string, number>;
      tz.value = response.tz;
      tz_source.value = response.tz_source;

      // Extract limits (day and week)
      const dayLimit = response.limits?.find((l: any) => l.kind === 'day')?.minutes || 0;
      const weekLimit = response.limits?.find((l: any) => l.kind === 'week')?.minutes || 0;
      limit_day.value = dayLimit;
      limit_week.value = weekLimit;
    } catch (err) {
      error.value = err as Error;
    } finally {
      loading.value = false;
    }
  };

  // Compute today's provisional timer span
  const updateProvisionalTimer = () => {
    const now = new Date();
    const today = now.toISOString().split('T')[0];
    const todayDay = days.value.find((day: PersonalDay) => day.day === today);

    if (todayDay) {
      Object.entries(todayDay.workspaces).forEach(([workspace, data]: [string, any]) => {
        const provisionalSpan = data.spans.find((span: any) => span.provisional);
        if (provisionalSpan) {
          provisionalTimer.value = {
            start: provisionalSpan.start,
            end: provisionalSpan.end,
            workspace
          };
        }
      });
    }
  };

  // Compute limit warning state (amber at 90%, red past 100%)
  const limitWarning = computed(() => {
    if (limit_week.value === 0) return 'none';
    const actualWeek = totals.value.actual || 0;
    if (actualWeek >= limit_week.value) return 'red';
    if (actualWeek >= warning_threshold.value) return 'amber';
    return 'none';
  });

  // Recompute on mount and unmount
  onMounted(() => {
    updateProvisionalTimer();
  });

  // Recompute every minute for the provisional timer
  let intervalId: number;
  onMounted(() => {
    intervalId = window.setInterval(updateProvisionalTimer, 60000);
  });
  onUnmounted(() => {
    clearInterval(intervalId);
  });

  return {
    days,
    totals,
    loading,
    error,
    tz,
    tz_source,
    limit_day,
    limit_week,
    warning_threshold,
    provisionalTimer,
    limitWarning,
    fetch
  };
}