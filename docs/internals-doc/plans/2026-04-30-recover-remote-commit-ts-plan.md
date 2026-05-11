# `remote_commit_ts` Recovery via `pg_commit_ts` Scan — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After crash recovery, scan `pg_commit_ts` backward to recover the most-recent `remote_commit_ts` per origin so `spock.progress` shows accurate values post-crash; the recovered `prev_remote_ts` is also intended to be useful for the planned parallel-apply rework.

**Architecture:** New file-static function `recover_progress_timestamps_from_commit_ts()` in `src/spock_apply.c`, called from `spock_apply_main` after `reconcile_progress_with_origin` and before `spock_start_replication`, gated on a new `ReconcileResult` enum so the scan only runs when the loaded `resource.dat` is stale or missing. Termination after observing 1000 commits per origin or scanning 1M xids total. Hard error if `track_commit_timestamp` is off.

**Tech Stack:** C (Postgres extension), Postgres SLRU API (`TransactionIdGetCommitTsData`), Perl TAP tests (existing `SpockTest` module).

**Pre-flight:**

```bash
source ~/bin/env17.sh                # activates pg_config / PATH
cd /home/msharp/dev/pgedge7/spock
git status                           # working tree clean
make -j4 install                     # baseline build OK
```

---

## File Structure

| File | Role | Change |
|---|---|---|
| `src/spock_apply.c` | Apply worker main, reconcile, new recovery function | Modify |
| `tests/tap/t/027_remote_commit_ts_recovery.pl` | Happy path | Create |
| `tests/tap/t/029_remote_commit_ts_recovery_clean_shutdown.pl` | Skip-path verification | Create |
| `tests/tap/t/030_remote_commit_ts_recovery_track_commit_ts_off.pl` | Error-path verification | Create |

No header changes — `ReconcileResult` is file-static.

---

## Task 1: Refactor `reconcile_progress_with_origin` to return `ReconcileResult`

**Why first:** The recovery function needs to know which reconcile branch was taken so it can skip when the file is in sync. Threading the enum through is purely structural with no behavioral change, so it's safe to land first.

**Files:**
- Modify: `src/spock_apply.c` — add enum near other forward declarations (~line 245-260), change function signature at `src/spock_apply.c:2937-2938`, update caller at `src/spock_apply.c:4216`.

- [ ] **Step 1.1: Add the enum near the existing forward declarations**

Locate the forward declarations block at `src/spock_apply.c:248-257`:

```c
static void UpdateWorkerStats(XLogRecPtr last_received, XLogRecPtr last_inserted);
...
static void request_initial_status_update(PGconn *conn, XLogRecPtr startpos);
static void reconcile_progress_with_origin(XLogRecPtr origin_lsn);
```

Replace the last line with the enum and updated declaration:

```c
typedef enum ReconcileResult
{
	RECONCILE_FILE_IN_SYNC,		/* file_lsn == origin_lsn; recovery scan can skip */
	RECONCILE_FILE_STALE,		/* file_lsn <  origin_lsn; recovery scan needed */
	RECONCILE_FILE_ANOMALY,		/* file_lsn >  origin_lsn; recovery scan needed */
	RECONCILE_FILE_ABSENT		/* no entry was loaded; recovery scan needed */
} ReconcileResult;

static ReconcileResult reconcile_progress_with_origin(XLogRecPtr origin_lsn);
```

- [ ] **Step 1.2: Update the function definition to return the enum**

At `src/spock_apply.c:2937`, change:

```c
static void
reconcile_progress_with_origin(XLogRecPtr origin_lsn)
```

to:

```c
static ReconcileResult
reconcile_progress_with_origin(XLogRecPtr origin_lsn)
```

In the body (current `src/spock_apply.c:2944-3043`), each branch must `return` the appropriate enum value.

- The early-return at the top (`!SpockGroupHash || !SpockCtx`) — change to `return RECONCILE_FILE_ABSENT;`. The hash isn't set up; treat as absent.
- The `entry == NULL` case (hash full) — change `return;` to `return RECONCILE_FILE_ABSENT;` and continue with the existing WARNING.
- The `if (!found)` branch — after the existing log line, `result = RECONCILE_FILE_ABSENT;`.
- The `else if (entry->progress.remote_commit_lsn == origin_lsn)` branch — `result = RECONCILE_FILE_IN_SYNC;`.
- The `else if (entry->progress.remote_commit_lsn < origin_lsn)` branch — `result = RECONCILE_FILE_STALE;`.
- The final `else` (anomaly) branch — `result = RECONCILE_FILE_ANOMALY;`.

