// W14 (spec 047, SPL-1169): the /help page's link rules (utils/help.mjs).
//
// Run: node tests/unit/help.test.mjs
import { fillHelpHosts, helpHref, helpRepoBase, hostOf, rewriteHelpLinks, validHelpSlug } from '../../src/utils/help.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('help')
ok('a sibling page becomes the /help route', helpHref('./how-to-post.md') === '/help/how-to-post' && helpHref('global-search.md#x') === '/help/global-search')
ok('the index is /help itself', helpHref('./index.md') === '/help')
ok('the route builder is the page\'s (locale prefix)', helpHref('./user-settings.md', (s) => '/fi/help/' + s) === '/fi/help/user-settings')
ok('absolute, mailto, anchor and site paths stay', ['https://example.com/a', 'mailto:a@example.com', '#top', '/search?q=x'].every((h) => helpHref(h) === h))
const BASE = helpRepoBase('https://git.example.org/acme/spool/', '/-/blob/main/doc/help/')
ok('the repo base is the two cnf values joined', BASE === 'https://git.example.org/acme/spool/-/blob/main/doc/help/')
ok('either value unset or malformed: no repo base', helpRepoBase('', '/blob/x/') === '' && helpRepoBase('https://x', '') === '' && helpRepoBase('x', '/a/') === '' && helpRepoBase('https://x', 'a/') === '')
ok('any other relative link points at the configured repo', helpHref('../../specs/047/x.md', undefined, BASE) === 'https://git.example.org/acme/spool/-/blob/main/specs/047/x.md')
ok('no repo configured: that link is hidden, never a fallback', helpHref('../../specs/047/x.md') === '' && rewriteHelpLinks('see [the spec](../x.md) now') === 'see the spec now')
ok('no repo configured: help-page links still work', rewriteHelpLinks('[Post](./how-to-post.md) [s](../x.md)') === '[Post](/help/how-to-post) s')
ok('rewrite touches only link targets', rewriteHelpLinks('see [Post](./how-to-post.md) and (./x.md) text') === 'see [Post](/help/how-to-post) and (./x.md) text')
ok('slugs are the sync rule', validHelpSlug('getting-started') && !validHelpSlug('../x') && !validHelpSlug('') && !validHelpSlug('A'))
ok('host tokens: this deployment\'s hub and site', fillHelpHosts('https://{{api}} at https://{{site}}/t/1', { api: 'hub.example.org', site: 'chat.example.org' }) === 'https://hub.example.org at https://chat.example.org/t/1')
ok('one host for both (self-hosted, same origin)', fillHelpHosts('{{api}} {{site}}', { site: 'chat.example.org' }) === 'chat.example.org chat.example.org')
ok('hostOf', hostOf('https://a.example.org:8443/x') === 'a.example.org:8443' && hostOf('nope') === '')
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`help: ${failed} FAILED`)
  process.exit(1)
}
console.log('help: all passed')
