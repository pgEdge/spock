/*-------------------------------------------------------------------------
 *
 * spock_common.c
 * 		Common code for Spock.
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "miscadmin.h"
#include "fmgr.h"

#include "executor/executor.h"
#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "storage/proc.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/pg_lsn.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"

#include "spock_common.h"
#include "spock_compat.h"

#if PG_VERSION_NUM >= 170000 && PG_VERSION_NUM < 180000
static StrategyNumber spock_get_equal_strategy_number(Oid opclass);
#endif
static int spock_build_replindex_scan_key(ScanKey skey, Relation rel,
							Relation idxrel, TupleTableSlot *searchslot);

/*
 * Temporarily switch to a new user ID.
 *
 * SECURITY_RESTRICTED_OPERATION is imposed and a new GUC nest level is
 * created so that any settings changes can be rolled back.
 */
void
SPKSwitchToUntrustedUser(Oid userid, UserContext *context)
{
    int     sec_context;

	/* Get the current user ID and security context. */
	GetUserIdAndSecContext(&context->save_userid,
						   &context->save_sec_context);
	sec_context = context->save_sec_context;

    /*
     * This user can SET ROLE to the target user, but not the other way
     * around, so protect ourselves against the target user by setting
     * SECURITY_RESTRICTED_OPERATION to prevent certain changes to the
     * session state. Also set up a new GUC nest level, so that we can
     * roll back any GUC changes that may be made by code running as the
     * target user, inasmuch as they could be malicious.
     */
	sec_context |= SECURITY_RESTRICTED_OPERATION;
	SetUserIdAndSecContext(userid, sec_context);
	context->save_nestlevel = NewGUCNestLevel();
}

/*
 * Switch back to the original user ID.
 *
 * If we created a new GUC nest level, also roll back any changes that were
 * made within it.
 */
void
SPKRestoreUserContext(UserContext *context)
{
	if (context->save_nestlevel != -1)
		AtEOXact_GUC(false, context->save_nestlevel);
	SetUserIdAndSecContext(context->save_userid, context->save_sec_context);
}

bool
SPKExecBRDeleteTriggers(EState *estate,
						EPQState *epqstate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple)
{
	UserContext		ucxt;
	bool			ret;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ret = ExecBRDeleteTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple);
	RestoreUserContext(&ucxt);

	return ret;
}

void
SPKExecARDeleteTriggers(EState *estate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple)
{
	UserContext		ucxt;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ExecARDeleteTriggers(estate, relinfo, tupleid, fdw_trigtuple);
	RestoreUserContext(&ucxt);
}

bool
SPKExecBRUpdateTriggers(EState *estate,
						EPQState *epqstate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple,
						TupleTableSlot *slot)
{
	UserContext		ucxt;
	bool			ret;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ret = ExecBRUpdateTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple, slot);
	RestoreUserContext(&ucxt);

	return ret;
}

void
SPKExecARUpdateTriggers(EState *estate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple,
						TupleTableSlot *slot,
						List *recheckIndexes)
{
	UserContext		ucxt;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ExecARUpdateTriggers(estate, relinfo, tupleid, fdw_trigtuple, slot, recheckIndexes);
	RestoreUserContext(&ucxt);
}

bool
SPKExecBRInsertTriggers(EState *estate,
						ResultRelInfo *relinfo,
						TupleTableSlot *slot)
{
	UserContext		ucxt;
	bool			ret;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ret = ExecBRInsertTriggers(estate, relinfo, slot);
	RestoreUserContext(&ucxt);

	return ret;
}

void
SPKExecARInsertTriggers(EState *estate,
						ResultRelInfo *relinfo,
						TupleTableSlot *slot,
						List *recheckIndexes)
{
	UserContext		ucxt;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ExecARInsertTriggers(estate, relinfo, slot, recheckIndexes);
	RestoreUserContext(&ucxt);
}

/*
 * Check if an index is usable for INSERT conflict detection (Insert-Exists).
 *
 * Usable indexes must be:
 * - Valid
 * - Unique and immediate (not deferrable)
 * - Can be partial
 *
 * PK and RI indexes are excluded, as they are already used by default for
 * conflict resolution.
 */
