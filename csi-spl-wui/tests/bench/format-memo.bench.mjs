// A file card's size and a card's two avatars, per render (CLE-35075):
// formatBytes with a locale, avatarDataUri for 20 ids x 50 cards.
import { bench, src } from './lib/bench.mjs'

const { formatBytes } = await src('utils/channel-feed.mjs')
const { avatarDataUri } = await src('utils/avatar.mjs')

bench('formatBytes x1000 (fi)', () => { let s = ''; for (let i = 0; i < 1000; i++) s = formatBytes(2048 + i, 'fi'); return s })
bench('avatarDataUri x1000 (20 ids)', () => { let s = ''; for (let i = 0; i < 1000; i++) s = avatarDataUri('HUM-' + (i % 20), i % 2 ? 'box-a' : ''); return s })
