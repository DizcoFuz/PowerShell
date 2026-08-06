# Runbook — SQL Server 2022 Standard Edition, Write-Intensive Build

**Target:** Windows Server 2022, SQL Server 2022 Standard, OLTP/ingest workload dominated by INSERT/UPDATE/DELETE.
**Patch baseline at time of writing:** CU26 (KB5093420), build 16.0.4265.3 — always verify the current CU before you build.
**Assumed deployment:** VMware vSphere VM. Bare-metal notes called out where they differ.

---

## 0. Read this first — Standard Edition reality check

Most "high performance SQL Server" guidance silently assumes Enterprise. These caps shape every decision below.

| Capability | Standard Edition 2022 |
|---|---|
| Buffer pool memory | **128 GB max per instance** |
| Compute | Lesser of **4 sockets or 24 cores** |
| Columnstore segment cache | 32 GB (on top of buffer pool) |
| In-Memory OLTP data | 32 GB **per database** (on top of buffer pool) |
| Online index rebuild | ❌ Enterprise only — all rebuilds take a schema-mod lock |
| Resumable index operations | ❌ Enterprise only |
| Resource Governor | ❌ Enterprise only |
| Partitioning, data compression, TDE | ✅ Available |
| Accelerated Database Recovery (ADR) | ✅ Available |
| Delayed durability | ✅ Available |
| Availability Groups | **Basic AG only** — 2 replicas, 1 DB per AG, no readable secondary |
| Backup compression | ✅ Available |

**Sizing consequence:** do not spec more than ~160 GB RAM for a Standard instance unless you're deliberately using columnstore or In-Memory OLTP. Anything beyond `128 GB + 32 GB + (32 GB × IMOLTP DBs)` is stranded.

**Maintenance consequence:** no online rebuild means your index maintenance window is a hard architectural constraint. Plan `REORGANIZE`-first strategies and partition-level maintenance from day one.

---

## 1. Pre-install — hardware and storage design

The write path is: log buffer → **transaction log write (synchronous, commit blocks on it)** → later, checkpoint flushes dirty data pages. Log write latency is the single hard ceiling on commit throughput. Design for it first.

### 1.1 Storage layout

| Volume | Contents | Format | Target latency | Notes |
|---|---|---|---|---|
| C: | OS + SQL binaries | 4K NTFS default | — | |
| D: | User DB data files (.mdf/.ndf) | **64K NTFS** | < 10 ms r/w | RAID 10 or NVMe. Avoid RAID 5/6. |
| L: | User DB log files (.ldf) | **64K NTFS** | **< 2 ms write, ideally < 1 ms** | Dedicated spindles/namespace. Never shared with data. |
| T: | tempdb data + log | **64K NTFS** | < 5 ms | Local NVMe if standalone. See FCI caveat below. |
| B: | Backups | 64K NTFS | — | Separate fault domain from data. |

```powershell
# Verify allocation unit size on every SQL volume
Get-CimInstance -ClassName Win32_Volume |
  Where-Object { $_.DriveLetter -in 'D:','L:','T:','B:' } |
  Select-Object DriveLetter, Label, BlockSize, @{n='CapacityGB';e={[math]::Round($_.Capacity/1GB,1)}}
```

**Log volume rules:**
- Parity RAID is disqualifying for a write-heavy log. Read-modify-write on every commit is a latency tax you cannot tune away.
- If using a SAN with a battery/flash-backed write cache, confirm the log LUN is in **write-back** mode and the BBU is healthy. A degraded BBU silently drops you to write-through and your commit latency will 5–10x.
- One log file per database. A second log file adds zero throughput — the log is written sequentially — and only complicates recovery.

**tempdb on local NVMe:** great for a standalone instance. If you later build an FCI, tempdb-on-local-disk is supported but the path must exist on every node. Decide now.

### 1.2 BIOS / firmware

| Setting | Value |
|---|---|
| Power profile | Maximum Performance (or "OS Control" + Windows High Performance) |
| C-States / C1E | **Disabled** |
| Turbo Boost | Enabled |
| Hyper-Threading | Enabled |
| NUMA / Node Interleaving | **Node interleaving disabled** (i.e. NUMA exposed) |
| Memory speed | Max supported, balanced DIMM population across channels |

