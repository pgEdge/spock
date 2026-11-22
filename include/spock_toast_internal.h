/*-------------------------------------------------------------------------
 *
 * spock_toast_internal.h
 *		Definitions shared by the TOAST divergence code
 *
 * spock_toast_suspect_record() (spock_toast_detect.c) records rows whose TOAST
 * columns may have diverged in spock.toast_suspect.
 * spock.toast_divergence_verify() (spock_toast_verify.c) checks them against
 * the winning node, and the repair worker's pass (spock_toast_repair.c)
 * settles each one against the winner's row (spock_toast_settle.c).  Both read
 * a batch of entries (spock_toast_queue.c) and fetch the winner's rows
 * (spock_toast_fetch.c) over libpq (spock_toast_conn.c).  Helpers the files
 * share are in spock_toast_util.c.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_TOAST_INTERNAL_H
#define SPOCK_TOAST_INTERNAL_H

#include "libpq-fe.h"
#include "lib/stringinfo.h"
#include "nodes/pg_list.h"
#include "replication/origin.h"
#include "utils/timestamp.h"

/* RepOriginId: PG 19 renamed it, spock_compat.h maps the name. */
#include "spock_compat.h"

/*
 * The search_path the TOAST divergence code runs its own SQL under.  A
 * function or operator someone created in another schema on the session's
 * path could otherwise be called in place of the built-in one, as whatever
 * user runs the SQL.  pg_temp is named last so a temporary table cannot
 * stand in for a catalog.
 */
#define TOAST_SEARCH_PATH "pg_catalog, pg_temp"

/*
 * In a batched query, the key object "k" of each row x of $1
 * (append_key_object()) read as columns k(pkcols_text), for pkjoin.
 */
#define KEY_FROM_PARAM "CROSS JOIN LATERAL jsonb_to_record(x.k) AS k(%s)"

/* One open connection per winner subscription for the length of a call. */
typedef struct VerifyConn
{
	Oid			subid;
	PGconn	   *conn;
	char	   *error;			/* connection failure, if any */
	bool		busy;			/* fetch_groups(): a query is outstanding */
	bool		for_repair;		/* opened by the repair worker */
} VerifyConn;

/*
 * The hash of one column of the row aliased t, the same expression on both
 * sides.  SHA-256 rather than md5(), which fails when OpenSSL runs in FIPS
 * mode.
 */
#define COLUMN_HASH_SQL "encode(sha256(convert_to(t.%s::text, 'UTF8')), 'hex')"

/*
 * How the grouped fetch left one entry.  Only WINNER_SETTLE entries carry
 * fetched row data and go through settle_one(); the rest are settled by the
 * fused pass directly.
 */
typedef enum WinnerFetchStatus
{
	WINNER_SETTLE,				/* row data fetched (present or not); settle
								 * it */
	WINNER_DROP,				/* table, columns or local row gone: delete
								 * the entry */
	WINNER_ORPHAN,				/* winner subscription dropped: delete the
								 * entry and report it */
	WINNER_WAIT,				/* winner subscription disabled: leave for
								 * later */
	WINNER_PENDING,				/* the winner has an older pending entry for
								 * the row: retry after it is repaired */
	WINNER_RETRY,				/* only inside fetch_wave(): its group's query
								 * failed, so fetch it again on its own */
	WINNER_FAIL					/* could not fetch: mark the entry failed */
} WinnerFetchStatus;

/*
 * The winner's already-fetched row data for one suspect entry, passed to
 * settle_one() so it does not need to do its own network round trip.
 */
typedef struct WinnerRow
{
	WinnerFetchStatus status;	/* how the grouped fetch left this entry */
	char	   *err;			/* WINNER_FAIL: the failure to record */
	bool		present;		/* the winner still has this row */
	bool	   *diff;			/* per suspect column: value differs from
								 * local */
	char	  **val;			/* per suspect column: winner value, or NULL
								 * when !diff or SQL NULL */
	TimestampTz ts;				/* winner row commit timestamp */
	RepOriginId origin;			/* winner row origin (already mapped: 0 ->
								 * winner node id) */
	char	   *pending;		/* WINNER_PENDING: the winner's older entry,
								 * described for last_error */
	char	  **stamp;			/* per suspect column: the winner's current
								 * value stamp (spock.toast_stamp() text), or
								 * NULL when it has none */
} WinnerRow;

/* What the batch read found of an entry's local row (read_entries()). */
typedef enum LocalRowState
{
	LOCAL_UNREAD,				/* not read: no usable table, columns or key */
	LOCAL_FOUND,
	LOCAL_MISSING,
	LOCAL_MULTI,				/* the key matched more than one row */
	LOCAL_ERROR					/* reading it failed */
} LocalRowState;

/*
 * One entry, copied out of the batch SELECT so it survives the per-entry
 * transactions.
 */