Concretely, declare `ReconcileResult result;` near the top of the function, set it in each branch, and return it after `LWLockRelease`.

```c
static ReconcileResult
reconcile_progress_with_origin(XLogRecPtr origin_lsn)
{
	SpockGroupKey	key;
	SpockGroupEntry *entry;
	bool			found;
	ReconcileResult	result;

	if (!SpockGroupHash || !SpockCtx)
	{
		elog(WARNING, "SPOCK %s: SpockGroupHash is not initialized; reconcile skipped",
			 MySubscription->name);
		return RECONCILE_FILE_ABSENT;
	}

	key.dbid = MyDatabaseId;
	key.node_id = MySubscription->target->id;
	key.remote_node_id = MySubscription->origin->id;

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	entry = (SpockGroupEntry *) hash_search(SpockGroupHash, &key,
											HASH_ENTER, &found);
	if (entry == NULL)
	{
		LWLockRelease(SpockCtx->apply_group_master_lock);
		elog(WARNING, "SpockGroupHash is full, cannot reconcile progress for "
			 "(dbid=%u, node_id=%u, remote_node_id=%u)",
			 key.dbid, key.node_id, key.remote_node_id);
		return RECONCILE_FILE_ABSENT;
	}

	if (!found)
	{
		/* ...existing init body unchanged... */
		result = RECONCILE_FILE_ABSENT;
	}
	else if (entry->progress.remote_commit_lsn == origin_lsn)
	{
		/* ...existing body unchanged... */
		result = RECONCILE_FILE_IN_SYNC;
	}
	else if (entry->progress.remote_commit_lsn < origin_lsn)
	{
		/* ...existing stale body unchanged... */
		result = RECONCILE_FILE_STALE;
	}
	else
	{
		/* ...existing anomaly body unchanged... */
		result = RECONCILE_FILE_ANOMALY;
	}

	LWLockRelease(SpockCtx->apply_group_master_lock);
	return result;
}
```

- [ ] **Step 1.3: Update the caller to receive the result**

At `src/spock_apply.c:4216`, change:

```c
reconcile_progress_with_origin(origin_startpos);
```

to:

```c
ReconcileResult reconcile_result = reconcile_progress_with_origin(origin_startpos);
```

The variable is unused for now; Task 4 wires it up. Suppress the unused-variable warning by adding `(void) reconcile_result;` directly below the call, with a comment `/* used in Task 4 */`.

- [ ] **Step 1.4: Build and verify no behavioral regression**

```bash
make -j4 install
```

Expected: clean build, no new warnings.

```bash
cd tests/tap && ./run_tests.sh t/022_rmgr_progress_post_checkpoint_crash.pl
```

Expected: all subtests pass (this test exercises the reconcile path most heavily).

- [ ] **Step 1.5: Commit**

```bash
git add src/spock_apply.c
git commit -m "refactor: reconcile_progress_with_origin returns ReconcileResult

Threads a typed result back to the caller so a follow-up commit can
gate post-reconcile work on whether the loaded resource.dat was in
sync, stale, anomalous, or absent. Pure refactor -- no behavior
change."
```

---

## Task 2: Add the recovery constants

**Files:**
- Modify: `src/spock_apply.c` — add `#define`s near the top of the file, after the existing macros / includes.

- [ ] **Step 2.1: Add the three `#define`s**

Find an appropriate spot near the top of `src/spock_apply.c` (after the includes, near other apply-side `#define`s if present, or otherwise just before the forward declarations). Add:

```c
/*
 * Constants governing the post-crash scan of pg_commit_ts that recovers
 * remote_commit_ts per origin. Plain #defines for now; convert to GUCs
 * only if a deployment ever needs to tune them.
 */
#define SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN	1000
#define SPOCK_TS_RECOVERY_SCAN_LIMIT			1000000
#define SPOCK_TS_RECOVERY_BATCH_SIZE			1000
```

- [ ] **Step 2.2: Build to verify**

```bash
make -j4 install
```

Expected: clean build (no use sites yet, but the macros exist).

- [ ] **Step 2.3: Commit**