### 1.3 VMware configuration (if virtualized)

- **vCPU:** ≤ physical cores per socket, presented as 1 core per socket unless you exceed a physical NUMA node. Never straddle NUMA nodes without deliberate vNUMA sizing. Remember the 24-core Standard cap — do not license-waste.
- **Memory:** **reserve 100% of guest memory.** This is mandatory if you enable Lock Pages in Memory, and it eliminates ballooning/swapping under host pressure.
- **Storage controllers:** VMware **Paravirtual (PVSCSI)**, and use *separate controllers* per workload class — e.g. SCSI 0 = OS, SCSI 1 = data, SCSI 2 = log, SCSI 3 = tempdb. This gives independent queues.
- **VMDK provisioning:** eager-zeroed thick, or thin on an all-flash array with VAAI block-zero support.
- **Disks:** one VMDK per volume, no shared VMDKs. Consider raising PVSCSI queue depth (`RequestRingPages=32`, `MaxQueueDepth=254`) for high-IOPS log/data.
- **Advanced:** `disk.EnableUUID = TRUE`. VMXNET3 NIC. **No snapshots on a production SQL VM** — snapshot delta growth on a write-heavy log will destroy latency and eventually stun the VM.
- **Latency Sensitivity = High** only if you fully reserve CPU and memory; otherwise leave Normal.
- Confirm no CPU overcommit on the host, and no Storage vMotion during business hours.

---

## 2. Windows Server preparation

Run before SQL setup.

### 2.1 Power plan

```powershell
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c   # High performance
powercfg /getactivescheme
```

### 2.2 Service accounts

Use **gMSAs** where AD allows. Separate accounts for Database Engine and SQL Agent. Do not use built-in virtual accounts if you need Lock Pages in Memory (you need a real principal to grant the right to).

```powershell
# Example gMSA creation (run on a DC or with RSAT)
New-ADServiceAccount -Name gmsa-sql-eng -DNSHostName gmsa-sql-eng.corp.local `
  -PrincipalsAllowedToRetrieveManagedPassword 'SQLSERVERS$'
# On the SQL host:
Install-ADServiceAccount -Identity gmsa-sql-eng
```

### 2.3 User Rights Assignment

Grant to the **Database Engine service account**:

| Right | Constant | Why |
|---|---|---|
| Perform volume maintenance tasks | `SeManageVolumePrivilege` | Instant File Initialization — data file create/grow/restore skips zeroing |
| Lock pages in memory | `SeLockMemoryPrivilege` | Prevents the working set being trimmed under OS memory pressure |

SQL 2022 setup can grant IFI for you (`/SQLSVCINSTANTFILEINIT="True"`). Lock Pages in Memory must be granted manually via `secpol.msc` → Local Policies → User Rights Assignment, or by GPO.

> **IFI does not apply to the transaction log** in general — log growth is always zero-written. SQL Server 2022 relaxed this for log growth events **up to 64 MB only**. This drives the log sizing strategy in §5.

### 2.4 Antivirus exclusions

Exclude by path *and* process. Get this in writing from your security team; AV scanning of an .ldf is a classic mystery-latency source.

- Extensions: `.mdf`, `.ndf`, `.ldf`, `.bak`, `.trn`, `.dif`
- Directories: all data/log/tempdb/backup volumes, `%ProgramFiles%\Microsoft SQL Server\`, FILESTREAM containers
- Processes: `sqlservr.exe`, `sqlagent.exe`, `sqlwriter.exe`, `sqlceip.exe`

### 2.5 Misc OS

```powershell
# Disable NTFS last-access timestamp updates (reduces metadata writes)
fsutil behavior set disablelastaccess 1

# Verify 8.3 name creation is disabled on data volumes (default on non-system volumes in modern builds)
fsutil 8dot3name query D:

# Fixed-size page file, avoid dynamic resizing
$cs = Get-CimInstance Win32_ComputerSystem
Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$false}
```

Also: install the latest Windows CUs, set a static IP, register SPNs if you need Kerberos, and confirm the server is not also a domain controller or file server.

---

## 3. Installation

### 3.1 Unattended configuration file

Save as `ConfigurationFile.ini`. Adjust paths, accounts, and core counts.

```ini
[OPTIONS]
ACTION="Install"
; Omit AZUREEXTENSION unless you are deliberately onboarding to Azure Arc
FEATURES=SQLENGINE
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
QUIET="True"
IACCEPTSQLSERVERLICENSETERMS="True"
SUPPRESSPRIVACYSTATEMENTNOTICE="True"
UPDATEENABLED="False"

