/*-------------------------------------------------------------------------
 *
 * spock_monitoring.c
 * 		support for monitoring and progress tracking
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"
#include "miscadmin.h"

#include "replication/slot.h"

#include "utils/pg_lsn.h"

#include "storage/ipc.h"
#include "storage/proc.h"

#include "pgstat.h"

#include "spock.h"
#include "spock_compat.h"

PG_FUNCTION_INFO_V1(spock_wait_slot_confirm_lsn);

/*
 * Having been called on an LR publisher, it waits for the subscriber's LSN
 * confirmation on the specified slot, or all logical slots if none are given,
 * to pass the supplied value. If no position is given, the latest commit LSN is
 * used. If the instance has no committed transactions, the latest WAL insert
 * position is used.
 *
 * It may get stuck in an infinite loop if no replication slots available.
 * Do not throw an error to allow cases when LR restarts or just starts after
 * this wait function.
 *
 * No timeout is offered, use a statement_timeout.
 */
Datum
spock_wait_slot_confirm_lsn(PG_FUNCTION_ARGS)
{
	XLogRecPtr	target_lsn;
	Name		slot_name;
	int			i;

	if (PG_ARGISNULL(0))
		slot_name = NULL;
	else
		slot_name = PG_GETARG_NAME(0);

	if (PG_ARGISNULL(1))
	{
		if (XLogRecPtrIsInvalid(XactLastCommitEnd))
			target_lsn = GetXLogInsertRecPtr();
		else
			target_lsn = XactLastCommitEnd;
	}
	else
		target_lsn = PG_GETARG_LSN(1);

	elog(DEBUG1, "waiting for %s to pass confirmed_flush position %X/%X",
		 slot_name == NULL ? "all local slots" : NameStr(*slot_name),
		 (uint32) (target_lsn >> 32), (uint32) target_lsn);

	do
	{
		XLogRecPtr	oldest_confirmed_lsn = InvalidXLogRecPtr;
		int			oldest_slot_pos = -1;
		int			rc;

		LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
		for (i = 0; i < max_replication_slots; i++)
		{
			ReplicationSlot *s = &ReplicationSlotCtl->replication_slots[i];

			if (!s->in_use)
				continue;

			if (slot_name != NULL && strncmp(NameStr(*slot_name), NameStr(s->data.name), NAMEDATALEN) != 0)
				continue;

			if (oldest_confirmed_lsn == InvalidXLogRecPtr
				|| (s->data.confirmed_flush != InvalidXLogRecPtr && s->data.confirmed_flush < oldest_confirmed_lsn))
			{
				oldest_confirmed_lsn = s->data.confirmed_flush;
				oldest_slot_pos = i;
			}
		}

		if (oldest_slot_pos >= 0)
			elog(DEBUG2, "oldest confirmed lsn is %X/%X on slot '%s', %u bytes left until %X/%X",
				 (uint32) (oldest_confirmed_lsn >> 32), (uint32) oldest_confirmed_lsn,
				 NameStr(ReplicationSlotCtl->replication_slots[oldest_slot_pos].data.name),
				 (uint32) (target_lsn - oldest_confirmed_lsn),
				 (uint32) (target_lsn >> 32), (uint32) target_lsn);

		LWLockRelease(ReplicationSlotControlLock);

		if (oldest_confirmed_lsn >= target_lsn)
			break;

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   1000);

		ResetLatch(&MyProc->procLatch);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		CHECK_FOR_INTERRUPTS();

	} while (1);

	PG_RETURN_VOID();
}