```bash
git add src/spock_apply.c
git commit -m "feat: add SPOCK_TS_RECOVERY_* constants for commit_ts scan

Adds the three tunables (min commits per origin, hard scan limit,
batch size) for the upcoming pg_commit_ts recovery scan. Defined as
plain #defines; conversion to GUCs is a follow-up if profiling
motivates tuning."
```

---

## Task 3: Write the failing happy-path test (027)

**Why before implementation:** Establishes the regression target — running this test against `main` (or after Task 2) must fail; running it after Task 4 must pass.

**Files:**
- Create: `tests/tap/t/027_remote_commit_ts_recovery.pl`

- [ ] **Step 3.1: Create the test file**

Write `tests/tap/t/027_remote_commit_ts_recovery.pl` with the following content:

```perl
#!/usr/bin/perl
# =============================================================================
# Test: 027_remote_commit_ts_recovery.pl
#       Verify that after a crash, remote_commit_ts is recovered from the
#       subscriber's pg_commit_ts SLRU rather than left NULL. The recovered
#       values are also intended to be useful for the planned parallel-apply
#       rework.
#
# Topology:  n1 (provider) -> n2 (subscriber)
#
# Sequence:
#   1. Apply commits, clean restart (writes resource.dat).
#   2. Apply more commits (origin advances; resource.dat stale).
#   3. SIGKILL subscriber.
#   4. Restart. Apply worker reconcile detects stale, calls the new
#      recover_progress_timestamps_from_commit_ts which scans pg_commit_ts
#      backward and populates remote_commit_ts.
#   5. Assert remote_commit_ts is NOT NULL.
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    command_ok get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_pg_ready
);

sub wait_until {
    my ($timeout_s, $probe) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $probe->();
        select(undef, undef, undef, 0.25);
    }
    return 0;
}

create_cluster(2, 'Create 2-node cluster');

my $conf      = get_test_config();
my $host      = $conf->{host};
my $pg_bin    = $conf->{pg_bin};
my $ports     = $conf->{node_ports};
my $datadirs  = $conf->{node_datadirs};
my $dbname    = $conf->{db_name};
my $user      = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

psql_or_bail(1, "CREATE TABLE public.ts_recovery (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.ts_recovery (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'subscription is replicating');

# --- Round 1: apply, clean restart so resource.dat is written. ---
psql_or_bail(1, "INSERT INTO public.ts_recovery SELECT g, 'r1_' || g FROM generate_series(1,50) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_recovery") eq '50' }),
   'round-1 50 rows replicated');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok(-f "$sub_dir/spock/resource.dat", 'resource.dat written on clean stop');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber back up');
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'replicating after clean restart');

# --- Round 2: apply more so origin advances past resource.dat's snapshot. ---
psql_or_bail(1, "INSERT INTO public.ts_recovery SELECT g, 'r2_' || g FROM generate_series(51,100) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_recovery") eq '100' }),
   'round-2 50 rows replicated');

# Confirm remote_commit_ts is non-NULL pre-crash (sanity).
my $pre_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
ok($pre_ts ne '', "pre-crash remote_commit_ts populated: $pre_ts");

# --- SIGKILL subscriber. ---
my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $sub_pid = <$fh>;
chomp($sub_pid);
close($fh);
kill 'KILL', $sub_pid;
pass('subscriber SIGKILLed');

select(undef, undef, undef, 2.0);

# --- Restart. Reconcile detects stale; recovery scan populates remote_commit_ts. ---
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber accepting connections after crash');

# Wait for the apply worker to start, run reconcile, run recovery scan.
ok(wait_until(30, sub {
    my $ts = scalar_query(2, q{
        SELECT remote_commit_ts::text FROM spock.progress LIMIT 1
    });
    defined $ts && $ts ne '' && $ts ne '0/0'
}), 'spock.progress.remote_commit_ts populated by recovery scan');

# --- Assertions ---
my $post_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
ok($post_ts ne '',
   "post-crash remote_commit_ts is NOT NULL (recovered via pg_commit_ts scan): $post_ts");

# remote_commit_ts must be a valid timestamp (parses as such).
my $ts_valid = scalar_query(2,
    "SELECT '$post_ts'::timestamptz IS NOT NULL");
is($ts_valid, 't', "post-crash remote_commit_ts parses as a valid timestamptz");

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
```

Make it executable:

```bash
chmod +x tests/tap/t/027_remote_commit_ts_recovery.pl
```

- [ ] **Step 3.2: Run the test — confirm it fails as expected**

