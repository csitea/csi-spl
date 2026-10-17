// Guards the live proofs' verify-token helper (SPL-2411): since SPL-2157 the
// dev hub answers no debug_token, so a proof that registers reads the verify
// mail through MAIL_TOKEN_CMD. CONTROL: no debug_token and no command is a
// clear error naming the way out, never a crash or an empty token sent on.
//
// Run: node tests/unit/proof-verify-token.test.mjs
import { verifyToken, relayPlus, NO_TOKEN } from '../e2e/lib/proof.mjs'

let failed = 0
const check = (n, ok, m) => { if (ok) console.log(`  OK   ${n}`); else { failed++; console.log(`  FAIL ${n}: ${m}`) } }
const withCmd = (cmd, fn) => {
  const was = process.env.MAIL_TOKEN_CMD
  if (cmd === undefined) delete process.env.MAIL_TOKEN_CMD; else process.env.MAIL_TOKEN_CMD = cmd
  try { return fn() } finally { if (was === undefined) delete process.env.MAIL_TOKEN_CMD; else process.env.MAIL_TOKEN_CMD = was }
}

console.log('proof verifyToken (debug token, else the verify mail)')
const tok = 'a'.repeat(64)

let r = withCmd('exit 9', () => verifyToken({ status: 'verification_required', debug_token: tok }, 'x+1@example.net'))
check('a debug_token wins (lde), the command is not run', r.token === tok && r.via === 'debug_token', JSON.stringify(r))

r = withCmd(undefined, () => verifyToken({ status: 'verification_required' }, 'x+1@example.net'))
check('CONTROL: no debug_token, no MAIL_TOKEN_CMD -> no token, a clear error', r.token === '' && r.via === 'none' && r.error === NO_TOKEN, JSON.stringify(r))
check('CONTROL: the error names SPL-2157 and the action', /SPL-2157/.test(NO_TOKEN) && /do_spl_mail_verify_token/.test(NO_TOKEN), NO_TOKEN)
r = withCmd(undefined, () => verifyToken(null, 'x+1@example.net'))
check('CONTROL: an empty register body does not throw', r.token === '' && r.error === NO_TOKEN, JSON.stringify(r))

r = withCmd(`[ "$MAIL_TOKEN_EMAIL" = x+1@example.net ] && printf '%s\\n' ${'b'.repeat(64)} >"$MAIL_TOKEN_FILE"`, () => verifyToken({}, 'x+1@example.net'))
check('the command gets the address and writes the token file', r.token === 'b'.repeat(64) && r.via === 'mail', JSON.stringify(r))

r = withCmd('echo "FAIL no verify token: no verify mail within 1s"; exit 1', () => verifyToken({}, 'x+1@example.net'))
check('a command that finds no mail -> no token, its last line in the error', r.token === '' && r.via === 'mail' && r.error === 'MAIL_TOKEN_CMD exit 1: FAIL no verify token: no verify mail within 1s', JSON.stringify(r))

check('relayPlus makes a plus-address of the relay mailbox', relayPlus('relay@example.net', 'wui-1') === 'relay+wui-1@example.net', relayPlus('relay@example.net', 'wui-1'))

if (failed) { console.log(`\nproof-verify-token: ${failed} FAILED`); process.exit(1) }
console.log('\nproof-verify-token: all passed')
