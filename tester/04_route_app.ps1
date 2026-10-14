# 04_route_app.ps1 - point the running bank app at a different database (the "cutover" from the app's side).
# Only the app container is restarted; the application code does not change.
#
#   .\04_route_app.ps1 -To source                       # back to your PostgreSQL 16
#   .\04_route_app.ps1 -To proxy -Alias <alias>         # through the migrator's proxy (alias is shown in the console, Cutover page)
#   .\04_route_app.ps1 -To target                       # straight to ShaktiDB after the migration is closed
#
# Find the alias names with:  .\05_check.ps1 -Aliases
param(
    [Parameter(Mandatory)][ValidateSet('source','proxy','target')][string]$To,
    [string]$Alias
)
. "$PSScriptRoot\common.ps1"
$cfg = Read-Config
Assert-Docker

switch ($To) {
    'source' { $dsn = Get-DefaultAppDsn $cfg; $label = 'local-pg16' }
    'target' { $dsn = "host=host.docker.internal port=55442 dbname=target_db user=postgres password=secret"; $label = 'shaktidb-target' }
    'proxy'  {
        if (-not $Alias) { throw "-To proxy needs -Alias <name>. List them with .\05_check.ps1 -Aliases" }
        if ($Alias -notmatch '^[A-Za-z0-9_]+$') { throw "alias contains unexpected characters" }
        $dsn = "host=host.docker.internal port=16432 dbname=$Alias user=postgres"; $label = "proxy:$Alias"
    }
}
Set-AppEnv $cfg $dsn $label
Invoke-AppCompose @('up','-d','--force-recreate','--no-deps','bankapp')
Start-Sleep -Seconds 5
$r = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8090/healthz' -TimeoutSec 10
"app now answering from: $($r.Headers['X-Db-Endpoint'])  (HTTP $($r.StatusCode))"