```bash
cd tests/tap && ./run_tests.sh t/027_remote_commit_ts_recovery.pl
```

Expected: the test FAILS at the "post-crash remote_commit_ts is NOT NULL" assertion. Without the recovery scan, the field remains NULL after crash (current behavior).

- [ ] **Step 3.3: Commit**

```bash
git add tests/tap/t/027_remote_commit_ts_recovery.pl
git commit -m "test: add 027 (remote_commit_ts post-crash recovery, currently failing)

Asserts the regression target for the pg_commit_ts scan: after a crash
that leaves resource.dat stale relative to the replication origin,
remote_commit_ts must be recovered (non-NULL) rather than left blank.
Currently fails -- implementation lands in the next commit."
```

---

## Task 4: Implement the scan and wire the call site

**Files:**
- Modify: `src/spock_apply.c` — add `recover_progress_timestamps_from_commit_ts` function and call it from `spock_apply_main`. Add INFO logs.

- [ ] **Step 4.1: Add the forward declaration**

Near the existing forward declarations (`src/spock_apply.c:248-260`, the same block where Task 1 added `ReconcileResult`), add:

```c
static void recover_progress_timestamps_from_commit_ts(SpockGroupEntry *entry,
													   RepOriginId target_origin);
```

- [ ] **Step 4.2: Add the include for `commit_ts.h`**

Near the top of `src/spock_apply.c` (in the `#include` block), add:

```c
#include "access/commit_ts.h"
```

- [ ] **Step 4.3: Implement the scan function**

Add the function after `reconcile_progress_with_origin` (i.e., after the existing block ending at `src/spock_apply.c:3043`):

```c
/*
 * recover_progress_timestamps_from_commit_ts
 *
 * After reconcile detects that resource.dat is stale (or absent) for this
 * origin, scan pg_commit_ts backward from the latest xid to recover the
 * most-recent remote_commit_ts for this origin. The recovered values are
 * also intended to be useful for the planned parallel-apply rework.
 *
 * Termination: stop after observing SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN
 * commits for this origin (any older commit is guaranteed to have a smaller
 * commit_ts under realistic concurrency widths) or after scanning
 * SPOCK_TS_RECOVERY_SCAN_LIMIT total xids.
 *
 * Caller must have ensured the entry exists in SpockGroupHash (reconcile
 * does this).
 */
static void
recover_progress_timestamps_from_commit_ts(SpockGroupEntry *entry,
										   RepOriginId target_origin)
{
	TransactionId	xid_high;
	TimestampTz		running_max_ts = 0;
	int				seen_count = 0;
	int64			total_scanned = 0;

	xid_high = ReadNextTransactionId();
	if (TransactionIdPrecedes(xid_high, FirstNormalTransactionId + 1))
	{
		elog(LOG, "SPOCK %s: ts recovery: no normal transactions yet; skipping",
			 MySubscription->name);
		return;
	}
	xid_high = xid_high - 1;

	while (seen_count < SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN
		   && total_scanned < SPOCK_TS_RECOVERY_SCAN_LIMIT)
	{
		TransactionId	xid_low;
		TransactionId	xid;
		int64			batch_count;

		CHECK_FOR_INTERRUPTS();

		/* Compute batch lower bound, clamped at FirstNormalTransactionId. */
		if (TransactionIdPrecedes(xid_high,
								  FirstNormalTransactionId + SPOCK_TS_RECOVERY_BATCH_SIZE))
			xid_low = FirstNormalTransactionId;
		else
			xid_low = xid_high - SPOCK_TS_RECOVERY_BATCH_SIZE + 1;

		batch_count = (int64) xid_high - (int64) xid_low + 1;

		for (xid = xid_low; TransactionIdPrecedes(xid, xid_high + 1); xid++)
		{
			TimestampTz		ts;
			RepOriginId		origin;

			if (!TransactionIdGetCommitTsData(xid, &ts, &origin))
				continue;					/* aborted, vacuumed, or no commit_ts */
			if (origin != target_origin)
				continue;					/* local writes / other origins */

			seen_count++;
			if (ts > running_max_ts)
				running_max_ts = ts;
		}

		total_scanned += batch_count;

		if (xid_low == FirstNormalTransactionId)
			break;						/* wraparound floor */

		xid_high = xid_low - 1;
	}

	if (running_max_ts > 0)
	{
		LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);
		if (entry->progress.remote_commit_ts < running_max_ts)
		{
			entry->progress.remote_commit_ts = running_max_ts;
			entry->progress.prev_remote_ts = running_max_ts;
		}
		LWLockRelease(SpockCtx->apply_group_master_lock);

		elog(INFO, "SPOCK %s: ts recovery: scanned %lld xids, found %d commits, "
			 "recovered remote_commit_ts",
			 MySubscription->name, (long long) total_scanned, seen_count);
	}
	else
	{
		elog(WARNING, "SPOCK %s: ts recovery: scanned %lld xids, no commits found "
			 "for origin %u; remote_commit_ts remains NULL until next applied commit",
			 MySubscription->name, (long long) total_scanned, target_origin);
	}
}
```

