/**
 * The state label of a release note (spec 065 L11; owner HUM-10, t1 5a91349c,
 * 2026-11-24: "Notes should be always required").
 *
 * A note the hub stored as `missing` reads "committed before notes were
 * required" only for a commit from before the push gate started refusing a
 * commit without its note. A later one landed without its note anyway (a push
 * that skipped the gate), and says so plainly.
 *
 * NOTES_REQUIRED_SINCE is the commit time of the change that made the
 * pre-push part `release-note` refuse (the commit that added _RN_SWITCH_MARK to
 * csi-spl-iac/src/bash/run/check-release-note.func.sh).
 *
 * Pure: the i18n key only; the caller translates it.
 */

export const NOTES_REQUIRED_SINCE = '2026-11-24T15:23:10Z'

const STATES = ['missing', 'backfill', 'skip', 'revert']

/** The release_notes.* key for a note's state, '' when the state shows none. */
export function noteStateKey(state, committedAt) {
  if (!STATES.includes(state)) return ''
  if (state !== 'missing') return 'state_' + state
  const at = Date.parse(String(committedAt || ''))
  return Number.isFinite(at) && at >= Date.parse(NOTES_REQUIRED_SINCE) ? 'state_missing_required' : 'state_missing'
}
