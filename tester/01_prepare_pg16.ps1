# 01_prepare_pg16.ps1 - make the local PostgreSQL 16 usable as a migration source.
#
# Run from an ADMINISTRATOR PowerShell. It:
#   - turns on logical replication (wal_level=logical, replication slots, WAL senders)
#   - lets Docker containers connect (listen_addresses, pg_hba.conf, Windows Firewall for the port)
#   - restarts the PostgreSQL service (the wal_level change needs a restart)
# Both config files are backed up first (*.bankapp.bak) and the lines it adds are marked, so re-running is safe.
#
#   .\01_prepare_pg16.ps1              # normal
#   .\01_prepare_pg16.ps1 -NoRestart   # edit only; restart the service yourself
param([switch]$NoRestart)
. "$PSScriptRoot\common.ps1"
$cfg = Read-Config

$id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an Administrator PowerShell (it edits PostgreSQL's config files and restarts the service)."
}

# -- find the data directory ------------------------------------------------─
$dataDir = $cfg['PG_DATA_DIR']
if (-not $dataDir) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($cfg['PG_SERVICE'])'"
    if (-not $svc) { throw "Service '$($cfg['PG_SERVICE'])' not found. Fix PG_SERVICE in config.env (see services.msc), or set PG_DATA_DIR." }
    if ($svc.PathName -match '-D\s+"([^"]+)"') { $dataDir = $Matches[1] }
    elseif ($svc.PathName -match '-D\s+(\S+)') { $dataDir = $Matches[1] }
    else { throw "Could not read the data directory from the service. Set PG_DATA_DIR in config.env." }
}
$conf = Join-Path $dataDir 'postgresql.conf'
$hba  = Join-Path $dataDir 'pg_hba.conf'
foreach ($f in $conf, $hba) { if (-not (Test-Path $f)) { throw "Not found: $f" } }
"data directory: $dataDir"

$begin = '# >>> bank-app migration test (managed by 01_prepare_pg16.ps1) >>>'
$end   = '# <<< bank-app migration test <<<'
$utf8  = New-Object System.Text.UTF8Encoding($false)

function Set-Block([string]$Path, [string]$Body) {
    $bak = "$Path.bankapp.bak"
    if (-not (Test-Path $bak)) { Copy-Item $Path $bak; "  backup: $bak" }
    $text = [IO.File]::ReadAllText($Path)
    $pattern = '(?s)\r?\n?' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?'
    $text = [regex]::Replace($text, $pattern, "`n")
    $text = $text.TrimEnd() + "`n`n" + $begin + "`n" + $Body.TrimEnd() + "`n" + $end + "`n"
    [IO.File]::WriteAllText($Path, $text, $utf8)
}

Set-Block $conf @"
listen_addresses = '*'
wal_level = logical
max_replication_slots = 20
max_wal_senders = 20
"@
"updated $conf"

$cidr = $cfg['PG_ALLOW_CIDR']; if (-not $cidr) { $cidr = '0.0.0.0/0' }
Set-Block $hba @"
host    all            all    $cidr    scram-sha-256
host    replication    all    $cidr    scram-sha-256
"@
"updated $hba   (allowing $cidr)"

# -- firewall ----------------------------------------------------------------
$rule = 'PostgreSQL bank-app migration test'
if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort ([int]$cfg['PG_PORT']) -Action Allow -Profile Any | Out-Null
    "firewall rule added: TCP $($cfg['PG_PORT'])"
} else { "firewall rule already present" }

# -- restart and verify ------------------------------------------------------
if ($NoRestart) {
    "Restart the '$($cfg['PG_SERVICE'])' service yourself, then run 02_load_bank_db.ps1."
    return
}
"restarting service $($cfg['PG_SERVICE']) ..."
Restart-Service -Name $cfg['PG_SERVICE'] -Force
Start-Sleep -Seconds 4

Assert-Docker
$ver = Get-Scalar $cfg 'postgres' 'SHOW server_version'
$wal = Get-Scalar $cfg 'postgres' 'SHOW wal_level'
$sup = Get-Scalar $cfg 'postgres' "SELECT rolsuper FROM pg_roles WHERE rolname = current_user"
"PostgreSQL $ver   wal_level=$wal   $($cfg['PG_USER']) superuser=$sup"
if (-not $ver.StartsWith('16')) { Write-Warning "This is PostgreSQL $ver, not 16. The migration framework is built and tested against 16." }
if ($wal -ne 'logical') { throw "wal_level is '$wal', expected 'logical'. Check that the restart happened and no later line in postgresql.conf overrides it." }
if ($sup -ne 't') { Write-Warning "$($cfg['PG_USER']) is not a superuser. The migrator needs a superuser (or a role with REPLICATION plus rights on the bank tables)." }
"OK - the containers can reach PostgreSQL. Next: 02_load_bank_db.ps1"
