; tags.scm -- bash (tree-sitter-wasm `bash` grammar)
;
; These trees are shell-first: graft's precompiled tier sees 3.6% of the box
; tooling repo and 9.5% of the doc tooling repo, and shell is nearly all of the
; rest. The grammar earns the row -- 0.5% ERROR bytes over 1044 real scripts,
; 98% of files parsing clean, one degenerate parse in the whole corpus.
;
; THE CAPTURE NAMES ARE NOT FREE. graft's generic tier (dist/graph/generic.js)
; consumes exactly `definition.*`, `reference.call`, `reference.send`,
; `reference.class`, `reference.interface`, `reference.implementation` and
; `reference.module`. Any other name compiles, matches, and is silently
; discarded. And `@definition.<kind>` goes through a fixed KIND table whose
; MISSES FALL BACK TO "function" -- so a readable `@definition.script` would
; quietly file every script as a function rather than fail. Everything below is
; a name from those two lists, chosen for what graft will do with it, not for
; how it reads here.

; ---------------------------------------------------------------- definitions

; Both spellings -- `f() { ... }` and `function f { ... }` -- normalise to the
; same node, so one pattern is enough. A second keyed on the `function` keyword
; would double-count every definition written that way.
(function_definition
  name: (word) @name) @definition.function

; FOO=bar at any level, including inside declare/local/export/readonly:
; `declaration_command` wraps this same `variable_assignment` node, so one
; pattern catches both and a separate declaration pattern would double-count.
;
; These scripts configure by convention (ENV, PIPELINE, owner and friends), so
; "where is this set" is a real navigation question here and not the noise it
; would be in an application language.
(variable_assignment
  name: (variable_name) @name) @definition.variable

; ----------------------------------------------------------------- references

; Every command head: `helper_fn "$x"`, `./run -a do_thing`, `git`, `awk`. This
; is the call graph -- script-to-function and script-to-tool alike -- and it is
; the single most useful thing the grammar gives us on this estate.
;
; graft attributes each call to its innermost enclosing definition and skips a
; call landing on a definition's own name token, so the self-loops that shape
; would otherwise produce do not appear.
(command
  name: (command_name) @name) @reference.call

; NOT CAPTURED, and this is the interesting omission: `. lib.sh` / `source
; "$HERE/lib.sh"`. The include graph is how these repos are actually wired, so
; capturing the sourced FILE looks like the most valuable edge here -- and it is
; dead on arrival. `@reference.module` becomes a `references` edge, which
; resolve.js settles only against kinds ["class","interface","struct","enum",
; "type","module"]. Every definition in this file is a function or a variable,
; and a file node is kind "file", so a sourced path can never match anything.
; It would extract cleanly, resolve to zero, and leave a query that looks like
; it captures the include graph while capturing nothing -- the exact silent
; failure this feature exists to avoid. Better absent than decorative.
;
; (The `.`/`source` command head is still captured as a call by the pattern
; above, so the fact that a file sources something is visible; which file it
; sources is not.)
