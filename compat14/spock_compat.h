/*-------------------------------------------------------------------------
 *
 * spock_compat.h
 *             compatibility functions (mainly with different PG versions) 
 *
 * Copyright (c) 2021-2022, OSCG Partners, LLC
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_COMPAT_H
#define SPOCK_COMPAT_H

#include "access/amapi.h"
#include "access/heapam.h"
#include "access/table.h"
#include "access/tableam.h"
#include "utils/varlena.h"

#define PG_ENSURE_ERROR_CLEANUP_SUFFIX(cleanup_function, arg, _suf)	\
		PG_ENSURE_ERROR_CLEANUP(cleanup_function, arg)

#define PG_END_ENSURE_ERROR_CLEANUP_SUFFIX(cleanup_function, arg, _suf)	\
		PG_END_ENSURE_ERROR_CLEANUP(cleanup_function, arg)

#define WaitLatchOrSocket(latch, wakeEvents, sock, timeout) \
	WaitLatchOrSocket(latch, wakeEvents, sock, timeout, PG_WAIT_EXTENSION)

#define WaitLatch(latch, wakeEvents, timeout) \
	WaitLatch(latch, wakeEvents, timeout, PG_WAIT_EXTENSION)

#define GetCurrentIntegerTimestamp() GetCurrentTimestamp()

#define pg_analyze_and_rewrite(parsetree, query_string, paramTypes, numParams) \
	pg_analyze_and_rewrite(parsetree, query_string, paramTypes, numParams, NULL)

#define CreateCommandTag(raw_parsetree) \
	CreateCommandTag(raw_parsetree->stmt)

#define PortalRun(portal, count, isTopLevel, dest, altdest, qc) \
	PortalRun(portal, count, isTopLevel, true, dest, altdest, qc)

#define ExecAlterExtensionStmt(stmt) \
	ExecAlterExtensionStmt(NULL, stmt)

#define ExecBRDeleteTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple) \
 	ExecBRDeleteTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple, NULL)

#undef ExecEvalExpr
#define ExecEvalExpr(expr, econtext, isNull, isDone) \
	((*(expr)->evalfunc) (expr, econtext, isNull))

#define Form_pg_sequence Form_pg_sequence_data

#define InitResultRelInfo(resultRelInfo, resultRelationDesc, resultRelationIndex, instrument_options) \
	InitResultRelInfo(resultRelInfo, resultRelationDesc, resultRelationIndex, NULL, instrument_options)

#define ExecARUpdateTriggers(estate, relinfo, tupleid, fdw_trigtuple, newslot, recheckIndexes) \
	ExecARUpdateTriggers(estate, relinfo, tupleid, fdw_trigtuple, newslot, recheckIndexes, NULL)

#define ExecARInsertTriggers(estate, relinfo, slot, recheckIndexes) \
	ExecARInsertTriggers(estate, relinfo, slot, recheckIndexes, NULL)

#define ExecARDeleteTriggers(estate, relinfo, tupleid, fdw_trigtuple) \
	ExecARDeleteTriggers(estate, relinfo, tupleid, fdw_trigtuple, NULL)

#define SPKstandard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, sentToRemote, qc) \
	standard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc)

#define SPKnext_ProcessUtility_hook(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, sentToRemote, qc) \
	next_ProcessUtility_hook(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc)

#define SPKCreateTrigger(stmt, queryString, relOid, refRelOid, constraintOid, indexOid, isInternal) \
	CreateTrigger(stmt, queryString, relOid, refRelOid, constraintOid, indexOid, InvalidOid, InvalidOid, NULL, isInternal, false);

#define	SPKDoCopy(stmt, queryString, processed) \
	do \
	{ \
		ParseState* pstate = make_parsestate(NULL); \
		DoCopy(pstate, stmt, -1, 0, processed); \
		free_parsestate(pstate); \
	} while (false);

#define SPKReplicationSlotCreate(name, db_specific, persistency) ReplicationSlotCreate(name, db_specific, persistency)

#ifndef rbtxn_has_catalog_changes
#define rbtxn_has_catalog_changes(txn) (txn->has_catalog_changes)
#endif

#define ExecInitExtraTupleSlot(estate) \
	ExecInitExtraTupleSlot(estate, NULL, &TTSOpsHeapTuple)

#define ACL_OBJECT_RELATION OBJECT_TABLE
#define ACL_OBJECT_SEQUENCE OBJECT_SEQUENCE

#define DatumGetJsonb DatumGetJsonbP

#define spk_heap_attisnull(tup, attnum, tupledesc) \
	heap_attisnull(tup, attnum, tupledesc)

#define getObjectDescription(object) getObjectDescription(object, false)
#define addRTEPermissionInfo(rteperminfos, rte) \
	*rteperminfos = NIL;

#define OutputPluginUpdateProgress(ctx, false) \
			OutputPluginUpdateProgress(ctx)

#define SwitchToUntrustedUser(userid, context) ((void)0)
#define RestoreUserContext(context) ((void)0)

/* Must use this interface for access HeapTuple in ReorderBufferChange */
#define ReorderBufferChangeHeapTuple(change, tuple_type) \
	&change->data.tp.tuple_type->tuple

#endif
