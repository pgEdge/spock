/*-------------------------------------------------------------------------
 *
 * spock_toast_repair.c
 *		Background worker that verifies and repairs TOAST divergence
 *
 * One worker per database, started by the manager when
 * spock.toast_divergence_repair is on.  Each pass makes one fused
 * verify-and-repair run over a batch of suspects with
 * toast_divergence_process_run().  The next pass starts at once after a
 * full batch that settled entries, after spock.toast_divergence_interval
 * when less than a batch was found, and after
 * spock.toast_divergence_retry_interval when the pass settled nothing,
 * so that entries which can only wait or fail are not retried in a tight
 * loop.  Setting the latch ends a sleep early.
 *
 * Repaired rows must carry a chosen origin and commit timestamp, the
 * winner row's.  The commit timestamp record takes both from
 * replorigin_session_origin and
 * replorigin_session_origin_timestamp, and
 * RecordTransactionCommit() then advances whatever origin session this
 * process holds.  So the worker holds a session for a private origin,
 * spock_toast_repair_<dboid>, and sets the two globals for each repair
 * transaction.  The private origin's progress is meaningless and never
 * read.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"
#include "pgstat.h"

#include "access/xact.h"
#include "commands/extension.h"
#include "executor/spi.h"

#include "postmaster/interrupt.h"

#include "replication/origin.h"

#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"

#include "utils/guc.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

#include "spock.h"
#include "spock_compat.h"
#include "spock_node.h"
#include "spock_readonly.h"
#include "spock_toast_divergence.h"
#include "spock_toast_internal.h"
#include "spock_toast_repair.h"
#include "spock_worker.h"

typedef struct ToastRepairCounts
{
	int			repaired;
	int			dropped;
	int			remote_missing;
	int			waiting;
	int			failed;
	int			orphaned;		/* winner subscription dropped: entry deleted */
} ToastRepairCounts;

static void
private_origin_name(char *roname)
{
	snprintf(roname, NAMEDATALEN, "spock_toast_repair_%u", MyDatabaseId);
}

/*
 * Create the private origin if missing and set up this process's origin
 * session on it.  Runs inside a transaction: replorigin_by_name() and
 * replorigin_create() read and write the shared catalog.
 *
 * A worker that is exiting gives up its shmem slot before on_shmem_exit
 * releases its origin session.  A replacement worker started inside that
 * window fails here once with "replication origin ... is already active";
 * the manager starts it again after the restart delay.
 */
static void
setup_private_origin(void)
{
	char		roname[NAMEDATALEN];
	RepOriginId originid;

	private_origin_name(roname);

	StartTransactionCommand();
	originid = replorigin_by_name(roname, true);
	if (!OidIsValid(originid))
		originid = replorigin_create(roname);
	replorigin_session_setup(originid);
	CommitTransactionCommand();

	/* Nothing is stamped with the private origin; repairs set their own. */
	clear_origin_globals();
}

/*
 * Give up the origin session and drop the private origin, so a worker that
 * stops cleanly leaves no pg_replication_origin row behind.  A worker that
 * dies leaves the row, which the next one reuses.  A failure here is only
 * reported: the worker is exiting anyway.
 */
static void
drop_private_origin(void)
{
	char		roname[NAMEDATALEN];

	private_origin_name(roname);
	replorigin_session_reset();

	PG_TRY();
	{
		StartTransactionCommand();
		replorigin_drop_by_name(roname, true, false);
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		EmitErrorReport();
		FlushErrorState();
		AbortCurrentTransaction();
	}
	PG_END_TRY();
}

/*
 * A repair locks the local row.  A user transaction holding that row would
 * otherwise stall the worker for every table until it ends; after
 * spock.toast_divergence_lock_timeout the repair gives up instead, and the
 * entry is retried on a later pass.
 */
