# 02_load_bank_db.ps1 - create the bank database in the local PostgreSQL 16 and load the data.
#
#   .\02_load_bank_db.ps1            # size comes from SEED_PRESET in config.env
#   .\02_load_bank_db.ps1 -Preset tiny
#   .\02_load_bank_db.ps1 -Force     # reload without asking if the bank schema already has data
param(
    [ValidateSet('tiny','small','medium','custom')][string]$Preset,
    [switch]$Force
)
. "$PSScriptRoot\common.ps1"
$cfg = Read-Config
Assert-Docker

if (-not $Preset) { $Preset = $cfg['SEED_PRESET'] }
$customers = switch ($Preset) {
    'tiny'   { 10000 }
    'small'  { 100000 }
    'medium' { 1000000 }
    'custom' { [int]$cfg['SEED_CUSTOMERS'] }
    default  { throw "SEED_PRESET must be tiny, small, medium or custom" }
}
if ($customers -lt 1) { throw "customers must be at least 1 (set SEED_CUSTOMERS)" }
$db = $cfg['PG_DATABASE']
"target: $($cfg['PG_HOST']):$($cfg['PG_PORT'])/$db   preset=$Preset  customers=$customers  (~$($customers * 10) transfers, ~$([math]::Round($customers * 47 / 1e6, 1))M rows total)"

# -- connectivity and prerequisites ------------------------------------------
$ver = Get-Scalar $cfg 'postgres' 'SHOW server_version'
$wal = Get-Scalar $cfg 'postgres' 'SHOW wal_level'
"PostgreSQL $ver, wal_level=$wal"
if ($wal -ne 'logical') { Write-Warning "wal_level is '$wal'. The migration needs 'logical' - run 01_prepare_pg16.ps1 first (loading still works)." }

# -- database ----------------------------------------------------------------
$exists = Get-Scalar $cfg 'postgres' "SELECT 1 FROM pg_database WHERE datname = '$db'"
if ($exists -ne '1') {
    "creating database $db"
    Invoke-Psql $cfg 'postgres' @('-c',"CREATE DATABASE $db")
}

# -- guard against wiping an existing load by accident ----------------------─
$has = Get-Scalar $cfg $db "SELECT COALESCE((SELECT reltuples::bigint FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'bank' AND c.relname = 'customers'), -1)"
if ($has -ne '-1' -and -not $Force) {
    $ans = Read-Host "Schema 'bank' already exists in $db and will be DROPPED and reloaded. Type yes to continue"
    if ($ans -ne 'yes') { "aborted"; return }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
"applying schema.sql ..."
Invoke-Psql $cfg $db @('-q','-f','/work/schema.sql')

"loading seed.sql (this is the long step: $Preset) ..."
Invoke-Psql $cfg $db @('-q','-v',"customers=$customers",'-v','accounts_per_customer=2','-v','txns_per_account=5','-f','/work/seed.sql')

"applying facade.sql ..."
Invoke-Psql $cfg $db @('-q','-f','/work/facade.sql')

"`nrow counts:"
$union = ($BankTables | ForEach-Object { "SELECT '$_' AS tbl, count(*) AS n FROM bank.$_" }) -join ' UNION ALL '
Invoke-Psql $cfg $db @('-c',"SELECT tbl, to_char(n, 'FM999,999,999') AS rows FROM ($union) t ORDER BY n DESC")
$total = Get-Scalar $cfg $db "SELECT to_char(sum(n), 'FM999,999,999') FROM ($union) t"
$size  = Get-Scalar $cfg $db "SELECT pg_size_pretty(pg_database_size('$db'))"
"total rows: $total   database size: $size   elapsed: $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
"Next: 03_start_bank_app.ps1"