; --- Service accounts ---
SQLSVCACCOUNT="CORP\gmsa-sql-eng$"
SQLSVCSTARTUPTYPE="Automatic"
AGTSVCACCOUNT="CORP\gmsa-sql-agt$"
AGTSVCSTARTUPTYPE="Automatic"
SQLSVCINSTANTFILEINIT="True"

; --- Sysadmins ---
SQLSYSADMINACCOUNTS="CORP\SQL-DBA-Admins"
SECURITYMODE="SQL"          ; omit this + SAPWD for Windows-auth-only

; --- File locations ---
INSTALLSQLDATADIR="D:\MSSQL"
SQLUSERDBDIR="D:\MSSQL\Data"
SQLUSERDBLOGDIR="L:\MSSQL\Log"
SQLBACKUPDIR="B:\MSSQL\Backup"
SQLTEMPDBDIR="T:\MSSQL\TempDB"
SQLTEMPDBLOGDIR="T:\MSSQL\TempDBLog"

; --- tempdb: 8 files (or #cores if fewer), pre-sized, uniform ---
SQLTEMPDBFILECOUNT="8"
SQLTEMPDBFILESIZE="8192"        ; MB per data file
SQLTEMPDBFILEGROWTH="1024"      ; MB, fixed
SQLTEMPDBLOGFILESIZE="8192"     ; MB
SQLTEMPDBLOGFILEGROWTH="1024"   ; MB

; --- Engine tuning (2022 setup supports these natively) ---
SQLMAXDOP="8"
SQLMINMEMORY="0"
SQLMAXMEMORY="122880"           ; MB — see §4.1

; --- Collation: set deliberately, it is painful to change later ---
SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"

; --- Network ---
TCPENABLED="1"
NPENABLED="0"
```

```cmd
setup.exe /ConfigurationFile=ConfigurationFile.ini /SAPWD="<strong-password>"
```

### 3.2 Patch immediately

Apply the latest CU before the instance carries any load. Verify:

```sql
SELECT SERVERPROPERTY('ProductVersion')   AS Build,
       SERVERPROPERTY('ProductLevel')     AS Level,
       SERVERPROPERTY('ProductUpdateLevel') AS CU,
       SERVERPROPERTY('Edition')          AS Edition,
       SERVERPROPERTY('Collation')        AS Collation;
```

### 3.3 Confirm the privileges took

```sql
SELECT instant_file_initialization_enabled,   -- should be Y
       sql_memory_model_desc                  -- should be LOCK_PAGES or CONVENTIONAL
FROM sys.dm_server_services s
CROSS JOIN sys.dm_os_sys_info
WHERE s.servicename LIKE 'SQL Server (%';
```

If `sql_memory_model_desc` shows `CONVENTIONAL`, Lock Pages in Memory was not granted or the service was not restarted.

---

## 4. Instance configuration

### 4.1 Memory

```sql
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;

-- Leave the OS 4-8 GB (more if other agents run here).
-- Standard caps the BUFFER POOL at 128 GB; max server memory covers all clerks.
EXEC sp_configure 'max server memory (MB)', 122880;   -- 120 GB on a 128 GB VM
EXEC sp_configure 'min server memory (MB)', 65536;    -- optional floor
RECONFIGURE;
```

Sizing guide, for a dedicated SQL VM:

| Host RAM | max server memory (MB) |
|---|---|
| 64 GB | 57344 |
| 128 GB | 118784 |
| 192 GB | 131072 (BP capped at 128 GB; remainder only useful for columnstore/IMOLTP) |

### 4.2 Parallelism

Write-heavy OLTP is latency-sensitive and rarely benefits from parallel DML. Bias conservative.

```sql
EXEC sp_configure 'cost threshold for parallelism', 50;   -- default 5 is a 1990s artifact
RECONFIGURE;

-- MAXDOP: cores per NUMA node, capped at 8. Under 8 cores total, use core count.
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;
```

Verify your NUMA layout before choosing:

```sql
SELECT memory_node_id, COUNT(*) AS schedulers
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE'
GROUP BY memory_node_id;
```

### 4.3 Other instance settings

```sql
EXEC sp_configure 'optimize for ad hoc workloads', 1;   -- plan cache bloat control
EXEC sp_configure 'backup compression default', 1;      -- less backup I/O contention
EXEC sp_configure 'backup checksum default', 1;         -- SQL 2022 addition; cheap corruption detection
EXEC sp_configure 'remote admin connections', 1;        -- DAC over TCP; you will want this at 3am
RECONFIGURE;
```

### 4.4 Startup trace flags

Add via SQL Server Configuration Manager → Service Properties → Startup Parameters (`-T3226`).

| Flag | Effect | Recommendation |
|---|---|---|
| 3226 | Suppress successful-backup entries in ERRORLOG | **Enable** — with log backups every 2–5 min your ERRORLOG is otherwise useless |
| 834 | Large-page allocations for buffer pool | Only with Lock Pages in Memory, plenty of RAM, and after testing. Can slow startup and interacts badly with columnstore. Default: skip. |
| 1117 / 1118 | Uniform file growth / uniform extents | **Do not set** — default behavior since 2016 |
| 4199 | All query optimizer hotfixes | Prefer database-scoped `QUERY_OPTIMIZER_HOTFIXES = ON` after regression testing |

### 4.5 tempdb metadata contention

For heavy temp-object churn (which write-heavy ETL and stored-proc workloads generate constantly):

```sql
ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;
-- Requires instance restart. Verify:
SELECT SERVERPROPERTY('IsTempdbMetadataMemoryOptimized');
```

Caveats: no columnstore indexes on temp tables, and a few `sp_getapplock`/DDL restrictions. Test against your app before committing.

### 4.6 Agent, alerts, and Database Mail

Configure Database Mail and Agent operator, then create alerts for severity 19–25 plus 823/824/825 (I/O errors). On a write-heavy system, 825 ("read retry succeeded") is your early warning that storage is dying.

```sql
EXEC msdb.dbo.sp_add_alert @name = N'Sev 19 - Fatal Resource Error',
     @severity = 19, @notification_message = N'Investigate immediately.',
     @include_event_description_in = 1;
-- Repeat for 20-25 and message_id 823, 824, 825.
```

---

## 5. Database creation

### 5.1 Pre-size everything

Autogrowth during production load is a stall. Size for 12–18 months of growth up front.

```sql
CREATE DATABASE [AppDB]
 ON PRIMARY
  ( NAME = N'AppDB_data01', FILENAME = N'D:\MSSQL\Data\AppDB_data01.mdf',
    SIZE = 262144MB, FILEGROWTH = 4096MB ),
  ( NAME = N'AppDB_data02', FILENAME = N'D:\MSSQL\Data\AppDB_data02.ndf',
    SIZE = 262144MB, FILEGROWTH = 4096MB ),
  ( NAME = N'AppDB_data03', FILENAME = N'D:\MSSQL\Data\AppDB_data03.ndf',
    SIZE = 262144MB, FILEGROWTH = 4096MB ),
  ( NAME = N'AppDB_data04', FILENAME = N'D:\MSSQL\Data\AppDB_data04.ndf',
    SIZE = 262144MB, FILEGROWTH = 4096MB )
 LOG ON
  ( NAME = N'AppDB_log', FILENAME = N'L:\MSSQL\Log\AppDB_log.ldf',
    SIZE = 8192MB, FILEGROWTH = 64MB );
GO
```

**Data files:** multiple equal-sized files in the filegroup spread allocation across proportional-fill targets and reduce allocation-page (PFS/GAM/SGAM) contention on insert-heavy tables. 4–8 files is the usual sweet spot. They must be **equal size with equal growth**, or proportional fill will skew them.

**Log file growth increment = 64 MB.** This is counterintuitive versus older guidance, but SQL 2022's instant file initialization for log growth only covers events **up to 64 MB**. A 4 GB log autogrow gets zero-written and stalls every committing transaction for the duration. Small IFI-eligible increments plus a properly pre-sized log is the better trade.

### 5.2 Grow the log to final size in steps, then check VLFs

Grow to target in ~8 GB increments to get a sane VLF count, then leave autogrow at 64 MB as a safety net.

```sql
-- Repeat in 8GB steps up to target (e.g. 128 GB)
ALTER DATABASE [AppDB] MODIFY FILE (NAME = N'AppDB_log', SIZE = 16384MB);
ALTER DATABASE [AppDB] MODIFY FILE (NAME = N'AppDB_log', SIZE = 24576MB);
-- ... etc

-- Then verify
SELECT COUNT(*) AS vlf_count,
       MIN(vlf_size_mb) AS min_vlf_mb,
       MAX(vlf_size_mb) AS max_vlf_mb
FROM sys.dm_db_log_info(DB_ID('AppDB'));
```

Target a few hundred VLFs. Thousands of tiny VLFs slow recovery, log backups, and log truncation.

### 5.3 Database-level settings

```sql
ALTER DATABASE [AppDB] SET RECOVERY FULL;
ALTER DATABASE [AppDB] SET AUTO_SHRINK OFF;              -- never
ALTER DATABASE [AppDB] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [AppDB] SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE [AppDB] SET AUTO_UPDATE_STATISTICS_ASYNC ON;  -- avoids stat-update stalls on hot paths
ALTER DATABASE [AppDB] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [AppDB] SET TARGET_RECOVERY_TIME = 60 SECONDS;  -- indirect checkpoint, default for new DBs
ALTER DATABASE [AppDB] SET COMPATIBILITY_LEVEL = 160;
```

---

## 6. Write-path tuning

This is where the workload is actually won or lost.

### 6.1 Log write latency — measure before you tune

```sql
SELECT DB_NAME(vfs.database_id) AS db,
       mf.physical_name,
       vfs.num_of_writes,
       vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes,0) AS avg_write_ms,
       vfs.io_stall_read_ms  / NULLIF(vfs.num_of_reads,0)  AS avg_read_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf
  ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
