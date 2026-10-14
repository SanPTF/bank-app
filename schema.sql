-- bank-app/schema.sql
--
-- Synthetic bank schema for migration testing (source side, PostgreSQL 16).
-- Every table has a primary key: the migrator refuses a table without one,
-- because it needs a key to apply changes idempotently and to chunk the bulk load.
-- The cross-schema foreign keys are intentional: they are the "seams" the
-- strangler-fig coupling analysis (pass E) looks for.
--
-- Load it first, then seed.sql:
--   psql -d source_db -v ON_ERROR_STOP=1 -f schema.sql

DROP SCHEMA IF EXISTS bank CASCADE;
CREATE SCHEMA bank;

-- ── reference data (small, read-mostly) ─────────────────────────────────────
CREATE TABLE bank.branches (
  id      int PRIMARY KEY,
  code    text UNIQUE NOT NULL,
  name    text NOT NULL,
  country char(2) NOT NULL
);
CREATE TABLE bank.currencies (
  code       char(3) PRIMARY KEY,
  name       text NOT NULL,
  minor_unit smallint NOT NULL
);
CREATE TABLE bank.fx_rates (
  id    bigserial PRIMARY KEY,
  base  char(3) NOT NULL,
  quote char(3) NOT NULL,
  rate  numeric(18,8) NOT NULL,
  as_of timestamptz NOT NULL
);

-- ── customer (PII) ──────────────────────────────────────────────────────────
CREATE TABLE bank.customers (
  id          bigserial PRIMARY KEY,
  full_name   text NOT NULL,
  national_id text NOT NULL,
  email       text,
  phone       text,
  dob         date NOT NULL,
  tier        text NOT NULL DEFAULT 'standard',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bank.addresses (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  line1       text NOT NULL,
  city        text NOT NULL,
  country     char(2) NOT NULL,
  postcode    text,
  is_primary  boolean NOT NULL DEFAULT false
);
CREATE TABLE bank.contacts (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  kind        text NOT NULL,
  value       text NOT NULL,
  verified    boolean NOT NULL DEFAULT false
);
CREATE TABLE bank.kyc_documents (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  doc_type    text NOT NULL,
  payload     bytea NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bank.consents (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  purpose     text NOT NULL,
  granted     boolean NOT NULL,
  at          timestamptz NOT NULL DEFAULT now()
);

-- ── accounts ────────────────────────────────────────────────────────────────
CREATE TABLE bank.accounts (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  branch_id   int NOT NULL REFERENCES bank.branches(id),
  currency    char(3) NOT NULL REFERENCES bank.currencies(code),
  kind        text NOT NULL,
  opened_at   timestamptz NOT NULL DEFAULT now(),
  status      text NOT NULL DEFAULT 'open'
);
CREATE TABLE bank.account_balances (
  account_id bigint PRIMARY KEY REFERENCES bank.accounts(id),
  available  numeric(18,2) NOT NULL DEFAULT 0,
  ledger     numeric(18,2) NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bank.account_holds (
  id         bigserial PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES bank.accounts(id),
  amount     numeric(18,2) NOT NULL,
  reason     text NOT NULL,
  expires_at timestamptz
);

-- ── money movement (mutates in the same transaction as accounts) ────────────
CREATE TABLE bank.transfers (
  id          bigserial PRIMARY KEY,
  src_account bigint NOT NULL REFERENCES bank.accounts(id),
  dst_account bigint NOT NULL REFERENCES bank.accounts(id),
  amount      numeric(18,2) NOT NULL CHECK (amount > 0),
  currency    char(3) NOT NULL,
  status      text NOT NULL DEFAULT 'settled',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bank.ledger_entries (
  id          bigserial PRIMARY KEY,
  transfer_id bigint REFERENCES bank.transfers(id),
  account_id  bigint NOT NULL REFERENCES bank.accounts(id),
  direction   char(1) NOT NULL CHECK (direction IN ('D', 'C')),
  amount      numeric(18,2) NOT NULL,
  posted_at   timestamptz NOT NULL DEFAULT now()
);

-- ── cards (PCI: tokens only, never a real PAN) ──────────────────────────────
CREATE TABLE bank.pan_tokens (
  token      text PRIMARY KEY,
  last4      char(4) NOT NULL,
  bin        char(6) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bank.cards (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  account_id  bigint NOT NULL REFERENCES bank.accounts(id),
  pan_token   text NOT NULL,
  network     text NOT NULL,
  expiry      date NOT NULL,
  status      text NOT NULL DEFAULT 'active'
);

-- ── loans ───────────────────────────────────────────────────────────────────
CREATE TABLE bank.loan_accounts (
  id          bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES bank.customers(id),
  principal   numeric(18,2) NOT NULL,
  rate        numeric(6,4) NOT NULL,
  term_months int NOT NULL,
  opened_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bank.repayments (
  id      bigserial PRIMARY KEY,
  loan_id bigint NOT NULL REFERENCES bank.loan_accounts(id),
  due     date NOT NULL,
  amount  numeric(18,2) NOT NULL,
  paid_at timestamptz
);

-- ── audit (append-only) ─────────────────────────────────────────────────────
CREATE TABLE bank.access_log (
  id        bigserial PRIMARY KEY,
  actor     text NOT NULL,
  action    text NOT NULL,
  entity    text NOT NULL,
  entity_id bigint NOT NULL,
  at        timestamptz NOT NULL DEFAULT now()
);

-- ── indexes for the application's access patterns ───────────────────────────
-- Foreign keys do not get an index automatically. Without these, customer and
-- account lookups sequentially scan millions of rows and the app times out.
CREATE INDEX bank_accounts_customer_idx      ON bank.accounts (customer_id);
CREATE INDEX bank_addresses_customer_idx     ON bank.addresses (customer_id);
CREATE INDEX bank_cards_customer_idx         ON bank.cards (customer_id);
CREATE INDEX bank_loans_customer_idx         ON bank.loan_accounts (customer_id);
CREATE INDEX bank_ledger_account_idx         ON bank.ledger_entries (account_id, id DESC);
CREATE INDEX bank_contacts_customer_idx      ON bank.contacts (customer_id);
