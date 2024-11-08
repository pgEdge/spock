/*-------------------------------------------------------------------------
 *
 * spock_compat.h
 *             compatibility functions (mainly with different PG versions) 
 *
 * Copyright (c) 2021-2023, pgEdge
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


/* Redefine macros with a SUFFIX arg, to be passed-on to PG_TRY/PG_CATCH */
#define PG_ENSURE_ERROR_CLEANUP_SUFFIX(cleanup_function, arg, _suf)	\
	do { \
		before_shmem_exit(cleanup_function, arg); \
		PG_TRY(_suf)

#define PG_END_ENSURE_ERROR_CLEANUP_SUFFIX(cleanup_function, arg, _suf)	\
		cancel_before_shmem_exit(cleanup_function, arg); \
		PG_CATCH(_suf); \
		{ \
			cancel_before_shmem_exit(cleanup_function, arg); \
			cleanup_function (0, arg); \
			PG_RE_THROW(); \
		} \
		PG_END_TRY(_suf); \
	} while (0)

#define WaitLatchOrSocket(latch, wakeEvents, sock, timeout) \
	WaitLatchOrSocket(latch, wakeEvents, sock, timeout, PG_WAIT_EXTENSION)

#define WaitLatch(latch, wakeEvents, timeout) \
	WaitLatch(latch, wakeEvents, timeout, PG_WAIT_EXTENSION)

#define GetCurrentIntegerTimestamp() GetCurrentTimestamp()

#define pg_analyze_and_rewrite(parsetree, query_string, paramTypes, numParams) \
	pg_analyze_and_rewrite_fixedparams(parsetree, query_string, paramTypes, numParams, NULL)

#define CreateCommandTag(raw_parsetree) \
	CreateCommandTag(raw_parsetree->stmt)

#define PortalRun(portal, count, isTopLevel, dest, altdest, qc) \
	PortalRun(portal, count, isTopLevel, true, dest, altdest, qc)

#define ExecAlterExtensionStmt(stmt) \
	ExecAlterExtensionStmt(NULL, stmt)

#define ExecBRDeleteTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple) \
	ExecBRDeleteTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple, NULL, NULL, NULL)

#define ExecBRUpdateTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple, slot) \
	ExecBRUpdateTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple, slot, NULL, NULL)

#undef ExecEvalExpr
#define ExecEvalExpr(expr, econtext, isNull, isDone) \
	((*(expr)->evalfunc) (expr, econtext, isNull))

#define Form_pg_sequence Form_pg_sequence_data

#define ExecARUpdateTriggers(estate, relinfo, tupleid, fdw_trigtuple, newslot, recheckIndexes) \
	ExecARUpdateTriggers(estate, relinfo, NULL, NULL, tupleid, fdw_trigtuple, newslot, recheckIndexes, NULL, false)

#define ExecARInsertTriggers(estate, relinfo, slot, recheckIndexes) \
	ExecARInsertTriggers(estate, relinfo, slot, recheckIndexes, NULL)

#define ExecARDeleteTriggers(estate, relinfo, tupleid, fdw_trigtuple) \
	ExecARDeleteTriggers(estate, relinfo, tupleid, fdw_trigtuple, NULL, false)

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

#define ACL_OBJECT_RELATION OBJECT_TABLE
#define ACL_OBJECT_SEQUENCE OBJECT_SEQUENCE

#define DatumGetJsonb DatumGetJsonbP

#define spk_heap_attisnull(tup, attnum, tupledesc) \
	heap_attisnull(tup, attnum, tupledesc)

#define getObjectDescription(object) getObjectDescription(object, false)

#define replorigin_session_setup(node) \
	replorigin_session_setup(node, 0)

#define simple_heap_update(relation, otid, tup) \
	do \
	{ \
		TU_UpdateIndexes updateIndexes;	\
		simple_heap_update(relation, otid, tup, &updateIndexes);	\
	} while (false);

#define LogLogicalMessage(_prefix, _message, _size, _transactional) \
	LogLogicalMessage(_prefix, _message, _size, _transactional, false)

/* Must use this interface for access HeapTuple in ReorderBufferChange */
#define ReorderBufferChangeHeapTuple(change, tuple_type) \
	change->data.tp.tuple_type

#endif