ORDER BY avg_write_ms DESC;
```

Log file `avg_write_ms` above ~2 ms means you have a storage problem, not a query problem. Fix it there before touching anything else.

### 6.2 Accelerated Database Recovery

```sql
ALTER DATABASE [AppDB] SET ACCELERATED_DATABASE_RECOVERY = ON;
```

**Enable when:** you have long-running transactions, large rollbacks, or log growth driven by an old active transaction pinning the log. ADR gives near-instant rollback and much more aggressive log truncation.

**Cost:** the Persistent Version Store lives in your database and adds write amplification plus space. On a pure short-transaction ingest workload, ADR may cost more than it saves. Benchmark it both ways — this is a genuine trade, not a free win.

Monitor PVS size:

```sql
SELECT DB_NAME(database_id) AS db, persistent_version_store_size_kb / 1024.0 AS pvs_mb,
       oldest_active_transaction_id, online_index_version_cleanup_lsn
FROM sys.dm_tran_persistent_version_store_stats
WHERE database_id = DB_ID('AppDB');
```

### 6.3 Delayed durability

The highest-leverage single setting for commit-bound ingest workloads, and the most dangerous.

```sql
-- Preferred: allow it, and let specific workloads opt in
ALTER DATABASE [AppDB] SET DELAYED_DURABILITY = ALLOWED;

