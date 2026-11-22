/*-------------------------------------------------------------------------
 *
 * spock_toast_stamp.h
 *		Version stamps of out-of-line TOAST values
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_TOAST_STAMP_H
#define SPOCK_TOAST_STAMP_H

#include "fmgr.h"
#include "access/xlogdefs.h"
#include "utils/timestamp.h"

/* RepOriginId: PG 19 renamed it, spock_compat.h maps the name. */
#include "spock_compat.h"

/*
 * The version of a TOAST value: the node and commit timestamp of the
 * transaction that wrote it, and its raw size.  Every node holding that
 * version holds it in chunks stamped the same way, because Spock applies a
 * remote transaction under the origin node's id and commit timestamp.
 */
typedef struct SpockToastStamp
{
	uint32		nodeid;			/* Spock node id (a RepOriginId value) */
	TimestampTz ts;				/* commit timestamp of the writing xact */
	int32		rawsize;		/* va_rawsize, VARHDRSZ included */
} SpockToastStamp;

static inline bool
toast_stamp_equal(const SpockToastStamp *a, const SpockToastStamp *b)
{
	return a->nodeid == b->nodeid && a->ts == b->ts &&
		a->rawsize == b->rawsize;
}

/* Holds a TOAST relation open across the columns of one tuple. */
typedef struct ToastStampReader
{
	Oid			toastrelid;
	struct RelationData *toastrel;
	struct RelationData *toastidx;
	bool		failed;			/* could not open toastrelid */
} ToastStampReader;

extern bool toast_stamp_read(Datum value, uint32 local_nodeid,
							 SpockToastStamp *stamp);
extern void toast_stamp_reader_init(ToastStampReader *reader);
extern bool toast_stamp_read_with(ToastStampReader *reader, Datum value,
								  uint32 local_nodeid, SpockToastStamp *stamp);
extern void toast_stamp_reader_close(ToastStampReader *reader);
extern char *toast_stamp_to_text(const SpockToastStamp *stamp);
extern bool toast_stamp_from_text(const char *txt, SpockToastStamp *stamp);
extern void toast_stamp_set_subxact_commit_ts(TimestampTz ts,
											  RepOriginId nodeid);
extern Datum spock_toast_stamp(PG_FUNCTION_ARGS);

#endif							/* SPOCK_TOAST_STAMP_H */