- [ ] **Step 4.4: Wire the call site in `spock_apply_main`**

At `src/spock_apply.c:4216` (where Task 1 introduced `reconcile_result`), replace:

```c
ReconcileResult reconcile_result = reconcile_progress_with_origin(origin_startpos);
(void) reconcile_result;	/* used in Task 4 */
```

with:

```c
ReconcileResult reconcile_result = reconcile_progress_with_origin(origin_startpos);

if (reconcile_result == RECONCILE_FILE_IN_SYNC)
{
	elog(INFO, "SPOCK %s: ts recovery: file in sync with origin, skipping scan",
		 MySubscription->name);
}
else
{
	SpockGroupKey		key;
	SpockGroupEntry	   *entry;
	bool				found;
	RepOriginId			target_origin = replorigin_session_origin;

	key.dbid = MyDatabaseId;
	key.node_id = MySubscription->target->id;
	key.remote_node_id = MySubscription->origin->id;

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_SHARED);
	entry = (SpockGroupEntry *) hash_search(SpockGroupHash, &key,
											HASH_FIND, &found);
	LWLockRelease(SpockCtx->apply_group_master_lock);

	if (entry != NULL)
		recover_progress_timestamps_from_commit_ts(entry, target_origin);
}
```

Note on `target_origin`: `replorigin_session_origin` is the standard Postgres global, set by `replorigin_session_setup(originid)` at `src/spock_apply.c:4212`, two lines before the reconcile call. It is the correct `RepOriginId` to filter by.

- [ ] **Step 4.5: Build and run test 027**

```bash
make -j4 install
cd tests/tap && ./run_tests.sh t/027_remote_commit_ts_recovery.pl
```

Expected: all subtests pass. The "post-crash remote_commit_ts is NOT NULL" assertion now succeeds.

- [ ] **Step 4.6: Run the existing crash-recovery regression to ensure no regression**

```bash
./run_tests.sh t/022_rmgr_progress_post_checkpoint_crash.pl t/008_rmgr.pl
```

Expected: both pass. Note that 022's assertion `is($post_commit_ts, '', "remote_commit_ts is NULL post-crash...")` is now WRONG — recovery populates it. **You must update 022 in this same task.**

- [ ] **Step 4.7: Update test 022 to reflect new behavior**

In `tests/tap/t/022_rmgr_progress_post_checkpoint_crash.pl` at the assertion block (around line 191-197), change:

```perl
my $post_commit_ts = scalar_query(2, q{
    SELECT remote_commit_ts::text FROM spock.progress LIMIT 1
});
is($post_commit_ts, '',
   "remote_commit_ts is NULL post-crash (reconcile cleared stale ts)");

diag("post-crash: remote_commit_lsn=$post_commit_lsn remote_commit_ts='$post_commit_ts' (expected NULL)");
```

to:

```perl
my $post_commit_ts = scalar_query(2, q{
    SELECT remote_commit_ts::text FROM spock.progress LIMIT 1
});
ok($post_commit_ts ne '',
   "remote_commit_ts is NOT NULL post-crash (recovered via pg_commit_ts scan)");

diag("post-crash: remote_commit_lsn=$post_commit_lsn remote_commit_ts='$post_commit_ts'");
```

Also update the file header comment block where it says `remote_commit_ts is NULL post-crash` to reflect the recovery behavior.

- [ ] **Step 4.8: Re-run 022 to confirm the update**

```bash
./run_tests.sh t/022_rmgr_progress_post_checkpoint_crash.pl
```

Expected: all subtests pass.

- [ ] **Step 4.9: Commit**