-- Then, in the transaction that can tolerate it:
COMMIT TRANSACTION WITH (DELAYED_DURABILITY = ON);
```

**What it does:** commits return without waiting for the log flush; the log buffer flushes when full (~60 KB), on a checkpoint, or on `sp_flush_log`.

**What it costs:** on a crash/failover you lose every committed transaction still sitting in the log buffer. This is *data loss on committed transactions* — not a corruption risk, but a durability one.

**Use it for:** telemetry, audit trails, staging/ETL loads, anything replayable.
**Do not use it for:** financial transactions, anything where the client is told "saved" and means it, or where you cannot reconstruct the last few seconds from an upstream source.

`SET DELAYED_DURABILITY = FORCED` at the database level is a blunt instrument — get explicit written sign-off before using it.

### 6.4 Last-page insert contention

A clustered index on an ever-increasing key (IDENTITY, sequential datetime) funnels every insert to the same trailing page. Under high concurrency this shows up as `PAGELATCH_EX` waits on a single page — throughput flatlines while CPU sits idle.

```sql
-- SQL 2019+ mitigation, all editions
ALTER TABLE dbo.Events
  ADD CONSTRAINT PK_Events PRIMARY KEY CLUSTERED (EventId)
  WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON);
```

If that's insufficient, options in escalating order of disruption: hash-partition the table on a computed modulo column; use a non-sequential clustered key; move the hot table to In-Memory OLTP (32 GB/DB in Standard).

Diagnose with:

```sql
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       wait_time_ms / NULLIF(waiting_tasks_count,0) AS avg_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('WRITELOG','PAGELATCH_EX','PAGELATCH_SH',
                    'PAGEIOLATCH_EX','LOGBUFFER','HADR_SYNC_COMMIT')
