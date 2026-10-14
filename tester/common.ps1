# bank-app/tester/common.ps1 - shared helpers, dot-sourced by the numbered scripts.
$ErrorActionPreference = 'Stop'

$Script:Here      = $PSScriptRoot
$Script:BankApp   = Split-Path $Here -Parent
$Script:AppCompose      = Join-Path $Here 'docker-compose.app.yml'

function Read-Config {
    $path = if ($env:TESTER_CONFIG) { $env:TESTER_CONFIG } else { Join-Path $Here 'config.env' }
    if (-not (Test-Path $path)) { throw "config.env not found in $Here" }
    $cfg = @{}
    foreach ($line in Get-Content $path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $cfg[$t.Substring(0, $i).Trim()] = $v
    }
    foreach ($k in 'PG_HOST','PG_PORT','PG_USER','PG_PASSWORD','PG_DATABASE') {
        if (-not $cfg[$k]) { throw "config.env: $k is empty" }
    }
    if ($cfg['PG_PASSWORD'] -eq 'change-me') { throw "config.env: set PG_PASSWORD to your PostgreSQL password first." }
    if ($cfg['PG_DATABASE'] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "config.env: PG_DATABASE must be a plain identifier" }
    return $cfg
}

function Assert-Docker {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and wait until it says 'Engine running'." }
}

# libpq key/value connection string (no URL-encoding problems with special characters in the password)
function Get-ConnInfo([hashtable]$Cfg, [string]$Db) {
    $pw = $Cfg.PG_PASSWORD.Replace('\', '\\').Replace("'", "\'")
    return "host=$($Cfg.PG_HOST) port=$($Cfg.PG_PORT) dbname=$Db user=$($Cfg.PG_USER) password='$pw'"
}


# Runs psql from a postgres:16 container so the host needs no PostgreSQL client tools.
# bank-app\ is mounted read-only at /work, so -f /work/schema.sql works.
function Invoke-Psql {
    param([hashtable]$Cfg, [string]$Db, [string[]]$PsqlArgs)
    $env:PGPASSWORD = $Cfg.PG_PASSWORD
    $a = @('run','--rm','-i','-e','PGPASSWORD','--add-host','host.docker.internal:host-gateway',
           '-v',"${BankApp}:/work:ro",'postgres:16',
           'psql','-h',$Cfg.PG_HOST,'-p',$Cfg.PG_PORT,'-U',$Cfg.PG_USER,'-d',$Db,'-X','-v','ON_ERROR_STOP=1') + $PsqlArgs
    & docker @a
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE) against $($Cfg.PG_HOST):$($Cfg.PG_PORT)/$Db" }
}

# Single scalar value
function Get-Scalar([hashtable]$Cfg, [string]$Db, [string]$Sql) {
    $out = Invoke-Psql $Cfg $Db @('-A','-t','-c',$Sql)
    $first = $out | Select-Object -First 1
    if ($null -eq $first) { return '' }
    return $first.ToString().Trim()
}



function Invoke-AppCompose([string[]]$ComposeArgs) {
    & docker compose -f $AppCompose @ComposeArgs
    if ($LASTEXITCODE -ne 0) { throw "docker compose failed (exit $LASTEXITCODE)" }
}

function Set-AppEnv([hashtable]$Cfg, [string]$Dsn, [string]$Endpoint) {
    $env:BANK_DSN = $Dsn
    $env:BANK_ENDPOINT = $Endpoint
}

function Get-DefaultAppDsn([hashtable]$Cfg) { Get-ConnInfo $Cfg $Cfg.PG_DATABASE }

$Script:BankTables = 'branches','currencies','fx_rates','customers','addresses','contacts','kyc_documents','consents',
    'accounts','account_balances','account_holds','transfers','ledger_entries','pan_tokens','cards','loan_accounts',
    'repayments','access_log'
