/*-------------------------------------------------------------------------
 *
 * spock_common.h
 * 		Common code for Spock.
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#ifndef SPOCK_COMMON_H
#define SPOCK_COMMON_H

#include "access/amapi.h"
#include "commands/trigger.h"

extern void AfterTriggerBeginQuery(void);

#if PG_VERSION_NUM >= 160000
#include "utils/usercontext.h"

#else /* The following only required for versions prior to PG16 */
/*
 * When temporarily changing to run as a different user, this structure
 * holds the details needed to restore the original state.
 */
typedef struct UserContext
{
	Oid			save_userid;
	int			save_sec_context;
	int			save_nestlevel;
} UserContext;
#endif

/* Function prototypes. */
extern void SPKSwitchToUntrustedUser(Oid userid, UserContext *context);
extern void SPKRestoreUserContext(UserContext *context);

extern bool SPKExecBRDeleteTriggers(EState *estate,
								 EPQState *epqstate,
								 ResultRelInfo *relinfo,
								 ItemPointer tupleid,
								 HeapTuple fdw_trigtuple);
extern void SPKExecARDeleteTriggers(EState *estate,
								 ResultRelInfo *relinfo,
								 ItemPointer tupleid,
								 HeapTuple fdw_trigtuple);

extern bool SPKExecBRUpdateTriggers(EState *estate,
								 EPQState *epqstate,
								 ResultRelInfo *relinfo,
								 ItemPointer tupleid,
								 HeapTuple fdw_trigtuple,
								 TupleTableSlot *slot);
extern void SPKExecARUpdateTriggers(EState *estate,
								 ResultRelInfo *relinfo,
								 ItemPointer tupleid,
								 HeapTuple fdw_trigtuple,
								 TupleTableSlot *slot,
								 List *recheckIndexes);

extern bool SPKExecBRInsertTriggers(EState *estate,
								 ResultRelInfo *relinfo,
								 TupleTableSlot *slot);
extern void SPKExecARInsertTriggers(EState *estate,
								 ResultRelInfo *relinfo,
								 TupleTableSlot *slot,
								 List *recheckIndexes);

extern bool IsIndexUsableForInsertConflict(Relation idxrel);
extern bool SpockRelationFindReplTupleByIndex(EState *estate,
								 Relation rel,
								 Relation idxrel,
								 LockTupleMode lockmode,
								 TupleTableSlot *searchslot,
								 TupleTableSlot *outslot);

extern void read_buf(int fd, void *buf, size_t nbytes, const char *filename);
extern void write_buf(int fd, const void *buf, size_t nbytes, const char *filename);

#endif /* SPOCK_COMMON_H */
