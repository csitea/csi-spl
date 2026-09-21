# fastpath-v1 — hello capability negotiation and the paths it enables

**Version**: 0.1.0 · spec `030-spool-wire-fastpath` · extends 003
`contracts/http-v1.md` §2.2 (hello) and §2.3 (welcome).

This contract adds **one optional, unsigned field** to two existing frames. It
adds no new message semantics: every capability here is permission to reach the
same stored message over a cheaper path.

## 1. The field

```
caps: ["<token>", ...]     // sorted, short lowercase tokens, optional
```

On `hello` it is what the CLIENT can do. On `welcome` it is what the HUB can
do. Both are optional.

**It is not covered by any signature.** `wire.HelloPayload` remains
`jq -cS '{box_id,nonce,ts}'`, exactly as 020 left `msg_versions` outside it. A
peer that adds `caps` produces a byte-identical hello signature to one that does
not, so no deployed verifier changes behaviour.

## 2. Rules

1. **Absent or empty = pre-030.** The peer MUST be treated exactly as it is
   treated today. This is the mixed-fleet rule of 020 `migration.md` §3, and it
   is what keeps every already-deployed box and browser working.
2. **Unknown tokens are ignored**, never an error, in both directions. A newer
   client may therefore announce tokens an older hub has never heard of, and an
   older hub's silence is a valid answer.
3. **A fast path is used only when BOTH sides name it.** The intersection of the
   two `caps` lists decides; anything outside it uses the old path.
4. **No capability changes what a message IS.** The envelope, the inner object,
   the canonical bytes and every signature are identical on both paths (spec
   FR-006). A capability may change only *which connection* carries it, *when*
   it is carried, or *what else is carried alongside*.
5. **Withdrawing a token is a rollback**, and takes effect on the next hello.
   No redeploy of the peer, no stored data touched.

## 3. Tokens

| token | side | meaning |
|---|---|---|
| `submit` | client | this box runs a local submit listener: its CLI hands outbound envelopes to the sidecar's warm hub session instead of dialling a new `role=cli` socket (spec FP-2). Purely box-local; the hub never sees the difference. |

A token is added to this table by the spec that introduces it, together with
the control that proves an old peer still works without it.

## 4. What is deliberately NOT here

- **No binary or length-prefixed frame.** Measured 2026-09-21 (spec §0): the
  whole in-process protocol — canonicalise, sign, verify, encode, decode — costs
  ~0.26 ms for an interactive line against a 61.5 ms round trip. A binary frame
  would put the canonical signing bytes at risk to save ~0.4 % of one hop.
- **No change to the message envelope.** `v:1` is frozen (002); `v:2` readers
  are as 020 deployed them.
- **No new fetch.** Both sockets already push the full body; there is no
  notify-then-fetch here to collapse.