static void
set_lock_timeout(void)
{
	char		buf[32];

	snprintf(buf, sizeof(buf), "%d", spock_toast_divergence_lock_timeout);
	SetConfigOption("lock_timeout", buf, PGC_SUSET, PGC_S_OVERRIDE);
}

/* One verify-and-repair pass over a batch of entries. */

/*
 * The number of entries from entries[start] on that make up the next wave:
 * up to the batch size, or until their summed byte estimate reaches the
 * fetch-bytes budget, whichever comes first.
 */
static int
wave_size(RepairEntry *entries, int nentries, int start)
{
	int64		bytes = 0;
	int			n = 0;

	while (start + n < nentries)
	{
		bytes += entries[start + n].est_bytes;
		n++;
		if (n >= spock_toast_divergence_batch ||
			bytes >= spock_toast_divergence_fetch_bytes)
			break;
	}
	return n;
}

/*
 * Bring each connection back to a clean state after a fetch threw part way
 * (CHECK_FOR_INTERRUPTS(), or out of memory) with queries still out.  Left
 * alone, the next wave's PQsendQueryParams() on such a connection fails with
 * "another command is already in progress", and since PQstatus() still says
 * CONNECTION_OK the connection is never reset, so every later wave for that
 * winner fails.  A busy query is cancelled first, so this does not wait for
 * it; a connection no longer usable is closed, so later waves skip it.
 * Plain libpq calls, so this cannot throw.
 */
static void
conns_drain(List *conns)
{
	ListCell   *lc;

	foreach(lc, conns)
	{
		VerifyConn *vc = (VerifyConn *) lfirst(lc);
		PGresult   *r;

		vc->busy = false;
		if (vc->conn == NULL)
			continue;
		if (PQtransactionStatus(vc->conn) == PQTRANS_ACTIVE)
			conn_cancel(vc->conn);
		while ((r = PQgetResult(vc->conn)) != NULL)
			PQclear(r);
		if (PQstatus(vc->conn) != CONNECTION_OK)
		{
			PQfinish(vc->conn);
			vc->conn = NULL;
		}
	}
}

/*
 * Fetch a wave's winner rows in one read-only transaction, holding no row
 * locks.  If the fetch fails, every entry of the wave is marked
 * WINNER_FAIL with the error (drop and wait ones too: whatever they should
 * have been is found again on the next pass), and the next wave still runs.
 * Called with wavecxt current, and returns with it current.
 */
static void
fetch_wave_or_fail(RepairEntry **wave, int n, List **conns, WinnerRow *rows,
				   MemoryContext wavecxt)
{
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	PG_TRY();
	{
		fetch_wave(wave, n, conns, rows, true);
		PopActiveSnapshot();
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		ErrorData  *edata;
		char	   *ferr;
		int			k;

		MemoryContextSwitchTo(wavecxt);
		edata = CopyErrorData();
		ferr = pstrdup(edata->message);
		FlushErrorState();
		FreeErrorData(edata);
		clear_origin_globals();
		AbortOutOfAnyTransaction();
		MemoryContextSwitchTo(wavecxt);

		conns_drain(*conns);
		for (k = 0; k < n; k++)
		{
			rows[k].status = WINNER_FAIL;
			rows[k].err = ferr;
		}
	}
	PG_END_TRY();
	MemoryContextSwitchTo(wavecxt);
}

/*
 * Settle one entry by how the fetch left it, inside the caller's
 * transaction.
 */
static RepairOutcome
settle_by_status(RepairEntry *e, WinnerRow *w)
{
	switch (w->status)
	{
		case WINNER_SETTLE:
			return settle_one(e, w);
		case WINNER_DROP:
			return settle_drop(e, REPAIR_DROPPED);
		case WINNER_ORPHAN:
			return settle_drop(e, REPAIR_ORPHANED);
		case WINNER_WAIT:
			return REPAIR_WAITING;
		case WINNER_FAIL:

			/*
			 * An entry that could not be fetched, say because the winner is
			 * briefly down, keeps its own state: moving a suspect to
			 * 'confirmed' would show it as a real divergence until a later
			 * pass checks it again.
			 */
			entry_mark(e, e->orig_state, w->err);
			return REPAIR_FAILED;
		case WINNER_RETRY:
			break;
	}
	elog(ERROR, "unexpected winner fetch status %d in repair", w->status);
	return REPAIR_FAILED;		/* keep compiler quiet */
}