bool
IsIndexUsableForInsertConflict(Relation idxrel)
{
	/* Skip if already used for replica identity or primary key */
	if (idxrel->rd_index->indisprimary || idxrel->rd_index->indisreplident)
		return false;

	/* Skip if index is invalid, non-unique, non-immediate */
	if (!idxrel->rd_index->indisvalid ||
		!idxrel->rd_index->indisunique ||
		!idxrel->rd_index->indimmediate)
		return false;

	return true;
}

/*
 * Check whether the index key attributes in the two tuples are all non-NULL.
 *
 * This function does not compare actual values for equality. Instead, it verifies
 * that all index key columns (excluding dropped and generated ones) are non-NULL
 * in both tuples.
 * In SQL semantics, NULLs are not considered equals, even when both sides are
 * NULLs. so any NULL in a key column implies that they do not match.
 */
static bool
index_keys_have_nonnulls(TupleTableSlot *slot1, TupleTableSlot *slot2, Relation idxrel,
			 ScanKey skey, int ncols)
{
	int			i;
	int			attrnum;

	Assert(slot1->tts_tupleDescriptor->natts ==
		   slot2->tts_tupleDescriptor->natts);

	slot_getallattrs(slot1);
	slot_getallattrs(slot2);

	/* Check equality of the attributes. */
	for (i = 0; i < ncols; i++)
	{
		Form_pg_attribute att;

		attrnum = idxrel->rd_index->indkey.values[skey[i].sk_attno - 1] - 1;

		att = TupleDescAttr(slot1->tts_tupleDescriptor, attrnum);

		/*
		 * Ignore dropped and generated columns as the publisher doesn't send
		 * those
		 */
		if (att->attisdropped || att->attgenerated)
			continue;

		/*
		 * If either value is NULL, then according to SQL semantics,
		 * they are not considered equal, even if both are NULL.
		 */
		if (slot1->tts_isnull[attrnum] || slot2->tts_isnull[attrnum])
			return false;

	}

	return true;
}

/*
 * If the index is partial (has a WHERE clause), prepare the predicate
 * expression for evaluation.
 */
static ExprState *
SpockPreparePredicateExpr(Relation idxrel, EState *estate)
{
	List *predExprList = NIL;

	if (heap_attisnull(idxrel->rd_indextuple, Anum_pg_index_indpred, NULL))
		return NULL;

	predExprList = RelationGetIndexPredicate(idxrel);
	if (predExprList == NIL)
		return NULL;

	return ExecPrepareQual(predExprList, estate);
}

/*
 * Check if the predicate matches by evaluating the index predicate on the
 * given tuple slot. This is used for both remote and local tuples.
 *
 * Returns true if the predicate matches, or if the predicate is NULL.
 */
static bool
SpockPredicateMatches(EState *estate, ExprState *predExpr, TupleTableSlot *slot)
{
	ExprContext *econtext;

	if (!predExpr)
		return true;

	ResetPerTupleExprContext(estate);
	econtext = GetPerTupleExprContext(estate);
	econtext->ecxt_scantuple = slot;
	return ExecQual(predExpr, econtext);
}

/*
 * Search the relation 'rel' for tuple using the index.
 *
 * If a matching tuple is found, lock it with lockmode, fill the slot with its
 * contents, and return true.  Return false otherwise.
 */