```bash
git add src/spock_apply.c tests/tap/t/022_rmgr_progress_post_checkpoint_crash.pl
git commit -m "feat: recover remote_commit_ts via pg_commit_ts scan on crash restart

After reconcile_progress_with_origin detects that resource.dat is stale
or absent for an origin, scan pg_commit_ts backward from the latest xid
and populate remote_commit_ts with the max ts found for this origin.
The recovered values are also intended to be useful for the planned
parallel-apply rework.

Termination: 1000 commits seen for this origin (concurrency width is
bounded well below this by max_connections / poolers) or 1M xids total.
Logs INFO on completion (skip path or run path) so startup behavior is
grep-able.

Updates test 022 to reflect that remote_commit_ts is now recovered
rather than NULL after crash."
```

---

## Task 5: Write the failing `track_commit_timestamp` off test (030)

**Files:**
- Create: `tests/tap/t/030_remote_commit_ts_recovery_track_commit_ts_off.pl`

- [ ] **Step 5.1: Create the test**

Write `tests/tap/t/030_remote_commit_ts_recovery_track_commit_ts_off.pl`:

```perl
#!/usr/bin/perl
# =============================================================================
# Test: 030_remote_commit_ts_recovery_track_commit_ts_off.pl
#       Verify that the apply worker errors out at startup if
#       track_commit_timestamp is off and the recovery scan would otherwise
#       run (i.e., resource.dat is stale or absent). Spock requires
#       track_commit_timestamp = on for conflict resolution; making the
#       failure mode loud at apply-worker start is intentional.
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    command_ok get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_pg_ready
);

sub wait_until {
    my ($timeout_s, $probe) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $probe->();
        select(undef, undef, undef, 0.25);
    }
    return 0;
}

sub log_contains {
    my ($logfile, $pattern) = @_;
    return 0 unless -f $logfile;
    open(my $fh, '<', $logfile) or return 0;
    while (my $line = <$fh>) {
        return 1 if $line =~ /$pattern/;
    }
    close($fh);
    return 0;
}

create_cluster(2, 'Create 2-node cluster');

my $conf      = get_test_config();
my $host      = $conf->{host};
my $pg_bin    = $conf->{pg_bin};
my $ports     = $conf->{node_ports};
my $datadirs  = $conf->{node_datadirs};
my $dbname    = $conf->{db_name};
my $user      = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

psql_or_bail(1, "CREATE TABLE public.ts_off (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.ts_off (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'subscription is replicating');

psql_or_bail(1, "INSERT INTO public.ts_off SELECT g, 'r1_' || g FROM generate_series(1,50) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_off") eq '50' }),
   '50 rows replicated');

# Clean restart so resource.dat is current.
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'replicating after clean restart');

# Apply more so resource.dat goes stale.
psql_or_bail(1, "INSERT INTO public.ts_off SELECT g, 'r2_' || g FROM generate_series(51,100) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_off") eq '100' }),
   '100 rows replicated');

# Disable track_commit_timestamp -- requires a postmaster restart, but our
# next step is going to crash and restart anyway.
psql_or_bail(2, "ALTER SYSTEM SET track_commit_timestamp = off");

# SIGKILL.
my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $sub_pid = <$fh>;
chomp($sub_pid);
close($fh);
kill 'KILL', $sub_pid;
pass('subscriber SIGKILLed');

select(undef, undef, undef, 2.0);

# Restart -- track_commit_timestamp is now off; reconcile sees stale file;
# recovery scan must error out.
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber back up');

# Wait for the apply worker to attempt start, then check the log for the
# expected ERROR. The bgworker manager will respawn it; we just need to
# verify the message appears.
my $logfile = "$sub_dir/log/postgresql-1.log";
# SpockTest may put logs elsewhere; adjust path if needed by reading test
# config or scanning $sub_dir/log/.
ok(wait_until(30, sub {
    log_contains($logfile, qr/track_commit_timestamp.*on/i)
}), "apply worker logged ERROR about track_commit_timestamp being off");

# Restore for cleanup.
psql_or_bail(2, "ALTER SYSTEM SET track_commit_timestamp = on");
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'restart';

destroy_cluster('Destroy 2-node cluster');
done_testing();
```

Note: the log path may need adjusting based on how `SpockTest` configures `log_directory` / `log_filename`. Inspect `tests/tap/SpockTest.pm` if `$sub_dir/log/postgresql-1.log` doesn't match. The pattern matching for the error message is tolerant (case-insensitive, just looks for "track_commit_timestamp" near "on").

