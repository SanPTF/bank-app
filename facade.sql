-- bank-app/facade.sql
--
-- The facade the application talks to instead of the base tables. It is what
-- makes a database cutover a routing change rather than an application change:
-- the app is pointed at schema `bank_app` and never sees `bank` directly.
--
-- Every view here is a *simple* view over exactly one base table, so PostgreSQL
-- keeps it auto-updatable: SELECT, INSERT, UPDATE and DELETE all pass through,
-- serial defaults fire on the base table, and RETURNING works. That is enough
-- for a same-database facade.
--
-- When the module moves to its own database, the definition behind these views
-- is what changes (foreign tables / INSTEAD OF triggers / a route table) — the
-- application's SQL does not. That is the framework's `facade.install` /
-- `route.switch` work; this file is the example-level stand-in.
--
-- Load after schema.sql:
--   psql -d source_db -v ON_ERROR_STOP=1 -f facade.sql

CREATE SCHEMA IF NOT EXISTS bank_app;

-- reference data
CREATE OR REPLACE VIEW bank_app.branches          AS SELECT * FROM bank.branches;
CREATE OR REPLACE VIEW bank_app.currencies        AS SELECT * FROM bank.currencies;
CREATE OR REPLACE VIEW bank_app.fx_rates          AS SELECT * FROM bank.fx_rates;

-- customer
CREATE OR REPLACE VIEW bank_app.customers         AS SELECT * FROM bank.customers;
CREATE OR REPLACE VIEW bank_app.addresses         AS SELECT * FROM bank.addresses;
CREATE OR REPLACE VIEW bank_app.contacts          AS SELECT * FROM bank.contacts;
CREATE OR REPLACE VIEW bank_app.kyc_documents     AS SELECT * FROM bank.kyc_documents;
CREATE OR REPLACE VIEW bank_app.consents          AS SELECT * FROM bank.consents;

-- accounts
CREATE OR REPLACE VIEW bank_app.accounts          AS SELECT * FROM bank.accounts;
CREATE OR REPLACE VIEW bank_app.account_balances  AS SELECT * FROM bank.account_balances;
CREATE OR REPLACE VIEW bank_app.account_holds     AS SELECT * FROM bank.account_holds;

-- money movement
CREATE OR REPLACE VIEW bank_app.transfers         AS SELECT * FROM bank.transfers;
CREATE OR REPLACE VIEW bank_app.ledger_entries    AS SELECT * FROM bank.ledger_entries;

-- cards
CREATE OR REPLACE VIEW bank_app.pan_tokens        AS SELECT * FROM bank.pan_tokens;
CREATE OR REPLACE VIEW bank_app.cards             AS SELECT * FROM bank.cards;

-- loans
CREATE OR REPLACE VIEW bank_app.loan_accounts     AS SELECT * FROM bank.loan_accounts;
CREATE OR REPLACE VIEW bank_app.repayments        AS SELECT * FROM bank.repayments;

-- audit
CREATE OR REPLACE VIEW bank_app.access_log        AS SELECT * FROM bank.access_log;