/*
 * Settle one entry in its own top-level transaction, so its commit carries
 * that entry's own origin and timestamp.  An error is recorded on the entry
 * in a transaction of its own and warned about, and the pass goes on.
 * Called with wavecxt current, and returns with it current.
 */
static RepairOutcome
settle_entry(RepairEntry *e, WinnerRow *w, MemoryContext wavecxt)
{
	volatile RepairOutcome outcome = REPAIR_FAILED;

	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed in settle_entry");

	PG_TRY();
	{
		outcome = settle_by_status(e, w);
		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		/* The abort frees the transaction context: leave it first. */
		MemoryContextSwitchTo(wavecxt);
		edata = CopyErrorData();
		FlushErrorState();

		/* Never stamp the bookkeeping commit with a repair's origin. */
		clear_origin_globals();
		AbortOutOfAnyTransaction();
		MemoryContextSwitchTo(wavecxt);

		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		if (SPI_connect() == SPI_OK_CONNECT)
		{
			entry_mark(e, e->orig_state, edata->message);
			SPI_finish();
		}
		PopActiveSnapshot();
		CommitTransactionCommand();
		MemoryContextSwitchTo(wavecxt);

		ereport(WARNING,
				(errmsg("SPOCK toast repair: could not repair a row of relation %u: %s",
						e->relid, edata->message),
				 errhint("The row's key is in spock.toast_divergence.")));
		FreeErrorData(edata);
		outcome = REPAIR_FAILED;
	}
	PG_END_TRY();

	clear_origin_globals();
	MemoryContextSwitchTo(wavecxt);
	return outcome;
}

static void
count_outcome(ToastRepairCounts *counts, RepairOutcome outcome)
{
	switch (outcome)
	{
		case REPAIR_REPAIRED:
			counts->repaired++;
			break;
		case REPAIR_DROPPED:
			counts->dropped++;
			break;
		case REPAIR_REMOTE_MISSING:
			counts->remote_missing++;
			break;
		case REPAIR_WAITING:
			counts->waiting++;
			break;
		case REPAIR_FAILED:
			counts->failed++;
			break;
		case REPAIR_ORPHANED:
			counts->orphaned++;
			break;
	}
}

/*
 * One verify-and-repair pass over up to max_rows entries.  Call it outside a
 * transaction: the batch read is one transaction, each wave's fetch another
 * (read-only, no row locks), and each entry's settle its own.  Requires an
 * origin session on this process.
 *
 * Verify and repair take one round trip per wave: the winner compares
 * hashes and returns only the columns that differ, and settle_one() applies
 * them under the conflict rule the apply worker uses.
 */