ORDER BY wait_time_ms DESC;
```

### 6.5 Index strategy

**Every nonclustered index multiplies your write cost.** An INSERT into a table with 8 nonclustered indexes is 9 index maintenance operations and 9 sets of log records. On a write-heavy system, index count is a throughput dial.

Audit ruthlessly:

```sql
SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name,
       s.user_seeks, s.user_scans, s.user_lookups, s.user_updates,
       s.user_updates - (s.user_seeks + s.user_scans + s.user_lookups) AS write_read_delta
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s
  ON s.object_id = i.object_id AND s.index_id = i.index_id
  AND s.database_id = DB_ID()
WHERE i.type_desc = 'NONCLUSTERED' AND OBJECTPROPERTY(i.object_id,'IsUserTable') = 1
ORDER BY write_read_delta DESC;
```

Anything with a large positive `write_read_delta` is pure overhead. (Counters reset on instance restart — collect over a full business cycle.)

### 6.6 Page splits and fill factor

Bad page splits are fully logged and generate significant extra log volume.

- Sequential clustered keys → fill factor 95–100.
- Random keys (GUIDs, natural keys) → fill factor 80–90, and consider redesigning the key.
- Do **not** apply a global low fill factor. It wastes buffer pool and increases the pages you must write.

Monitor bad splits:

```sql
SELECT OBJECT_NAME(ios.object_id) AS table_name, i.name AS index_name,
       ios.leaf_allocation_count, ios.nonleaf_allocation_count
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) ios
JOIN sys.indexes i ON i.object_id = ios.object_id AND i.index_id = ios.index_id
WHERE ios.leaf_allocation_count > 0
ORDER BY ios.leaf_allocation_count DESC;
```

### 6.7 Isolation level

`READ_COMMITTED_SNAPSHOT` eliminates most reader/writer blocking, which usually helps overall throughput. But it adds a 14-byte version pointer to every modified row and pushes version records into tempdb (or the PVS if ADR is on).

```sql
ALTER DATABASE [AppDB] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
```

On a write-dominated workload with few concurrent readers, RCSI may be net negative. Test it. If enabling, watch tempdb version store growth via `sys.dm_tran_version_store_space_usage`.

### 6.8 Overhead features to audit

Each of these adds synchronous work to your write path. Confirm every one is actually needed:

- Triggers (especially those doing lookups or writing audit rows)
- Change Data Capture / Change Tracking
- Transactional replication
- Temporal tables (every UPDATE becomes an UPDATE plus an INSERT to history)
- Foreign key constraints without supporting indexes on the child side
- TDE (encrypts on write; measurable CPU cost)
- Query Store (see §8.3)

### 6.9 Batching

Application-side, but the biggest lever available: a single transaction committing 1,000 rows costs one log flush; 1,000 autocommit transactions cost 1,000. If you can influence the application, batching beats every server-side setting in this document.

---

## 7. Backup and recovery

Heavy write = heavy log generation. Log backup cadence is now a throughput and space concern, not just an RPO one.

| Backup | Cadence | Notes |
|---|---|---|
| Full | Weekly | Striped across multiple files, compressed |
| Differential | Daily | |
| Transaction log | **Every 2–5 minutes** | Also sets your RPO |

```sql
BACKUP DATABASE [AppDB]
TO DISK = N'B:\MSSQL\Backup\AppDB_full_01.bak',
   DISK = N'B:\MSSQL\Backup\AppDB_full_02.bak',
   DISK = N'B:\MSSQL\Backup\AppDB_full_03.bak',
   DISK = N'B:\MSSQL\Backup\AppDB_full_04.bak'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 5,
     MAXTRANSFERSIZE = 4194304, BUFFERCOUNT = 50;