```bash
chmod +x tests/tap/t/030_remote_commit_ts_recovery_track_commit_ts_off.pl
```

- [ ] **Step 5.2: Run the test — confirm it fails as expected**

```bash
./run_tests.sh t/030_remote_commit_ts_recovery_track_commit_ts_off.pl
```

Expected: the test FAILS at the "logged ERROR about track_commit_timestamp" check, because Task 4 has no guard. Without the guard, the recovery scan calls `TransactionIdGetCommitTsData` which returns false for every xid (no commit_ts data) and the scan logs "no commits found" instead of erroring.

- [ ] **Step 5.3: Commit**

```bash
git add tests/tap/t/030_remote_commit_ts_recovery_track_commit_ts_off.pl
git commit -m "test: add 030 (track_commit_timestamp off, currently failing)

Asserts the apply worker errors at startup if track_commit_timestamp
is off when the recovery scan would otherwise run. Currently fails --
guard lands in the next commit."
```

---

## Task 6: Add the `track_commit_timestamp` guard

**Files:**
- Modify: `src/spock_apply.c` — add the guard at the top of `recover_progress_timestamps_from_commit_ts`.

- [ ] **Step 6.1: Add the guard**

At the top of `recover_progress_timestamps_from_commit_ts` (added in Task 4.3), insert immediately after the variable declarations:

```c
if (!track_commit_timestamps)
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SPOCK %s: track_commit_timestamp must be on for spock.progress recovery",
					MySubscription->name),
			 errhint("Set track_commit_timestamp = on in postgresql.conf and restart.")));
```

The variable `track_commit_timestamps` (note plural) is the standard Postgres GUC global, declared in `access/commit_ts.h` (already included in Task 4.2).

- [ ] **Step 6.2: Build**

```bash
make -j4 install
```

Expected: clean build.

- [ ] **Step 6.3: Run test 030 — should now pass**

```bash
./run_tests.sh t/030_remote_commit_ts_recovery_track_commit_ts_off.pl
```

Expected: all subtests pass.

- [ ] **Step 6.4: Run test 027 to confirm no regression**

```bash
./run_tests.sh t/027_remote_commit_ts_recovery.pl
```

Expected: all subtests pass.

- [ ] **Step 6.5: Commit**

```bash
git add src/spock_apply.c
git commit -m "feat: error if track_commit_timestamp is off during ts recovery

Spock already requires track_commit_timestamp = on for conflict
resolution. Making the failure mode loud at apply-worker start (rather
than silently returning a degraded NULL state) is consistent with that
existing requirement and catches misconfiguration early."
```

---

## Task 7: Add the clean-shutdown skip-path test (029)

**Files:**
- Create: `tests/tap/t/029_remote_commit_ts_recovery_clean_shutdown.pl`

- [ ] **Step 7.1: Create the test**

Write `tests/tap/t/029_remote_commit_ts_recovery_clean_shutdown.pl`:

