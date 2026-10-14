# Bank migration test: tester guide

You will load a bank database into **your own PostgreSQL 16** and run a bank application against it. You then run the
migration to **ShaktiDB 18** from the migrator's UI while the application keeps serving requests.

```
 your PC
  ├─ PostgreSQL 16  (port 5432)   bank_db: the data lives here, the app reads/writes it, the migrator copies from it
  ├─ Docker: bank app (8090) + traffic simulator   <- requests go to PostgreSQL 16, later to ShaktiDB via the proxy
  └─ the migrator (UI at http://localhost:8765)    <- started and operated by you, not by these scripts
```

These scripts do **not** start or configure the migrator.

## What you need
- Windows with **Docker Desktop** running.
- **PostgreSQL 16** installed as a Windows service, and its superuser password.
- About **15 GB free disk** for the 10M-transfer data set (about 47M rows in 18 tables), and a PowerShell window.
- The migrator running, with its **source** set to your PostgreSQL 16 (see step 4).

## 0. Configure (the only file you edit)
Open `config.env` and set `PG_PASSWORD` (and `PG_USER` if it is not `postgres`). Check `PG_SERVICE` against the service
name in `services.msc`. `SEED_PRESET=medium` is the 10M-transfer data set; use `tiny` for a quick first try.

If PowerShell refuses to run scripts: `Set-ExecutionPolicy -Scope Process Bypass`.

## 1. Prepare PostgreSQL 16 (Administrator PowerShell, once)
```
.\01_prepare_pg16.ps1
```
Turns on logical replication, lets Docker connect, opens the firewall port and **restarts the PostgreSQL service**
(anything else using it is interrupted for a few seconds). Your config files are backed up as `*.bankapp.bak`.

## 2. Load the bank database
```
.\02_load_bank_db.ps1
```
Creates `bank_db`, applies the schema, loads the data and prints row counts. The 10M-transfer load takes roughly
30 to 60 minutes. Load it once; to repeat a migration from the same data you do not need to reload.

## 3. Start the bank app and traffic
```
.\03_start_bank_app.ps1
```
App: <http://localhost:8090/docs>. Every response has an `X-Db-Endpoint` header saying which database answered.
`-NoTraffic` starts the app alone; `-Rps 300` raises the load. Traffic log: `docker logs -f bank-tester-banktraffic-1`;
a summary is written to `..\runs\traffic\` when it stops.

## 4. Run the migration from the UI
The migrator's source must be your PostgreSQL 16, database `bank_db` (schema `bank`). If you operate the migrator
from Docker, it reaches your PC at `host.docker.internal:5432`, with the user and password from `config.env`:
`postgresql://<user>:<password>@host.docker.internal:5432/bank_db` (percent-encode special characters in the password).
Use decoder **`pgoutput`**, then follow the gates in the UI.

## 5. Move the app to the new database
The app is moved by repointing it; its code does not change.
```
.\05_check.ps1 -Aliases                              # lists the proxy aliases the migrator created
.\04_route_app.ps1 -To proxy -Alias <alias>          # app now talks to ShaktiDB through the proxy (port 16432)
.\04_route_app.ps1 -To source                        # roll back to PostgreSQL 16
.\04_route_app.ps1 -To target                        # straight to ShaktiDB (port 55442) after the migration is closed
```
`04_route_app.ps1 -To target` and `05_check.ps1` assume the default target `postgres/secret@localhost:55442/target_db`.
Compare the two databases at any point (stop traffic first for an exact result): `.\05_check.ps1`.

## 6. Logs to keep for the report
- App: `docker logs bank-tester-bankapp-1 > app.log`
- Migrator: its container logs (`docker logs <container> > file`) and the UI's **Audit log** page.

## Reset and clean up
```
.\reset.ps1 -Slots      # ALWAYS do this if you stop mid-run: an abandoned replication slot fills your disk with WAL
.\reset.ps1 -Data       # reload the bank data
.\03_start_bank_app.ps1 -Stop
```

## Troubleshooting
| Symptom | Likely cause |
|---|---|
| `Docker is not running` | start Docker Desktop and wait for "Engine running" |
| connection refused / timeout | run `01_prepare_pg16.ps1`; check the service is running, `PG_PASSWORD`, the firewall, and that nothing else uses port 5432 |
| `password authentication failed` | wrong `PG_USER` / `PG_PASSWORD` in `config.env` |
| migrator preflight says wal_level is not logical | the restart in step 1 did not happen, or a later line in `postgresql.conf` overrides it |
| port 8090 already in use | something else holds the port; stop it |
| disk filling during a long pause | an active slot is retaining WAL; finish the run or `reset.ps1 -Slots` |