bool
SpockRelationFindReplTupleByIndex(EState *estate,
							 Relation rel,
							 Relation idxrel,
							 LockTupleMode lockmode,
							 TupleTableSlot *searchslot,
							 TupleTableSlot *outslot)
{
	ScanKeyData skey[INDEX_MAX_KEYS];
	int			skey_attoff;
	IndexScanDesc scan;
	SnapshotData snap;
	TransactionId xwait;
	bool		found;
	ExprState *predExpr;

	Assert(idxrel->rd_index->indisunique);
	predExpr = SpockPreparePredicateExpr(idxrel, estate);

	/*
	 * Partial unique indexes only apply to rows that satisfy the predicate.
	 * So if the remote tuple doesn't match the predicate, it's not part of
	 * the index and can't conflict with anything in it.
	 *
	 * We can skip scanning the index entirely in that case.
	 */
	if (!SpockPredicateMatches(estate, predExpr, searchslot))
		return false;

	InitDirtySnapshot(snap);

	/* Build scan key. */
	skey_attoff = spock_build_replindex_scan_key(skey, rel, idxrel, searchslot);

	/* Start an index scan. */
	scan = index_beginscan(rel, idxrel, &snap, skey_attoff, 0);

retry:
	found = false;

	index_rescan(scan, skey, skey_attoff, NULL, 0);

	/* Try to find the tuple */
	while (index_getnext_slot(scan, ForwardScanDirection, outslot))
	{
		if (!index_keys_have_nonnulls(outslot, searchslot, idxrel, skey, skey_attoff))
			continue;

		/* Skip if local tuple does not satisfy the index predicate */
		if (!SpockPredicateMatches(estate, predExpr, outslot))
			continue;

		ExecMaterializeSlot(outslot);
		xwait = TransactionIdIsValid(snap.xmin) ?
			snap.xmin : snap.xmax;

		/*
		 * If the tuple is locked, wait for locking transaction to finish and
		 * retry.
		 */
		if (TransactionIdIsValid(xwait))
		{
			XactLockTableWait(xwait, NULL, NULL, XLTW_None);
			goto retry;
		}

		/* Found our tuple and it's not locked */
		found = true;
		break;
	}

	/* Found tuple, try to lock it in the lockmode. */
	if (found)
	{
		TM_FailureData tmfd;
		TM_Result	res;

		PushActiveSnapshot(GetLatestSnapshot());

		res = table_tuple_lock(rel, &(outslot->tts_tid), GetActiveSnapshot(),
							   outslot,
							   GetCurrentCommandId(false),
							   lockmode,
							   LockWaitBlock,
							   0 /* don't follow updates */ ,
							   &tmfd);

		PopActiveSnapshot();

		switch (res)
		{
			case TM_Ok:
				break;
			case TM_Updated:
				/* XXX: Improve handling here */
				if (ItemPointerIndicatesMovedPartitions(&tmfd.ctid))
					ereport(DEBUG1,
							(errcode(ERRCODE_T_R_SERIALIZATION_FAILURE),
							 errmsg("tuple to be locked was already moved to another partition due to concurrent update, retrying")));
				else
					ereport(DEBUG1,
							(errcode(ERRCODE_T_R_SERIALIZATION_FAILURE),
							 errmsg("concurrent update, retrying")));
				goto retry;
			case TM_Deleted:
				/* XXX: Improve handling here */
				ereport(DEBUG1,
						(errcode(ERRCODE_T_R_SERIALIZATION_FAILURE),
						 errmsg("concurrent delete, retrying")));
				goto retry;
			case TM_Invisible:
				elog(ERROR, "attempted to lock invisible tuple");
				break;
			default:
				elog(ERROR, "unexpected table_tuple_lock status: %u", res);
				break;
		}
	}

	index_endscan(scan);

	return found;
}

#if PG_VERSION_NUM >= 170000 && PG_VERSION_NUM < 180000
/*
 * Return the appropriate strategy number which corresponds to the equality
 * operator.
 */
static StrategyNumber
spock_get_equal_strategy_number(Oid opclass)
{
	Oid			am = get_opclass_method(opclass);

	return get_equal_strategy_number_for_am(am);
}
#endif

/*
 * Setup a ScanKey for a search in the relation 'rel' for a tuple 'key' that
 * is setup to match 'rel' (*NOT* idxrel!).
 *
 * Returns how many columns to use for the index scan.
 */