static bool
toast_divergence_process_run(int max_rows, ToastRepairCounts *counts)
{
	MemoryContext passcxt,
				oldcxt;
	RepairEntry *entries = NULL;
	int			nentries = 0;
	int			wave_start;
	List	   *volatile conns = NIL;
	volatile bool pass_ok = true;

	memset(counts, 0, sizeof(*counts));

	conn_cache_prune();

	passcxt = AllocSetContextCreate(CurrentMemoryContext, "toast process pass",
									ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(passcxt);

	/*
	 * This handler catches what the per-wave and per-entry ones cannot: an
	 * error reading the batch, or one thrown while a per-entry handler was
	 * recording a failure.  Without it those would leave the libpq
	 * connections open and take the worker down with them.
	 */
	PG_TRY();
	{
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		if (SPI_connect() != SPI_OK_CONNECT)
			elog(ERROR, "SPI_connect failed in toast_divergence_process_run");
		entries = read_entries(max_rows, true, passcxt, &nentries);
		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();

		for (wave_start = 0; wave_start < nentries && !got_SIGTERM;)
		{
			int			wave_n = wave_size(entries, nentries, wave_start);
			MemoryContext wavecxt;
			RepairEntry **wave;
			WinnerRow  *rows;
			int			k;

			/* The wave's results live here, deleted when the wave is done. */
			wavecxt = AllocSetContextCreate(passcxt, "toast process wave",
											ALLOCSET_DEFAULT_SIZES);
			MemoryContextSwitchTo(wavecxt);
			wave = palloc(wave_n * sizeof(RepairEntry *));
			rows = palloc0(wave_n * sizeof(WinnerRow));
			for (k = 0; k < wave_n; k++)
				wave[k] = &entries[wave_start + k];

			fetch_wave_or_fail(wave, wave_n, (List **) &conns, rows, wavecxt);
			for (k = 0; k < wave_n && !got_SIGTERM; k++)
				count_outcome(counts, settle_entry(wave[k], &rows[k], wavecxt));

			MemoryContextSwitchTo(passcxt);
			MemoryContextDelete(wavecxt);
			wave_start += wave_n;
		}
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(passcxt);
		clear_origin_globals();
		EmitErrorReport();
		FlushErrorState();
		AbortOutOfAnyTransaction();
		MemoryContextSwitchTo(passcxt);
		pass_ok = false;
	}
	PG_END_TRY();

	clear_origin_globals();
	MemoryContextSwitchTo(passcxt);
	conn_cache_return((List *) conns, pass_ok);
	MemoryContextSwitchTo(oldcxt);
	MemoryContextDelete(passcxt);
	return pass_ok;
}

/*
 * One pass: a single fused run that reads a batch of suspects, fetches the
 * winners for the rows that need them, and settles each one.  It manages its
 * own transactions and snapshots (it starts and commits one transaction per
 * entry, so each commit carries that entry's own origin and timestamp) and
 * reports its own per-entry errors, so a bad row does not stop the pass.
 *
 * Returns how long to sleep, in milliseconds, before the next pass.  A
 * pass that failed has its error logged already.
 */
static long
toast_repair_pass(void)
{
	static int	last_waiting = -1;
	ToastRepairCounts rc = {0};
	int			processed;
	int			settled;
	long		sleep_ms;
	bool		failed;

	failed = !toast_divergence_process_run(spock_toast_divergence_batch, &rc);

	settled = rc.repaired + rc.dropped + rc.remote_missing + rc.orphaned;
	processed = settled + rc.waiting + rc.failed;

	/*
	 * A pass that only found the same entries still waiting is not logged
	 * again: entries can wait for a long time, as for a disabled
	 * subscription, and the pass repeats every retry interval.
	 */
	if (processed > 0 &&
		(settled > 0 || rc.failed > 0 || rc.waiting != last_waiting))
		elog(LOG, "SPOCK toast repair: processed %d | repaired %d, cleared %d, "
			 "remote missing %d, waiting %d, failed %d, orphaned %d",
			 processed, rc.repaired, rc.dropped, rc.remote_missing,
			 rc.waiting, rc.failed, rc.orphaned);
	last_waiting = rc.waiting;
	if (rc.orphaned > 0)
		ereport(WARNING,
				(errmsg("SPOCK toast repair: removed %d TOAST suspect entries whose winner subscription no longer exists",
						rc.orphaned),
				 errhint("Those rows may still differ from the removed node's last values; compare the tables with ACE if that matters.")));

	/*
	 * The pass failed, or entries were read but none could be settled: a
	 * winner down or disabled.
	 */
	if (failed || (processed > 0 && settled == 0))
		sleep_ms = spock_toast_divergence_retry_interval * 1000L;
	/* A full batch that made progress: more are probably queued. */
	else if (processed >= spock_toast_divergence_batch)
		sleep_ms = 0;
	else
		sleep_ms = spock_toast_divergence_interval;
	return sleep_ms;
}

/*
 * Whether this database still has the extension and a local node, checked
 * before every pass.  The manager exits without them and stops starting
 * this worker, but nothing stops a running one, which would otherwise fail
 * every pass, or with the node gone keep deleting entries as orphans.
 */
static bool
node_still_here(void)
{
	bool		here;

	StartTransactionCommand();
	here = OidIsValid(get_extension_oid(EXTENSION_NAME, true)) &&
		get_local_node(false, true) != NULL;
	CommitTransactionCommand();
	return here;
}

void
spock_toast_repair_main(Datum main_arg)
{
	int			slot = DatumGetInt32(main_arg);
	int			i;
	bool		paused = false;

	spock_worker_attach(slot, SPOCK_WORKER_REPAIR);

	Assert(CurrentResourceOwner == NULL);
	CurrentResourceOwner = ResourceOwnerCreate(NULL, "spock toast repair");

	/* Like the apply worker: only replica triggers fire on our writes. */
	SetConfigOption("session_replication_role", "replica",
					PGC_SUSET, PGC_S_OVERRIDE);
	SetConfigOption("synchronous_commit",
					spock_synchronous_commit ? "local" : "off",
					PGC_BACKEND, PGC_S_OVERRIDE);

	set_lock_timeout();

	/*
	 * The same text-output settings spock.toast_divergence_verify() pins
	 * through its SET clauses, so hashes and values compare equal across
	 * nodes.  The remote side is pinned per connection in spock_toast_conn.c.
	 */
	for (i = 0; toast_pinned_output[i][0] != NULL; i++)
		SetConfigOption(toast_pinned_output[i][0], toast_pinned_output[i][1],
						PGC_BACKEND, PGC_S_OVERRIDE);

	/*
	 * And the search_path verify() pins, so the worker's SQL cannot call a
	 * function or operator another user created in place of a built-in one.
	 * Code a repair write runs, such as a trigger enabled ALWAYS or REPLICA,
	 * gets the same path.
	 */
	SetConfigOption("search_path", TOAST_SEARCH_PATH,
					PGC_BACKEND, PGC_S_OVERRIDE);

	setup_private_origin();

	elog(LOG, "SPOCK toast repair: worker started for database %u", MyDatabaseId);

	while (!got_SIGTERM)
	{
		int			rc;
		long		sleep_ms;

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
			if (!spock_toast_divergence_repair)
				break;
			set_lock_timeout();
			/* Reconnect so the winner side takes the new lock_timeout too. */
			toast_divergence_close_cached_conns();
		}

		if (!node_still_here())
		{
			elog(LOG, "SPOCK toast repair: no spock extension or local node in database %u, exiting",
				 MyDatabaseId);
			break;
		}

		/*
		 * With the node fully read-only the apply workers stop, and so does
		 * this: a repair writes user rows.  Entries wait for the mode to end.
		 */
		if (spock_readonly == READONLY_ALL)
		{
			if (!paused)
				elog(LOG, "SPOCK toast repair: spock.readonly is all, repairs paused");
			paused = true;
			sleep_ms = spock_toast_divergence_retry_interval * 1000L;
		}
		else
		{
			paused = false;
			sleep_ms = toast_repair_pass();
		}

		/*
		 * A wait inside the pass resets the latch a SIGTERM or SIGHUP set, so
		 * look at the flags before sleeping, or the request waits out the
		 * whole sleep.
		 */
		if (got_SIGTERM || ConfigReloadPending)
			sleep_ms = 0;

		/*
		 * A zero timeout still notices postmaster death and lets the loop
		 * check for SIGTERM and a reload between passes.
		 */
		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   sleep_ms);
		ResetLatch(&MyProc->procLatch);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		CHECK_FOR_INTERRUPTS();
	}

	toast_divergence_close_cached_conns();
	drop_private_origin();
	proc_exit(0);
}
