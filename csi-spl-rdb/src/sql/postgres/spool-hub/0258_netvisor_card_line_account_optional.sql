-- 0258_netvisor_card_line_account_optional.sql - a card cost line may carry
-- no bookkeeping account (spec 125 v0.1 section 4, build row B5 fix,
-- SPL-4742; owner HUM-10, topic fc0119cd). Forward-only, idempotent: a second
-- apply changes nothing.
--
-- rdb 0255 required netvisor_card_cost_lines.account_number to be 1-12
-- digits. A credit-card e-invoice line (route credit_einvoice, B3) is read
-- from the purchase invoice, which names no account, so the main-box sync
-- (B6) had to drop every such line. The column stays NOT NULL, like the
-- other optional text columns of the table (vendor, account_name,
-- dimension): '' now means "no account", the default, and a value given is
-- still 1-12 digits. RLS is untouched (0255's tenant_scope, owner_scope and
-- netvisor_ingest policies stay as they are).
--
-- Live-data safety: a default and a wider check rewrite no row; the new
-- check runs once over the table (every existing row already passes it),
-- under the lock this file already holds. DEPLOY ORDER: wf 20 applies this
-- before the hub that files '' rolls; the old hub never writes ''.

SET LOCAL lock_timeout = '5s';

ALTER TABLE netvisor_card_cost_lines ALTER COLUMN account_number SET DEFAULT '';

ALTER TABLE netvisor_card_cost_lines DROP CONSTRAINT IF EXISTS netvisor_card_cost_lines_account_number_check;
ALTER TABLE netvisor_card_cost_lines ADD CONSTRAINT netvisor_card_cost_lines_account_number_check
    CHECK (account_number ~ '^([0-9]{1,12})?$');
