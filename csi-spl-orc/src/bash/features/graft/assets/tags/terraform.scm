; tree-sitter-terraform tags query.
;
; Capture the block LABELS, never the block keyword: `resource "t" "n"` has
; (identifier)="resource" and two string_lit labels. Capturing the identifier
; names every resource in the repo "resource", which is worse than no index.
;
; Attribute definitions are deliberately NOT captured. Measured on 20 real .tf
; files: 471 attributes against 153 blocks, i.e. `name`/`project`/`filter`
; would outnumber real symbols 3:1 and none of them is addressable.
(block
  (identifier) @_kind
  (string_lit (template_literal) @name)) @definition.type

; NO @reference.call. HCL's function_call names BUILT-INS -- lookup, join,
; merge, cidrsubnet -- which are never defined in the repo, so graft's resolver
; has nothing to bind them to and every edge would dangle. The only definition
; kind here is `type` (resource/variable/output block labels), and `type` is not
; in graft's callKinds, so a call edge could not resolve even in principle.
;
; Caught by test-graft-contract.sh, which nea wrote and which this box only
; started running once the suite stopped falsely skipping. An index that emits
; edges resolving to nothing is worse than one that emits none: it reports
; coverage it does not have.
