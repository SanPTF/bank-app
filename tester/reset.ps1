# reset.ps1 - get back to a clean start so a migration can be run again.
#
#   .\reset.ps1 -Slots                 # drop the migrator's replication slots/origins on YOUR PostgreSQL 16
#   .\reset.ps1 -Data                  # drop and reload the bank database (runs 02_load_bank_db.ps1 -Force)
#   .\reset.ps1 -Slots -Data          # both
#
# IMPORTANT: an abandoned replication slot makes PostgreSQL keep WAL on your disk forever. If you stop testing
# without finishing a run, run  .\reset.ps1 -Slots  (it is also safe to run any time).
param([switch]$Slots, [switch]$Data)
. "$PSScriptRoot\common.ps1"
if (-not ($Slots -or $Data)) { "choose at least one of -Slots -Data (see the top of this file)"; return }
$cfg = Read-Config
Assert-Docker

& "$PSScriptRoot\03_start_bank_app.ps1" -Stop

if ($Slots) {
    "dropping replication slots and origins on $($cfg['PG_HOST']):$($cfg['PG_PORT']) ..."
    $sql = @"
SELECT pg_terminate_backend(active_pid) FROM pg_replication_slots WHERE active_pid IS NOT NULL;
SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots;
SELECT pg_replication_origin_drop(roname) FROM pg_replication_origin;
DO `$`$ DECLARE p text; BEGIN FOR p IN SELECT pubname FROM pg_publication LOOP EXECUTE format('DROP PUBLICATION %I', p); END LOOP; END `$`$;
"@
    # the bank database has no publications of its own, so every one found was created by the migrator
    Invoke-Psql $cfg $cfg.PG_DATABASE @('-c',$sql)
    $left = Get-Scalar $cfg $cfg.PG_DATABASE 'SELECT count(*) FROM pg_replication_slots'
    "slots remaining: $left"
}
if ($Data) { & "$PSScriptRoot\02_load_bank_db.ps1" -Force }
