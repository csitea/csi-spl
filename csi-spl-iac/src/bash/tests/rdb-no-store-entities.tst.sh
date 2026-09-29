#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 007 T016 / FR-006 / SC-003 — csi-spl-rdb SQL is spool tables
#          only. A grep for store entities (product, cart, sku, wp_) must be
#          empty. "production" and "filename order" are not store entities.
#
#          CONTROLS: a guard that finds nothing proves nothing unless it is
#          shown to find something. Control 1 plants store-entity DDL and
#          requires those hits; control 2 plants "production"/"filename order"
#          and requires none; control 3 requires at least one .sql file so an
#          empty tree is not a vacuous pass.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# store_entity_hits <sql-root> -> prints file:line hits (relative when possible)
# "the product default" / "product-neutral" are software prose (the app, the
# built-in default), not a store `products` table — exempted like "production".
# A real store entity is a table/column name (products, carts, skus), never the
# phrase "product default"; the exemption is anchored to those two phrases only.
store_entity_hits() {
  local root="$1"
  grep -rInE --include='*.sql' \
    '(^|[^A-Za-z0-9_])(products?|carts?|skus?)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])wp_' \
    "$root" 2>/dev/null | sed "s#^$root/##" \
    | grep -vEi 'product[ -](default|neutral)' || true
}

SQL="$APP_ROOT/csi-spl-rdb/src/sql"
[[ -d "$SQL" ]] || { echo "FAIL: missing $SQL"; exit 1; }

# --- 3. at least one migration exists -----------------------------------------
n=$(find "$SQL" -name '*.sql' -type f | wc -l)
[[ "$n" -ge 1 ]] && pass "csi-spl-rdb has $n .sql file(s)" || fail "no .sql files under $SQL"

# --- the real tree ------------------------------------------------------------
hits=$(store_entity_hits "$SQL")
if [[ -z "$hits" ]]; then
  pass "rdb SQL has no product/cart/sku/wp_ store entities"
else
  fail "rdb SQL names a store entity:"
  printf '      %s\n' $hits
fi

# --- control 1: planted store DDL is found ------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bad" "$tmp/ok"
cat >"$tmp/bad/shop.sql" <<'SQL'
CREATE TABLE products (id int);
CREATE TABLE carts (sku text);
CREATE TABLE wp_posts (id int);
SQL
cat >"$tmp/ok/spool.sql" <<'SQL'
-- Forward-only. Applied in filename order. This is production-shaped spool DDL.
-- A key absent = fall back to the global, then the product default (CLE-35099).
CREATE TABLE tenants (tenant_id text PRIMARY KEY);
CREATE TABLE messages (msg_id uuid NOT NULL);
SQL

# control 2b: a real `products` table AND the prose "product default" in one
# file (separate lines): the table is still caught, the prose is not — the
# exemption is anchored to the phrase, not a blanket "product" skip.
mkdir -p "$tmp/mix"
cat >"$tmp/mix/store_and_prose.sql" <<'SQL'
CREATE TABLE products (id int);
-- a key absent falls back to the product default (this line is prose)
SQL

hits=$(store_entity_hits "$tmp/bad")
echo "$hits" | grep -q 'shop.sql' && echo "$hits" | grep -q 'products' && echo "$hits" | grep -q 'sku' && echo "$hits" | grep -q 'wp_posts' \
  && pass "control: planted product/cart/sku/wp_ DDL is caught" \
  || fail "control: planted store DDL not caught: ${hits:-<nothing>}"

# --- control 2: production / filename order / product default are not hits -----
hits=$(store_entity_hits "$tmp/ok")
[[ -z "$hits" ]] && pass "control: production/filename-order/product-default comments are not store entities" \
  || fail "control: false positive on spool-shaped SQL: $hits"

# --- control 2b: the exemption is anchored (a real table is still caught) ------
hits=$(store_entity_hits "$tmp/mix")
{ echo "$hits" | grep -q 'products' && ! echo "$hits" | grep -qi 'product default'; } \
  && pass "control: 'product default' prose is exempt but a products table is still caught" \
  || fail "control: exemption not anchored: ${hits:-<nothing>}"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
