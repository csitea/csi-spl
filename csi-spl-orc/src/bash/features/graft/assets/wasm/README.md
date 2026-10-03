# Breadth-tier grammar WASM not shipped by the vendor bundle

tree-sitter-wasm@1.1.8 -- the version the offline pack resolves -- ships 103 grammars
and does NOT include "sql". Version 1.1.6 did (112 grammars). The file here is the
1.1.6 sql grammar, kept because this estate is ~46% Hive SQL and the index is close to
worthless without it.

Validated before adoption: 60 real Hive files, 4.7% of bytes inside ERROR nodes, and it
yields the nodes an index needs -- object_reference, create_table, create_view,
create_query, drop_table, insert, cte. ABI-checked against web-tree-sitter 0.26.13, the
version carried in the pack.

graft-register-lang.sh refuses to register a language whose wasm is absent -- correct
behaviour, and the reason this directory exists instead of a silent fallback.
