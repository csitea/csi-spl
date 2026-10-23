// ChannelSidebar's source, as the tests that read it need it.
//
// r13-04 split the sidebar's <script> over composables
// (src/composables/useSidebar*.ts): the sidebar wires them, each holds one
// part. A test that pins a line of the sidebar's code reads this instead of
// ChannelSidebar.vue alone, so the line is found whichever of those files
// holds it now. The SFC comes first: a test that looks for its <template> or
// <style> still finds them where they were.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')

export const CHANNEL_SIDEBAR_FILES = [
  'src/components/ChannelSidebar.vue',
  'src/composables/useSidebarCounts.ts',
  'src/composables/useSidebarPeers.ts',
  'src/composables/useSidebarChannelAdmin.ts',
  'src/composables/useSidebarChannelCreate.ts',
  'src/composables/useSidebarRowDrag.ts',
  'src/composables/useSidebarRowKeys.ts',
  'src/composables/useSidebarVersion.ts',
  'src/composables/useSidebarRailTabKeys.ts',
  'src/composables/useSidebarRailOnly.ts',
  'src/composables/useSidebarRailNav.ts',
]

/** ChannelSidebar.vue, then every composable it was split into, one string. */
export function channelSidebarSrc() {
  return CHANNEL_SIDEBAR_FILES.map((f) => readFileSync(join(WUI, f), 'utf8')).join('\n')
}
