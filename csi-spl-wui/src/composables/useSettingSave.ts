/**
 * The save half of an optimistic per-human setting (Debug pane, Text fields):
 * one save at a time while signed in, a `saving` flag for the control, and a
 * status line when the hub refuses. Each setting keeps its own apply*Setting
 * call as the job (utils/debug-pane.mjs, utils/submit-key.mjs).
 */
import { ref } from 'vue'
import { useSessionStore } from '~/stores/session'
import { useAuthCopy } from '~/composables/useAuthCopy'

type NativeOut = Parameters<ReturnType<typeof useAuthCopy>['nativeError']>[0]

export function useSettingSave() {
  const { t } = useI18n({ useScope: 'global' })
  const session = useSessionStore()
  const copy = useAuthCopy()
  const saving = ref(false)
  const status = ref('')

  async function run(job: () => Promise<{ ok: boolean, out?: unknown }>) {
    if (session.state !== 'in' || saving.value) return
    saving.value = true
    status.value = ''
    const res = await job()
    saving.value = false
    if (!res.ok) {
      status.value = copy.nativeError((res.out ?? null) as NativeOut) || t('settings.language.failed')
    }
  }

  return { saving, status, run }
}
