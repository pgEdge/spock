/*-------------------------------------------------------------------------
 *
 * spock_toast_stamp.c
 *		Version stamps of out-of-line TOAST values
 *
 * A TOAST value is never changed in place: any change writes a new value
 * with a new value id, in the transaction doing the write.  So the
 * transaction that wrote a value's chunks identifies that version of it.
 * Spock applies a remote transaction under the origin node's id and commit
 * timestamp, which PostgreSQL records in pg_commit_ts, so every node that
 * holds a given version holds it in chunks whose xmin maps to the same
 * (node id, commit timestamp).  On the node that first wrote it the origin
 * reads as 0, which counts as that node's own id.
 *
 * The sender sends the stamp of each unchanged out-of-line column, and the
 * receiver compares it with its own value's stamp, to record a suspect only
 * when the versions differ.
 *
 * A stamp names the writing transaction, not the write.  A transaction that
 * writes the same column of a row twice, with values of the same size,
 * leaves the same stamp on either value.  If a receiver applies only the
 * first write, which spock.exception_behaviour = discard can do when the
 * second one fails there, it holds the first value under the stamp of the
 * second, and a later comparison finds them equal.  The skipped change is
 * in spock.exception_log.
 *
 * Nor do equal stamps prove equal values.  A statement replicated as a
 * statement (a table-rewriting ALTER TABLE through AutoDDL) rewrites the
 * values on every node under the same node id and commit timestamp,
 * whatever each node held.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/commit_ts.h"
#include "access/detoast.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/relation.h"
#include "access/skey.h"
#include "access/stratnum.h"
#include "access/table.h"
#include "access/transam.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "replication/origin.h"
#include "catalog/pg_type.h"
#include "storage/lmgr.h"
#include "storage/smgr.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

#include "spock_node.h"
#include "spock_toast_stamp.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * Whether a relation's main file can be read.  When a rewrite (VACUUM
 * FULL, CLUSTER, ALTER TABLE), TRUNCATE or DROP commits, PostgreSQL drops
 * the old file's buffers and truncates its first segment to zero length at
 * once, but unlinks it only at the next checkpoint (mdunlinkfork()).
 * Decoding a change made before that opens the old file through the
 * historic catalog, so both "missing" and "empty" mean gone: reading the
 * empty file ERRORs.
 */
static bool
relation_file_usable(Relation rel)
{
	SMgrRelation smgr = RelationGetSmgr(rel);

	return smgrexists(smgr, MAIN_FORKNUM) &&
		smgrnblocks(smgr, MAIN_FORKNUM) > 0;
}

/* Open the valid index of a TOAST relation without waiting for a lock. */
static Relation
open_toast_index(Relation toastrel)
{
	List	   *indexes = RelationGetIndexList(toastrel);
	ListCell   *lc;
	Relation	result = NULL;

	foreach(lc, indexes)
	{
		Oid			indexoid = lfirst_oid(lc);
		Relation	idx;

		if (!ConditionalLockRelationOid(indexoid, AccessShareLock))
			continue;
		idx = try_relation_open(indexoid, NoLock);
		if (idx == NULL)
		{
			UnlockRelationOid(indexoid, AccessShareLock);
			continue;
		}
		if (idx->rd_index != NULL && idx->rd_index->indisvalid)
		{
			result = idx;
			break;
		}
		relation_close(idx, AccessShareLock);
	}
	list_free(indexes);
	return result;
}

/* Start a reader with nothing open. */
void
toast_stamp_reader_init(ToastStampReader *reader)
{
	reader->toastrelid = InvalidOid;
	reader->toastrel = NULL;
	reader->toastidx = NULL;
	reader->failed = false;
}

/* Close what the reader holds open, and start it again. */
void
toast_stamp_reader_close(ToastStampReader *reader)
{
	if (reader->toastidx != NULL)
		relation_close(reader->toastidx, AccessShareLock);
	if (reader->toastrel != NULL)
		relation_close(reader->toastrel, AccessShareLock);
	toast_stamp_reader_init(reader);
}

/*
 * Make the reader hold toastrelid open, with its valid index, without
 * waiting for a lock.  A reader that failed for this relation stays failed,
 * so a lock held elsewhere costs one attempt per tuple, not one per column.
 */