```perl
#!/usr/bin/perl
# =============================================================================
# Test: 029_remote_commit_ts_recovery_clean_shutdown.pl
#       Verify that on a CLEAN restart (resource.dat in sync with origin),
#       the recovery scan is SKIPPED and the loaded remote_commit_ts is
#       preserved. Confirmed by checking the apply-worker INFO log for the
#       "file in sync, skipping scan" line.
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    command_ok get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_pg_ready
);

sub wait_until {
    my ($timeout_s, $probe) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $probe->();
        select(undef, undef, undef, 0.25);
    }
    return 0;
}

sub log_grep_count {
    my ($logfile, $pattern) = @_;
    return 0 unless -f $logfile;
    open(my $fh, '<', $logfile) or return 0;
    my $count = 0;
    while (my $line = <$fh>) {
        $count++ if $line =~ /$pattern/;
    }
    close($fh);
    return $count;
}

create_cluster(2, 'Create 2-node cluster');

my $conf      = get_test_config();
my $host      = $conf->{host};
my $pg_bin    = $conf->{pg_bin};
my $ports     = $conf->{node_ports};
my $datadirs  = $conf->{node_datadirs};
my $dbname    = $conf->{db_name};
my $user      = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

psql_or_bail(1, "CREATE TABLE public.ts_clean (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.ts_clean (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'subscription is replicating');

psql_or_bail(1, "INSERT INTO public.ts_clean SELECT g, 'r_' || g FROM generate_series(1,50) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_clean") eq '50' }),
   '50 rows replicated');

# Capture pre-shutdown ts.
my $pre_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
ok($pre_ts ne '', "pre-shutdown remote_commit_ts: $pre_ts");

# Establish baseline: count "skipping scan" log lines before restart.
my $logfile = "$sub_dir/log/postgresql-1.log";
my $skip_before = log_grep_count($logfile, qr/ts recovery: file in sync, skipping scan/);

# CLEAN shutdown + restart. resource.dat should match origin LSN.
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok(-f "$sub_dir/spock/resource.dat", 'resource.dat written on clean stop');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber back up');
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'replicating after clean restart');

# Wait for the new "skipping scan" log line.
ok(wait_until(15, sub {
    log_grep_count($logfile, qr/ts recovery: file in sync, skipping scan/) > $skip_before
}), 'apply worker logged "file in sync, skipping scan" on clean restart');

# Confirm scan was NOT run (no "scanned ... xids" line for this restart).
my $scan_run = log_grep_count($logfile, qr/ts recovery: scanned \d+ xids/);
# We only count NEW occurrences relative to baseline, but since baseline is 0
# for a fresh cluster, any positive count would indicate the scan ran.
# Capture before/after to be precise:
# (For simplicity, this test asserts the skip log appeared. A run log alongside
#  it would also appear, indicating the skip path was NOT taken; the assertion
#  below covers that case.)
is(log_grep_count($logfile, qr/ts recovery: scanned \d+ xids.*recovered remote_commit_ts/),
   0,
   'scan did NOT run on clean restart (no "recovered remote_commit_ts" log line)');

# remote_commit_ts should still match pre-shutdown.
my $post_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
is($post_ts, $pre_ts, "remote_commit_ts preserved across clean restart");

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
```

```bash
chmod +x tests/tap/t/029_remote_commit_ts_recovery_clean_shutdown.pl
```

- [ ] **Step 7.2: Run the test**

```bash
./run_tests.sh t/029_remote_commit_ts_recovery_clean_shutdown.pl
```

Expected: all subtests pass. The skip-path INFO log was added in Task 4 and the recovery function is gated on `RECONCILE_FILE_IN_SYNC` — both already in place by this point.

- [ ] **Step 7.3: Commit**

```bash
git add tests/tap/t/029_remote_commit_ts_recovery_clean_shutdown.pl
git commit -m "test: add 029 (clean-shutdown skip path for ts recovery)

Verifies that on a clean restart, when resource.dat matches the origin
LSN, the recovery scan is skipped and the loaded remote_commit_ts is
preserved. Asserted via the INFO log line and absence of any 'scanned
xids' line for the restart."
```

---

## Task 8: Final regression sweep

- [ ] **Step 8.1: Run the full TAP suite**

```bash
cd tests/tap && ./run_tests.sh
```

Expected: all tests pass, including 008, 022, 023, 026, and the three new tests (027, 029, 030).

- [ ] **Step 8.2: Verify the commit log**

```bash
git log --oneline main..HEAD | head -20
```

Expected: a clean linear sequence — refactor, constants, test 027 (failing), implement, test 030 (failing), guard, test 029.

- [ ] **Step 8.3: No commit needed; the work is complete.**

If this lands as a PR, the user will decide whether to fold the design doc into the PR (currently uncommitted in the working tree).

---

## Self-Review

- **Spec coverage:** every section of the spec maps to a task: enum and skip-gating (Task 1, 4), constants (Task 2), scan logic (Task 4), `track_commit_timestamp` guard (Task 6), INFO logs (Task 4, 7), tests 027/029/030 (Tasks 3, 7, 5). Test 028 (idle/empty cluster) is deferred per the spec's discussion that triggering "no commits found" in a TAP test requires either a constant override or 1M+ unrelated xids — both are too heavy for v1.
- **Type consistency:** `ReconcileResult` enum (Task 1) is used in Task 4's call site. `target_origin` is `RepOriginId`. `running_max_ts` is `TimestampTz`. Constants are `int64`-safe via the `(int64) total_scanned` cast.
- **Placeholder scan:** every step has executable code or commands. The only soft spot is the log-path detection in tests 029 and 030 — handled with a comment instructing the implementer to inspect `SpockTest.pm` if the default path doesn't match.