```

Striping across 4 files parallelizes the write and typically cuts full-backup duration substantially. `MAXTRANSFERSIZE = 4194304` (4 MB) plus a raised `BUFFERCOUNT` improves throughput to fast targets — but `BUFFERCOUNT` consumes memory outside `max server memory`, so raise it in steps and watch.

Use Ola Hallengren's maintenance solution (`ola.hallengren.com`) for the scheduling framework rather than hand-rolling jobs.

**Restore-test quarterly.** A backup you have never restored is a hypothesis.

---

## 8. Maintenance and monitoring

### 8.1 Index maintenance without online rebuild

Standard Edition has no online rebuild, so:

1. **REORGANIZE first** — it's online, and adequate for 5–30% fragmentation.
2. **REBUILD only above ~30%**, and only inside a maintenance window, since it takes a schema modification lock for the duration.
3. **Partition your largest hot tables** so you can rebuild one partition at a time — a much shorter lock.
4. **Update statistics** more aggressively than you rebuild. On big tables the default 20%-of-rows sampling threshold means stats go stale long before fragmentation matters. `PERSIST_SAMPLE_PERCENT` helps hold a chosen sample rate.

Fragmentation on a write-heavy OLTP system is usually the *symptom* (bad clustered key, low fill factor) — treat the cause.

### 8.2 Consistency checks

```sql
DBCC CHECKDB([AppDB]) WITH NO_INFOMSGS, ALL_ERRORMSGS, PHYSICAL_ONLY;
```

Weekly minimum. On very large DBs, offload the full CHECKDB to a restored copy on a secondary server and run `PHYSICAL_ONLY` on production.

### 8.3 Query Store

On by default for new databases in SQL 2022. Useful, but it writes.

```sql
ALTER DATABASE [AppDB] SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,          -- not ALL, on a high-throughput system
    MAX_STORAGE_SIZE_MB = 4096,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 30,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    WAIT_STATS_CAPTURE_MODE = ON        -- turn OFF if you measure overhead
);
```

`QUERY_CAPTURE_MODE = ALL` on a workload executing thousands of small statements per second will hurt. Keep it on AUTO or CUSTOM.

### 8.4 Baseline collection

Capture a baseline in week one, before the workload ramps, and keep collecting:

- `sys.dm_os_wait_stats` — snapshot and delta, not cumulative-since-restart
- `sys.dm_io_virtual_file_stats` — per-file latency trend
- PerfMon: `SQL Server:Databases\Log Bytes Flushed/sec`, `Log Flush Wait Time`, `Log Flush Waits/sec`, `Transactions/sec`, `SQL Server:Buffer Manager\Page life expectancy`, `Checkpoint pages/sec`, `LogicalDisk\Avg. Disk sec/Write`
- `sys.dm_db_index_operational_stats` — latch and page-split trends

Without a baseline you cannot distinguish "slow" from "different."

---

## 9. Validation and acceptance

### 9.1 Storage validation (before SQL carries load)

Use `diskspd` on each volume with the file pre-created and caching disabled.

```cmd
:: Log volume — small sequential writes, low queue depth. Latency is what matters.
diskspd.exe -c50G -d60 -W15 -w100 -b64K -si -t1 -o1 -L -Sh L:\iotest.dat

:: Data volume — mixed random 8K, moderate queue depth
diskspd.exe -c100G -d60 -W15 -w30 -b8K -r -t8 -o16 -L -Sh D:\iotest.dat

