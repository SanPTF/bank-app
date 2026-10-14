-- bank-app/seed.sql
--
-- Synthetic data for the bank schema. Scale it with psql variables:
--
--   psql -d source_db -v ON_ERROR_STOP=1 \
--        -v customers=1000000 -v accounts_per_customer=2 -v txns_per_account=5 \
--        -f seed.sql
--
-- Defaults to a tiny dataset if you pass nothing. Presets:
--   tiny    customers=10000      accounts_per_customer=2  txns_per_account=5    (~100k transfers)
--   small   customers=100000     2                        5                      (~1M transfers)
--   medium  customers=1000000    2                        5                      (~10M transfers)
--   large   customers=5000000    2                        5                      (~50M transfers)
--   full    customers=10000000   2                        5                      (~100M transfers)
--
-- Every value is derived from the row index, so the seed is reproducible and
-- the whole-table fingerprint is stable across runs (the migrator's tests rely on that).

\if :{?customers}
\else
\set customers 10000
\endif
\if :{?accounts_per_customer}
\else
\set accounts_per_customer 2
\endif
\if :{?txns_per_account}
\else
\set txns_per_account 5
\endif

\timing on
SET synchronous_commit = off;

-- ── reference data ──────────────────────────────────────────────────────────
INSERT INTO bank.branches (id, code, name, country)
SELECT i, 'B' || lpad(i::text, 5, '0'), 'Branch ' || i, (ARRAY['GB','US','DE','IN'])[1 + i % 4]
FROM generate_series(1, 50) i;

INSERT INTO bank.currencies (code, name, minor_unit) VALUES
  ('GBP','Pound Sterling',2),('USD','US Dollar',2),('EUR','Euro',2),
  ('INR','Indian Rupee',2),('JPY','Yen',0);

INSERT INTO bank.fx_rates (base, quote, rate, as_of)
SELECT (ARRAY['GBP','USD','EUR'])[1 + i % 3], (ARRAY['USD','EUR','GBP'])[1 + i % 3],
       (1 + (i % 500) / 100.0)::numeric(18,8), now() - (i || ' minutes')::interval
FROM generate_series(1, 2000) i;

-- ── customer (PII) ──────────────────────────────────────────────────────────
INSERT INTO bank.customers (full_name, national_id, email, phone, dob, tier, created_at)
SELECT 'Customer ' || i,
       'NID' || lpad(((i::bigint * 7919) % 100000000)::text, 8, '0'),
       'user' || i || '@example.test',
       '+44' || lpad(((i::bigint * 104729) % 10000000000)::text, 10, '0'),
       date '1960-01-01' + (i % 14000),
       (ARRAY['standard','premium','private'])[1 + i % 3],
       now() - ((i % 3650) || ' days')::interval
FROM generate_series(1, :customers) i;

INSERT INTO bank.addresses (customer_id, line1, city, country, postcode, is_primary)
SELECT c, (1 + g) || ' High Street',
       (ARRAY['London','Berlin','Paris','Mumbai'])[1 + c % 4],
       (ARRAY['GB','DE','FR','IN'])[1 + c % 4],
       lpad(((c::bigint * 13) % 100000)::text, 5, '0'), g = 0
FROM generate_series(1, :customers) c, generate_series(0, 1) g;

INSERT INTO bank.contacts (customer_id, kind, value, verified)
SELECT c, (ARRAY['email','phone'])[1 + k % 2], 'contact ' || c || '-' || k, (c % 3) <> 0
FROM generate_series(1, :customers) c, generate_series(0, 1) k;

INSERT INTO bank.kyc_documents (customer_id, doc_type, payload, uploaded_at)
SELECT c, (ARRAY['passport','licence'])[1 + c % 2], decode(md5(c::text), 'hex'),
       now() - ((c % 1000) || ' days')::interval
FROM generate_series(1, :customers) c;

INSERT INTO bank.consents (customer_id, purpose, granted, at)
SELECT c, (ARRAY['marketing','analytics'])[1 + k % 2], (c + k) % 4 <> 0,
       now() - ((c % 500) || ' days')::interval
FROM generate_series(1, :customers) c, generate_series(0, 1) k;

-- ── accounts ────────────────────────────────────────────────────────────────
INSERT INTO bank.accounts (customer_id, branch_id, currency, kind, opened_at, status)
SELECT 1 + ((i - 1) / :accounts_per_customer),
       1 + (i % 50),
       (ARRAY['GBP','USD','EUR','INR'])[1 + i % 4],
       (ARRAY['current','savings','credit'])[1 + i % 3],
       now() - ((i % 2000) || ' days')::interval,
       (ARRAY['open','open','open','dormant'])[1 + i % 4]
FROM generate_series(1, :customers * :accounts_per_customer) i;

INSERT INTO bank.account_balances (account_id, available, ledger)
SELECT id, ((id::bigint * 137) % 5000000) / 100.0, ((id::bigint * 137) % 5000000) / 100.0
FROM bank.accounts;

INSERT INTO bank.account_holds (account_id, amount, reason, expires_at)
SELECT id, (id % 5000) / 100.0, 'preauth', now() + interval '7 days'
FROM bank.accounts WHERE id % 10 = 0;

-- ── money movement ──────────────────────────────────────────────────────────
INSERT INTO bank.transfers (src_account, dst_account, amount, currency, status, created_at)
SELECT 1 + (i % (:customers * :accounts_per_customer)),
       1 + ((i + 7) % (:customers * :accounts_per_customer)),
       ((i % 500000) + 1) / 100.0,
       (ARRAY['GBP','USD','EUR'])[1 + i % 3],
       (ARRAY['settled','settled','settled','pending','failed'])[1 + i % 5],
       now() - ((i % 180) || ' days')::interval - ((i % 86400) || ' seconds')::interval
FROM generate_series(1, :customers * :accounts_per_customer * :txns_per_account) i;

INSERT INTO bank.ledger_entries (transfer_id, account_id, direction, amount, posted_at)
SELECT id, src_account, 'D', amount, created_at FROM bank.transfers;
INSERT INTO bank.ledger_entries (transfer_id, account_id, direction, amount, posted_at)
SELECT id, dst_account, 'C', amount, created_at FROM bank.transfers;

-- ── cards (PCI) ─────────────────────────────────────────────────────────────
INSERT INTO bank.pan_tokens (token, last4, bin)
SELECT 'tok_' || lpad(id::text, 12, '0'), lpad((id % 10000)::text, 4, '0'),
       '4000' || lpad((id % 100)::text, 2, '0')
FROM bank.accounts WHERE id % 2 = 0;

INSERT INTO bank.cards (customer_id, account_id, pan_token, network, expiry, status)
SELECT a.customer_id, a.id, 'tok_' || lpad(a.id::text, 12, '0'),
       (ARRAY['visa','mastercard'])[1 + a.id % 2],
       date '2026-01-01' + (a.id % 1000)::int,
       (ARRAY['active','active','blocked'])[1 + a.id % 3]
FROM bank.accounts a WHERE a.id % 2 = 0;

-- ── loans ───────────────────────────────────────────────────────────────────
INSERT INTO bank.loan_accounts (customer_id, principal, rate, term_months, opened_at)
SELECT c, ((c % 100000) + 1000)::numeric(18,2), (2 + (c % 500) / 100.0)::numeric(6,4),
       (ARRAY[12,24,60,120])[1 + c % 4],
       now() - ((c % 1000) || ' days')::interval
FROM generate_series(1, :customers) c WHERE c % 20 = 0;

INSERT INTO bank.repayments (loan_id, due, amount, paid_at)
SELECT l.id, date '2025-01-01' + (m * 30), (l.principal / l.term_months)::numeric(18,2),
       CASE WHEN m <= 3 THEN now() - ((m * 30) || ' days')::interval ELSE NULL END
FROM bank.loan_accounts l, generate_series(1, 6) m;

-- ── audit (append-only) ─────────────────────────────────────────────────────
INSERT INTO bank.access_log (actor, action, entity, entity_id, at)
SELECT 'user' || (i % 100000), (ARRAY['login','view','transfer','update'])[1 + i % 4],
       (ARRAY['customer','account','transfer'])[1 + i % 3], 1 + (i % :customers),
       now() - ((i % 30) || ' days')::interval - ((i % 86400) || ' seconds')::interval
FROM generate_series(1, :customers * 2) i;

ANALYZE;
\timing off
