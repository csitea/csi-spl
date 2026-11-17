// SPL-985 (spec 042 §3): after a text is STORED, each person or agent it
// newly mentions gets a direct message from the author asking them to act -
// the same DM a person would type, so an agent's desk and pane get it like
// any other DM (spec 028). Rules are utils/mention-poke.mjs (unit-tested):
// who is poked (K3), the words (K1), who may be told (K4). A refusal or a
// failed poke is one snackbar line (K4, K6); the stored text is never rolled
// back for it. CLE-77852: an agent seated in the workspace but not in the
// channel is DM-poked anyway, and the author gets a notice saying so.
// Spec 067 (Q3, rule 3): a PERSON is never poked (the @mention reaches them in
// Flow), and an agent's poke carries ref_task_id, the channel topic it is about.
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'

/* 089 AC-02 (155 KB gzip): the poke rules load with the first poke, never
   with the entry: a poke only follows a stored text, after first paint. */
let pokeRules: Promise<typeof import('~/utils/mention-poke.mjs')> | null = null
export function loadMentionPoke() {
  /* a failed chunk load (a deploy in between) is asked again next time */
  return (pokeRules ||= import('~/utils/mention-poke.mjs').catch((e) => { pokeRules = null; throw e }))
}

/** CLE-77852: how long the "sent as a direct message" notice stays up. */
export const DIRECT_NOTE_MS = 6000

type DirectNote = { id: number, text: string }

/* one notice per tab, shared by the poking store and the shell's toast */
const directNote = shallowRef<DirectNote | null>(null)
let noteSeq = 0

export type PokeOpts = { text: string, before?: string, addressee?: string, where: PokeWhere }
export type PokeResult = { told: string[], refused: string[], failed: string[] }

/** The shell's MentionDirectToast reads and dismisses the notice. */
export function useMentionDirectNote() {
  return { note: directNote, dismiss: () => { directNote.value = null } }
}

export interface PokeWhere {
  /** a card, reply or comment: its task id; an issue: its key */
  taskId?: string
  issueKey?: string
  /** where the text lives, for K4: a channel id, a DM peer (id@box), or an issue */
  channel?: string
  peer?: string
  /** a DM topic's two ends (utils/mention-poke.mjs topicWhere) */
  ends?: string[]
  issue?: boolean
  /** where is not known: tell nobody (K4) */
  unknown?: boolean
}

/* SPL-5780: the poke itself (composables/mentionPokeRun.ts) loads with the
   first poke, like the rules; a failed chunk load is asked again next time */
let pokeRun: Promise<typeof import('~/composables/mentionPokeRun')> | null = null
function loadPokeRun() {
  return (pokeRun ||= import('~/composables/mentionPokeRun').catch((e) => { pokeRun = null; throw e }))
}

export function useMentionPoke() {
  const api = useSpoolApi()
  const roster = useRosterStore()
  const live = useLive()
  /* the global instance: this runs from stores too, outside any setup() */
  const i18n = useNuxtApp().$i18n

  function noteDirect(ids: string[]) {
    directNote.value = { id: ++noteSeq, text: i18n.t('mention.sent_direct', { ids: ids.join(', ') }) }
  }

  let run: ((opts: PokeOpts) => Promise<PokeResult>) | null = null

  /**
   * `text` was just stored at `where`. `before` is the text before an edit
   * (only new mentions poke); `addressee` the agent the send itself went to.
   * Resolves to what happened; never throws.
   */
  async function poke(opts: PokeOpts): Promise<PokeResult> {
    if (!run) {
      const mod = await loadPokeRun().catch(() => null)
      if (!mod) return { told: [], refused: [], failed: [] }
      run = mod.mentionPokeRunner({ api, roster, live, i18n, loadMentionPoke, noteDirect })
    }
    return run(opts)
  }

  return { poke }
}
