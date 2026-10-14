# 03_start_bank_app.ps1 - start the bank application (and traffic) against the local PostgreSQL 16.
#
#   .\03_start_bank_app.ps1                 # app + traffic simulator (100 requests/second)
#   .\03_start_bank_app.ps1 -NoTraffic      # app only
#   .\03_start_bank_app.ps1 -Rps 300
#   .\03_start_bank_app.ps1 -Stop           # stop app and traffic
param([switch]$NoTraffic, [int]$Rps = 100, [switch]$Stop)
. "$PSScriptRoot\common.ps1"
$cfg = Read-Config
Assert-Docker
Set-AppEnv $cfg (Get-DefaultAppDsn $cfg) 'local-pg16'
$env:TRAFFIC_RPS = "$Rps"

if ($Stop) { Invoke-AppCompose @('down'); return }

New-Item -ItemType Directory -Force -Path (Join-Path $BankApp 'runs\traffic') | Out-Null
"starting the bank app against $($cfg['PG_HOST']):$($cfg['PG_PORT'])/$($cfg['PG_DATABASE']) ..."
Invoke-AppCompose @('up','-d','--build','bankapp')

$ok = $false
for ($i = 0; $i -lt 30 -and -not $ok; $i++) {
    try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8090/healthz' -TimeoutSec 3; $ok = ($r.StatusCode -eq 200) }
    catch { Start-Sleep -Seconds 2 }
}
if (-not $ok) { Invoke-AppCompose @('logs','--tail','40','bankapp'); throw "the bank app did not become healthy" }
"  app is up: http://localhost:8090   (docs: http://localhost:8090/docs)"
"  answering from: $($r.Headers['X-Db-Endpoint'])"

if (-not $NoTraffic) {
    Invoke-AppCompose @('up','-d','banktraffic')
    "  traffic simulator started ($Rps req/s, 80:20 read:write). Watch it: docker logs -f bank-tester-banktraffic-1"
}
"Next: start the migration from the migrator UI (see TESTER_GUIDE.md)."