static int
spock_build_replindex_scan_key(ScanKey skey, Relation rel, Relation idxrel,
						 TupleTableSlot *searchslot)
{
	int			index_attoff;
	int			skey_attoff = 0;
	Datum		indclassDatum;
	oidvector  *opclass;
	int2vector *indkey = &idxrel->rd_index->indkey;

#if PG_VERSION_NUM < 160000
	bool        isnull;
	indclassDatum = SysCacheGetAttr(INDEXRELID, idxrel->rd_indextuple,
										   Anum_pg_index_indclass, &isnull);
	Assert(!isnull);
#else
	indclassDatum = SysCacheGetAttrNotNull(INDEXRELID, idxrel->rd_indextuple,
										   Anum_pg_index_indclass);
#endif

	opclass = (oidvector *) DatumGetPointer(indclassDatum);

	/* Build scankey for every non-expression attribute in the index. */
	for (index_attoff = 0; index_attoff < IndexRelationGetNumberOfKeyAttributes(idxrel);
		 index_attoff++)
	{
		Oid			operator;
		Oid			optype;
		Oid			opfamily;
		RegProcedure regop;
		int			table_attno = indkey->values[index_attoff];
		StrategyNumber eq_strategy;

		if (!AttributeNumberIsValid(table_attno))
		{
			/*
			 * XXX: Currently, we don't support expressions in the scan key,
			 * see code below.
			 */
			continue;
		}

		/*
		 * Load the operator info.  We need this to get the equality operator
		 * function for the scan key.
		 */
		optype = get_opclass_input_type(opclass->values[index_attoff]);
		opfamily = get_opclass_family(opclass->values[index_attoff]);
#if PG_VERSION_NUM < 170000
		eq_strategy = BTEqualStrategyNumber;
#elif PG_VERSION_NUM < 180000
		eq_strategy = spock_get_equal_strategy_number(opclass->values[index_attoff]);
#else
		/* PostgreSQL commit 622f678 */
		eq_strategy = IndexAmTranslateCompareType(COMPARE_EQ, idxrel->rd_rel->relam, opfamily, false);
#endif
		operator = get_opfamily_member(opfamily, optype,
									   optype,
									   eq_strategy);

		if (!OidIsValid(operator))
			elog(ERROR, "missing operator %d(%u,%u) in opfamily %u",
				 eq_strategy, optype, optype, opfamily);

		regop = get_opcode(operator);

		/* Initialize the scankey. */
		ScanKeyInit(&skey[skey_attoff],
					index_attoff + 1,
					eq_strategy,
					regop,
					searchslot->tts_values[table_attno - 1]);

		skey[skey_attoff].sk_collation = idxrel->rd_indcollation[index_attoff];

		/* Check for null value. */
		if (searchslot->tts_isnull[table_attno - 1])
			skey[skey_attoff].sk_flags |= (SK_ISNULL | SK_SEARCHNULL);

		skey_attoff++;
	}

	/* There must always be at least one attribute for the index scan. */
	Assert(skey_attoff > 0);

	return skey_attoff;
}


/*
 * Read exactly nbytes into buf or ERROR out. Never returns partial.
 */
void
read_buf(int fd, void *buf, size_t nbytes, const char *filename)
{
	const char *fname = filename ? filename : "file";
	size_t off = 0;

	/* Input validation (CWE-20) */
	if (fd < 0 || buf == NULL || nbytes == 0 || nbytes > (size_t)SSIZE_MAX)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid fd/buffer/size for %s", fname)));

	while (off < nbytes)
	{
		ssize_t n = read(fd, (char *)buf + off, nbytes - off);

		if (n == 0)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
						errmsg("could not read file \"%s\": read %zu of %zu",
							fname, off, nbytes)));

			/* One consolidated error path: EOF or hard error */
		if (n < 0)
		{
			if (errno == EINTR)
				continue; /* retry */

			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("could not read file \"%s\": %m", fname)));

		}
		off += (size_t)n;
	}
}


/*
 * Write exactly nbytes into file or ERROR out. Never partial.
 */
void
write_buf(int fd, const void *buf, size_t nbytes, const char *filename)
{
	const char *fname = filename ? filename : "file";
	size_t off = 0;

	/* Input validation (CWE-20) */
	if (fd < 0 || buf == NULL || nbytes == 0 || nbytes > (size_t)SSIZE_MAX)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid fd/buffer/size for %s", fname)));

	while (off < nbytes)
	{
		ssize_t		n = write(fd, (char *)buf + off, nbytes - off);

		if (n <= 0)
		{
			if (errno == EINTR)
				continue; /* retry */

			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
						errmsg("could not write file \"%s\": %m", fname)));
		}
		off += (size_t)n;
	}
}

TimestampTz
str_to_timestamptz(const char *s)
{
	return DatumGetTimestampTz(DirectFunctionCall3(timestamptz_in,
												   CStringGetDatum(s),
												   ObjectIdGetDatum(InvalidOid),
												   Int32GetDatum(-1)));
}

XLogRecPtr
str_to_lsn(const char *s)
{
	return DatumGetLSN(DirectFunctionCall1(pg_lsn_in, CStringGetDatum(s)));
}