typedef struct RepairEntry
{
	Oid			relid;
	char	   *pkey;
	Oid			subid;
	bool		sub_enabled;
	Oid			winner_node_id; /* spock node id of the winner */
	bool		table_exists;
	char	   *qualname;		/* quoted schema.table */
	char	   *where_clause;	/* NULL if the key does not match */
	int			ncols;
	char	  **colnames;		/* quoted identifiers, attnum order */
	char	  **coltypes;		/* format_type() output, same order */
	int16	   *attnums;		/* the same columns' attnums */
	char	   *pkjoin;			/* t.col1 = k.col1::type1 AND ..., or NULL if
								 * the key does not fully match live columns */
	char	   *pkcols_text;	/* "col1" text, "col2" text, ...: the k(...)
								 * columns, cast to their types by pkjoin */
	int32		detect_count;
	TimestampTz detected_at;	/* with detect_count, which detection this
								 * is: a new entry starts at 1 again */
	char	   *orig_state;		/* the entry's state as read: 'suspect' or
								 * 'confirmed'.  Kept so a failed fetch or
								 * repair marks the entry back to the same
								 * state instead of promoting a suspect to
								 * confirmed. */
	LocalRowState local;		/* what the batch read found of the local row */
	char	   *local_err;		/* LOCAL_ERROR: why reading it failed */
	char	  **local_hash;		/* LOCAL_FOUND: per suspect column, attnum
								 * order, COLUMN_HASH_SQL, or NULL if that
								 * column is NULL */
	int64		est_bytes;		/* sum(pg_column_size(col)) for the suspect
								 * columns of the local row, 0 if not present */
	char	  **stored_ptr;		/* per suspect column, attnum order: the TOAST
								 * pointer recorded at detection, or NULL */
	char	   *first_winner_ts;	/* the entry's oldest winner timestamp in
									 * ISO 8601, for the winner's
									 * pending-entry check */
	char	   *winner_node_name;	/* for messages; NULL if unknown */
	bool		sub_exists;		/* the winner subscription still exists */
	char	   *reason;			/* detection's reason, or NULL */
} RepairEntry;

/*
 * Outcome of one repair attempt, for the counters.
 */
typedef enum
{
	REPAIR_REPAIRED,
	REPAIR_DROPPED,
	REPAIR_REMOTE_MISSING,
	REPAIR_WAITING,
	REPAIR_FAILED,
	REPAIR_ORPHANED
} RepairOutcome;

/* spock_toast_util.c */
extern const char *const toast_pinned_output[][2];
extern int	last_subxact_errcode;
extern bool run_in_subxact(void (*fn) (void *arg), void *arg, char **errmsg);
extern char *toast_pointer_text(Datum value);
extern uint32 cached_local_nodeid(void);
extern Oid	table_owner(Oid relid);
struct UserContext;				/* utils/usercontext.h, or spock_common.h on 15 */
extern int	owner_enter(Oid owner, struct UserContext *ucxt);
extern void owner_leave(struct UserContext *ucxt, int nestlevel);
extern int	spi_execute_as_owner(Oid relid, const char *sql, long count);

/* spock_toast_conn.c */
extern void conn_cancel(PGconn *conn);
extern PGresult *conn_get_result(PGconn *conn);
extern void conn_cache_prune(void);
extern void conn_drop_if_broken(VerifyConn *vc, const char *err,
								MemoryContext cxt);
extern void conn_cache_return(List *conns, bool pass_ok);
extern VerifyConn *verify_conn_get(List **conns, Oid subid, bool use_cache);
extern void verify_conns_close(List *conns);

/*
 * The entry as the batch read it, locked unless another transaction holds
 * it (see suspect_mark()).  $1 to $4 are ENTRY_GUARD_TYPES, set by
 * entry_guard_values().
 */
#define ENTRY_AS_READ_SQL \
	"SELECT relid, pkey FROM spock.toast_suspect " \
	"WHERE relid = $1 AND pkey = $2::jsonb AND detect_count = $3 " \
	"AND detected_at = $4 FOR UPDATE SKIP LOCKED"
#define ENTRY_GUARD_TYPES OIDOID, TEXTOID, INT4OID, TIMESTAMPTZOID

/* spock_toast_queue.c */
extern void entry_guard_values(const RepairEntry *e, Datum *values);
extern bool suspect_mark(const RepairEntry *e, const char *state,
						 const char *error, const char *differing,
						 const char *winner_ts, const char *winner_origin);
extern bool suspect_delete(const RepairEntry *e);
extern bool same_shape(const RepairEntry *a, const RepairEntry *b);
extern bool entry_usable(const RepairEntry *e);
extern void append_key_object(StringInfo buf, const RepairEntry *e,
							  bool for_fetch);
extern RepairEntry *read_entries(int max_rows, bool for_repair,
								 MemoryContext destcxt, int *nentries);

/* spock_toast_fetch.c */
extern void fetch_wave(RepairEntry **entries, int n, List **conns,
					   WinnerRow *rows, bool for_repair);

/* spock_toast_settle.c */
extern RepairOutcome settle_drop(RepairEntry *e, RepairOutcome outcome);
extern void clear_origin_globals(void);
extern void entry_mark(RepairEntry *e, const char *state, const char *error);
extern RepairOutcome settle_one(RepairEntry *e, WinnerRow *w);

#endif							/* SPOCK_TOAST_INTERNAL_H */