:: tempdb volume — write-heavy random 64K
diskspd.exe -c50G -d60 -W15 -w70 -b64K -r -t4 -o8 -L -Sh T:\iotest.dat
```

Delete the test files afterward.

### 9.2 Acceptance criteria

| Metric | Source | Target |
|---|---|---|
| Log volume write latency | diskspd, `-L` output, 95th pct | < 2 ms |
| Data volume read latency | diskspd | < 10 ms |
| `WRITELOG` average wait | `sys.dm_os_wait_stats` | < 2 ms |
| `PAGEIOLATCH_*` average wait | `sys.dm_os_wait_stats` | < 10 ms |
| `Log Flush Wait Time` | PerfMon | ≤ 1 ms sustained |
| Page life expectancy | PerfMon | Stable; alert on sharp drops, not on the mythical 300 threshold |
| IFI enabled | `sys.dm_server_services` | Y |
| Memory model | `sys.dm_os_sys_info` | LOCK_PAGES |
| VLF count per DB | `sys.dm_db_log_info` | < ~500 |
| tempdb data files | `sys.master_files` | 8, equal size, equal growth |

### 9.3 Workload test

Run HammerDB TPROC-C (or a replay of your own workload) at 1x, 2x, and 4x expected concurrency. Capture wait stats deltas at each level. You're looking for the level at which the top wait shifts — that's your first real bottleneck, and it's usually `WRITELOG` or `PAGELATCH_EX`.

---

## 10. Go-live checklist

- [ ] BIOS power profile Max Performance, C-states disabled
- [ ] Windows High Performance power plan active
- [ ] VM memory 100% reserved, no snapshots, PVSCSI controllers split by workload
- [ ] All SQL volumes formatted 64K NTFS, verified
- [ ] AV exclusions applied and confirmed by security team
- [ ] gMSAs in use; IFI and Lock Pages in Memory granted and verified in DMVs
- [ ] Latest CU applied; build recorded in CMDB
- [ ] max server memory, MAXDOP, cost threshold, backup compression/checksum set
- [ ] TF3226 in startup parameters
- [ ] tempdb: 8 equal files, pre-sized, on fastest storage
- [ ] User DB data and log pre-sized; log autogrow = 64 MB; VLF count verified
- [ ] Recovery model FULL; log backups scheduled every 2–5 min
- [ ] Full + differential + log backup jobs running and **restore-tested**
- [ ] DBCC CHECKDB scheduled and completing clean
- [ ] Agent alerts for sev 19–25 and 823/824/825 configured with a working operator
- [ ] Baseline wait stats and file latency captured
- [ ] ADR / delayed durability / RCSI decisions tested and documented with sign-off
- [ ] Monitoring agent deployed; disk-full alerting on all SQL volumes
- [ ] Runbook and connection details handed to on-call

---

## Appendix A — Common write-heavy failure signatures

| Symptom | Likely cause | First action |
|---|---|---|
| `WRITELOG` dominant, high CPU idle | Log storage latency | §6.1 — check `dm_io_virtual_file_stats`, check BBU/write-cache mode |
| `PAGELATCH_EX` on one page, throughput flat | Last-page insert contention | §6.4 — `OPTIMIZE_FOR_SEQUENTIAL_KEY` |
| `PAGELATCH_UP` on 2:1:1 / 2:1:3 | tempdb allocation contention | §4.5 — memory-optimized tempdb metadata; verify 8 equal files |
| Periodic multi-second stalls | Log autogrowth (zero-write) | §5.1 — pre-size log, autogrow ≤ 64 MB |
| Log file grows without bound | Log backups failing, or long-open transaction | `SELECT log_reuse_wait_desc FROM sys.databases` |
| Sudden latency cliff after host event | VMware ballooning / snapshot present | Check memory reservation, delete snapshots |
| High `Log Bytes Flushed/sec` vs modest transaction count | Index bloat, page splits, or temporal/CDC overhead | §6.5, §6.6, §6.8 |

## Appendix B — Quick health query

```sql
SELECT TOP 15
       wait_type,
       waiting_tasks_count,
       wait_time_ms,
       wait_time_ms / NULLIF(waiting_tasks_count,0) AS avg_wait_ms,
       signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE waiting_tasks_count > 0
  AND wait_type NOT IN (
      'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK',
      'SLEEP_SYSTEMTASK','SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE',
      'CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT',
      'BROKER_TO_FLUSH','BROKER_TASK_STOP','CLR_MANUAL_EVENT','CLR_AUTO_EVENT',
      'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT','XE_DISPATCHER_WAIT',
      'XE_DISPATCHER_JOIN','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','DIRTY_PAGE_POLL',
      'SP_SERVER_DIAGNOSTICS_SLEEP','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
      'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_ASYNC_QUEUE','QDS_SHUTDOWN_QUEUE',
      'PREEMPTIVE_XE_GETTARGETSTATE','PWAIT_ALL_COMPONENTS_INITIALIZED')
ORDER BY wait_time_ms DESC;
```
