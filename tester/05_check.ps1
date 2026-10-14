# 05_check.ps1 - compare the source (your PostgreSQL 16) with the target (ShaktiDB), table by table.
# Run it after the bulk copy / steady sync. While the traffic simulator is running, counts of the busy tables
# (transfers, ledger_entries, access_log, account_balances) can differ by a few rows in flight; stop the
# traffic (.\03_start_bank_app.ps1 -Stop) for an exact comparison.
#
#   .\05_check.ps1            # row counts and a money checksum, source vs target
#   .\05_check.ps1 -Aliases   # list the proxy aliases the migrator has created
param([switch]$Aliases)
. "$PSScriptRoot\common.ps1"
$cfg = Read-Config
Assert-Docker

if ($Aliases) {
    $env:PGPASSWORD = ''
    & docker run --rm --add-host host.docker.internal:host-gateway postgres:16 `
        psql -h host.docker.internal -p 16432 -U pgbouncer -d pgbouncer -X -c 'SHOW DATABASES'
    return
}

function Query-Counts([string]$Mode) {
    $sql = ($BankTables | ForEach-Object { "SELECT '$_', count(*) FROM bank.$_" }) -join ' UNION ALL '
    $sql += " UNION ALL SELECT 'SUM(account_balances.ledger)', COALESCE(sum(ledger), 0)::bigint FROM bank.account_balances"
    $a = @('-A','-t','-F','|','-c',$sql)
    if ($Mode -eq 'source') { $lines = Invoke-Psql $cfg $cfg.PG_DATABASE $a }
    else {
        $env:PGPASSWORD = 'secret'
        $lines = & docker run --rm -e PGPASSWORD --add-host host.docker.internal:host-gateway postgres:16 `
            psql -h host.docker.internal -p 55442 -U postgres -d target_db -X -v ON_ERROR_STOP=1 @a
        if ($LASTEXITCODE -ne 0) { throw "could not query the target (ShaktiDB, port 55442). Is the migrator (ShaktiDB target) running?" }
    }
    $h = [ordered]@{}
    foreach ($l in $lines) { if ($l -match '^(.+)\|(-?\d+)$') { $h[$Matches[1]] = [int64]$Matches[2] } }
    return $h
}

$src = Query-Counts 'source'
$tgt = Query-Counts 'target'
$bad = 0
$rows = foreach ($k in $src.Keys) {
    $t = if ($tgt.Contains($k)) { $tgt[$k] } else { $null }
    $m = ($t -eq $src[$k]); if (-not $m) { $bad++ }
    [pscustomobject]@{ table = $k; source = $src[$k]; target = $t; match = $(if ($m) { 'yes' } else { 'NO' }) }
}
$rows | Format-Table -AutoSize
if ($bad -eq 0) { "all $($src.Count) checks match" } else { "$bad of $($src.Count) checks differ" ; exit 1 }