static bool
reader_open(ToastStampReader *reader, Oid toastrelid)
{
	Relation	toastrel;

	if (reader->toastrelid == toastrelid)
		return !reader->failed;
	toast_stamp_reader_close(reader);
	reader->toastrelid = toastrelid;

	if (!ConditionalLockRelationOid(toastrelid, AccessShareLock))
	{
		reader->failed = true;
		return false;
	}
	toastrel = try_relation_open(toastrelid, NoLock);
	if (toastrel == NULL)
	{
		UnlockRelationOid(toastrelid, AccessShareLock);
		reader->failed = true;
		return false;
	}
	if (!relation_file_usable(toastrel) ||
		(reader->toastidx = open_toast_index(toastrel)) == NULL ||
		!relation_file_usable(reader->toastidx))
	{
		if (reader->toastidx != NULL)
		{
			relation_close(reader->toastidx, AccessShareLock);
			reader->toastidx = NULL;
		}
		relation_close(toastrel, AccessShareLock);
		reader->failed = true;
		return false;
	}
	reader->toastrel = toastrel;
	return true;
}

/*
 * Read the stamp of an out-of-line TOAST value.  Returns false, with no
 * error, whenever the stamp cannot be read: the value is not out of line on
 * disk, a lock is not free, the TOAST relation, its file or the chunk is
 * gone, the writing xid is older than pg_commit_ts keeps, commit
 * timestamps are off, the node is in recovery, or the commit timestamp is at
 * or before the PostgreSQL epoch.  The last one is the initial table sync:
 * it writes copied rows under a local replication origin id (not a Spock
 * node id, and it can be the same number on two nodes) with an epoch
 * timestamp (src/spock_sync.c, start_copy_target_tx()), so its stamps do not
 * identify a version.
 *
 * This runs in the walsender while decoding, where an ERROR would take down
 * the stream, so it never waits for a lock and checks before reading what it
 * can.  Decoding opens the TOAST relation through the historic catalog, and
 * after a VACUUM FULL, CLUSTER, ALTER TABLE, TRUNCATE or DROP the historic
 * files may be gone or already truncated to nothing, so both the table's
 * and the index's are checked first (relation_file_usable()).  Reading a
 * regular table is legal here: PostgreSQL only restricts it while
 * CheckXidAlive is set (streamed or prepared decoding, which Spock does not
 * register), and systable scans set bsysscan in any case.
 *
 * Checked in the PostgreSQL 15 and 18 sources, none of these ERROR for the
 * cases above: try_relation_open() with NoLock (missing relation returns
 * NULL), smgrexists() (mdexists opens with EXTENSION_RETURN_NULL),
 * smgrnblocks() on a file that exists, systable_beginscan_ordered() on a
 * valid, non-empty index, and
 * TransactionIdGetCommitTsData() for xids outside the kept range (returns
 * false).  ERROR paths that remain: an I/O error reading the index, heap or
 * pg_commit_ts (SimpleLruReadPage_ReadOnly()), pg_commit_ts truncated
 * between its range check and the read, or the relation's file truncated
 * between relation_file_usable() and the read.  All are rare, and a
 * walsender that errors reconnects and falls back on retry.
 * TransactionIdGetCommitTsData() also ERRORs when commit timestamps are
 * inactive although the GUC reads on, which happens on a standby; hence the
 * RecoveryInProgress() check.
 *
 * SnapshotAny is right: all chunks of a value are written by one transaction
 * and never updated, and GetNewOidWithIndex() never reuses a value id while
 * any chunk with that id, dead or alive, remains.
 */
bool
toast_stamp_read(Datum value, uint32 local_nodeid, SpockToastStamp *stamp)
{
	ToastStampReader reader;
	bool		found;

	toast_stamp_reader_init(&reader);
	found = toast_stamp_read_with(&reader, value, local_nodeid, stamp);
	toast_stamp_reader_close(&reader);
	return found;
}

/*
 * toast_stamp_read() through a reader that keeps the TOAST relation and its
 * index open between calls, for the columns of one tuple.  The caller closes
 * it with toast_stamp_reader_close() before the tuple is done.
 */
bool
toast_stamp_read_with(ToastStampReader *reader, Datum value,
					  uint32 local_nodeid, SpockToastStamp *stamp)
{
	struct varlena *attr = (struct varlena *) DatumGetPointer(value);
	struct varatt_external ptr;
	ScanKeyData keys[2];
	SysScanDesc scan;
	HeapTuple	chunk;
	TransactionId xmin = InvalidTransactionId;
	TimestampTz ts;
	RepOriginId origin;

	if (!VARATT_IS_EXTERNAL_ONDISK(attr))
		return false;
	if (!track_commit_timestamp || RecoveryInProgress())
		return false;

	VARATT_EXTERNAL_GET_POINTER(ptr, attr);

	if (!reader_open(reader, ptr.va_toastrelid))
		return false;

	ScanKeyInit(&keys[0], (AttrNumber) 1, BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(ptr.va_valueid));
	ScanKeyInit(&keys[1], (AttrNumber) 2, BTEqualStrategyNumber, F_INT4EQ,
				Int32GetDatum(0));
	scan = systable_beginscan_ordered(reader->toastrel, reader->toastidx,
									  SnapshotAny, 2, keys);
	chunk = systable_getnext_ordered(scan, ForwardScanDirection);
	if (chunk != NULL)
		xmin = HeapTupleHeaderGetRawXmin(chunk->t_data);
	systable_endscan_ordered(scan);

	/*
	 * The raw xmin, as get_tuple_origin() reads it: freezing keeps the xid,
	 * and its commit timestamp stays readable until pg_commit_ts is
	 * truncated past it.
	 */
	if (!TransactionIdIsNormal(xmin))
		return false;
	if (!TransactionIdGetCommitTsData(xmin, &ts, &origin))
		return false;
	if (ts <= 0)
		return false;

	stamp->nodeid = (origin == InvalidRepOriginId) ? local_nodeid : (uint32) origin;
	stamp->ts = ts;
	stamp->rawsize = ptr.va_rawsize;
	return true;
}

/* '<nodeid>/<ts in microseconds>/<rawsize>' */
char *
toast_stamp_to_text(const SpockToastStamp *stamp)
{
	return psprintf("%u/" INT64_FORMAT "/%d", stamp->nodeid,
					(int64) stamp->ts, stamp->rawsize);
}

/* The reverse of toast_stamp_to_text(); false for anything malformed. */
bool
toast_stamp_from_text(const char *txt, SpockToastStamp *stamp)
{
	unsigned long nodeid;
	long long	ts;
	int			rawsize;
	char		extra;

	if (txt == NULL ||
		sscanf(txt, "%lu/%lld/%d%c", &nodeid, &ts, &rawsize, &extra) != 3)
		return false;
	if (nodeid > PG_UINT16_MAX || ts <= 0 || rawsize < 0)
		return false;
	stamp->nodeid = (uint32) nodeid;
	stamp->ts = (TimestampTz) ts;
	stamp->rawsize = rawsize;
	return true;
}

/*
 * Give the current subtransaction its own commit timestamp and origin, so
 * the rows and TOAST chunks it writes carry them after the top-level commit.
 * This needs the pgEdge PostgreSQL patch that adds
 * SubTransactionIdSetCommitTsData(); keep every call for TOAST divergence
 * here, so the check for a patched build has one place to go.
 */
void
toast_stamp_set_subxact_commit_ts(TimestampTz ts, RepOriginId nodeid)
{
	SubTransactionIdSetCommitTsData(GetCurrentTransactionId(), ts, nodeid);
}

PG_FUNCTION_INFO_V1(spock_toast_stamp);

/* spock.toast_stamp("any"): see toast_stamp_read(). */
Datum
spock_toast_stamp(PG_FUNCTION_ARGS)
{
	Oid			argtype = get_fn_expr_argtype(fcinfo->flinfo, 0);
	SpockLocalNode *local_node;
	SpockToastStamp stamp;

	if (!OidIsValid(argtype))
		elog(ERROR, "could not determine the argument type");
	if (get_typlen(argtype) != -1)
		PG_RETURN_NULL();

	local_node = get_local_node(false, true);
	if (!toast_stamp_read(PG_GETARG_DATUM(0),
						  local_node ? local_node->node->id : 0, &stamp))
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(cstring_to_text(toast_stamp_to_text(&stamp)));
}
