/*-------------------------------------------------------------------------
 *
 * spock_output.c
 *		  Logical Replication output plugin
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

#include "mb/pg_wchar.h"
#include "replication/logical.h"

#include "miscadmin.h"
#include "access/commit_ts.h"
#include "access/xact.h"
#include "executor/executor.h"
#include "catalog/namespace.h"
#include "storage/fd.h"
#include "storage/lmgr.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/guc.h"
#include "replication/origin.h"
#include "replication/syncrep.h"
#include "replication/walsender_private.h"
#include "storage/ipc.h"

#include "spock_output_plugin.h"
#include "spock.h"
#include "spock_output_config.h"
#include "spock_executor.h"
#include "spock_node.h"
#include "spock_output_proto.h"
#include "spock_queue.h"
#include "spock_repset.h"
#include "spock_worker.h"

#ifdef HAVE_REPLICATION_ORIGINS
#include "replication/origin.h"
#endif

extern void		_PG_output_plugin_init(OutputPluginCallbacks *cb);

/* Global variables */
bool	spock_replication_repair_mode = false;

/* Local functions */
static void pg_decode_startup(LogicalDecodingContext * ctx,
							  OutputPluginOptions *opt, bool is_init);
static void pg_decode_shutdown(LogicalDecodingContext * ctx);
static void pg_decode_begin_txn(LogicalDecodingContext *ctx,
					ReorderBufferTXN *txn);
static void pg_decode_commit_txn(LogicalDecodingContext *ctx,
					 ReorderBufferTXN *txn, XLogRecPtr commit_lsn);
static void pg_decode_change(LogicalDecodingContext *ctx,
				 ReorderBufferTXN *txn, Relation rel,
				 ReorderBufferChange *change);
static void pg_decode_message(LogicalDecodingContext *ctx,
							  ReorderBufferTXN *txn,
							  XLogRecPtr message_lsn,
							  bool transactional,
							  const char *prefix,
							  Size message_size,
							  const char *message);
static void pg_decode_truncate(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
							   int nrelations, Relation relations[],
							   ReorderBufferChange *change);

#ifdef HAVE_REPLICATION_ORIGINS
static bool pg_decode_origin_filter(LogicalDecodingContext *ctx,
						RepOriginId origin_id);
#endif

static void send_startup_message(LogicalDecodingContext *ctx,
		SpockOutputData *data, bool last_message);
static void maybe_send_schema(LogicalDecodingContext *ctx,
							  ReorderBufferChange *change,
							  Relation relation);
static bool can_replicate_truncate(List *repsets);

static bool startup_message_sent = false;

typedef struct SPKRelMetaCacheEntry
{
	Oid relid;
	/* Does the client have this relation cached? */
	bool is_cached;
	/* Entry is valid and not due to be purged */
	bool is_valid;
} SPKRelMetaCacheEntry;

#define RELMETACACHE_INITIAL_SIZE 128
static HTAB *RelMetaCache = NULL;
static MemoryContext RelMetaCacheContext = NULL;
static int InvalidRelMetaCacheCnt = 0;
static int MyWalSenderIdx = 0;

static bool						slot_group_on_exit_set = false;
static SpockOutputSlotGroup	   *slot_group = NULL;
static bool						slot_group_skip_xact = false;

/* ts of the last transaction processed by the slot group */
static TimestampTz				slot_group_last_commit_ts = 0;

static char					   *MyOutputNodeName = NULL;
static RepOriginId				MyOutputNodeId = InvalidRepOriginId;

#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

static void spock_output_join_slot_group(NameData slot_name);
static void spock_output_leave_slot_group(void);
static void spock_output_plugin_shmem_request(void);
static void spock_output_plugin_shmem_startup(void);
static Size spock_output_plugin_shmem_size(int nworkers);
static void spock_output_plugin_on_exit(int code, Datum arg);

static void relmetacache_init(MemoryContext decoding_context);
static SPKRelMetaCacheEntry *relmetacache_get_relation(SpockOutputData *data,
													   Relation rel);
static void relmetacache_flush(void);
static void relmetacache_prune(void);

static void spkReorderBufferCleanSerializedTXNs(const char *slotname);

/* specify output plugin callbacks */
void
_PG_output_plugin_init(OutputPluginCallbacks *cb)
{
	AssertVariableIsOfType(&_PG_output_plugin_init, LogicalOutputPluginInit);

	cb->startup_cb = pg_decode_startup;
	cb->begin_cb = pg_decode_begin_txn;
	cb->change_cb = pg_decode_change;
	cb->commit_cb = pg_decode_commit_txn;
	cb->message_cb = pg_decode_message;
	cb->truncate_cb = pg_decode_truncate;
#ifdef HAVE_REPLICATION_ORIGINS
	cb->filter_by_origin_cb = pg_decode_origin_filter;
#endif
	cb->shutdown_cb = pg_decode_shutdown;
}

static bool
check_binary_compatibility(SpockOutputData *data)
{
	if (data->client_binary_basetypes_major_version != PG_VERSION_NUM / 100)
		return false;

	if (data->client_binary_bigendian_set
		&& data->client_binary_bigendian != server_bigendian())
	{
		elog(DEBUG1, "Binary mode rejected: Server and client endian mismatch");
		return false;
	}

	if (data->client_binary_sizeofdatum != 0
		&& data->client_binary_sizeofdatum != sizeof(Datum))
	{
		elog(DEBUG1, "Binary mode rejected: Server and client sizeof(Datum) mismatch");
		return false;
	}

	if (data->client_binary_sizeofint != 0
		&& data->client_binary_sizeofint != sizeof(int))
	{
		elog(DEBUG1, "Binary mode rejected: Server and client sizeof(int) mismatch");
		return false;
	}

	if (data->client_binary_sizeoflong != 0
		&& data->client_binary_sizeoflong != sizeof(long))
	{
		elog(DEBUG1, "Binary mode rejected: Server and client sizeof(long) mismatch");
		return false;
	}

	if (data->client_binary_float4byval_set
		&& data->client_binary_float4byval != server_float4_byval())
	{
		elog(DEBUG1, "Binary mode rejected: Server and client float4byval mismatch");
		return false;
	}

	if (data->client_binary_float8byval_set
		&& data->client_binary_float8byval != server_float8_byval())
	{
		elog(DEBUG1, "Binary mode rejected: Server and client float8byval mismatch");
		return false;
	}

	if (data->client_binary_intdatetimes_set
		&& data->client_binary_intdatetimes != server_integer_datetimes())
	{
		elog(DEBUG1, "Binary mode rejected: Server and client integer datetimes mismatch");
		return false;
	}

	return true;
}

/* initialize this plugin */
static void
pg_decode_startup(LogicalDecodingContext * ctx, OutputPluginOptions *opt,
				  bool is_init)
{
	SpockOutputData	   *data = palloc0(sizeof(SpockOutputData));

	/* Join our slot-group if possible */
	spock_output_join_slot_group(ctx->slot->data.name);

	/* Short lived memory context for individual messages */
	data->context = AllocSetContextCreate(ctx->context,
										  "spock output msg context",
										  ALLOCSET_DEFAULT_SIZES);
	data->allow_internal_basetypes = false;
	data->allow_binary_basetypes = false;


	ctx->output_plugin_private = data;

	/*
	 * This is replication start and not slot initialization.
	 *
	 * Parse and validate options passed by the client.
	 */
	if (!is_init)
	{
		bool	started_tx = false;
		SpockLocalNode *node;
		MemoryContext oldctx;

		/*
		 * Discover our WalSender slot index. We use this to work around a problem
		 * in SyncRepWaitForLSN() later.
		 */
		if (MyWalSnd != NULL)
			MyWalSenderIdx = (MyWalSnd - WalSndCtl->walsnds) + 1;

		/*
		 * There's a potential corruption bug in PostgreSQL 10.1, 9.6.6, 9.5.10
		 * and 9.4.15 that can cause reorder buffers to accumulate duplicated
		 * transactions. See
		 *	 https://www.postgresql.org/message-id/CAMsr+YHdX=XECbZshDZ2CZNWGTyw-taYBnzqVfx4JzM4ExP5xg@mail.gmail.com
		 *
		 * We can defend against this by doing our own cleanup of any serialized
		 * txns in the reorder buffer on startup.
		 */
		spkReorderBufferCleanSerializedTXNs(NameStr(MyReplicationSlot->data.name));

		if (!IsTransactionState())
		{
			StartTransactionCommand();
			started_tx = true;
		}
		node = get_local_node(false, false);
		data->local_node_id	= node->node->id;

		/*
		 * Remember our own node.name for quick access out write_origin().
		 */
		oldctx = MemoryContextSwitchTo(TopMemoryContext);
		MyOutputNodeName = pstrdup(node->node->name);
		MyOutputNodeId = node->node->id;
		MemoryContextSwitchTo(oldctx);

		/*
		 * Ideally we'd send the startup message immediately. That way
		 * it'd arrive before any error we emit if we see incompatible
		 * options sent by the client here. That way the client could
		 * possibly adjust its options and reconnect. It'd also make
		 * sure the client gets the startup message in a timely way if
		 * the server is idle, since otherwise it could be a while
		 * before the next callback.
		 *
		 * The decoding plugin API doesn't let us write to the stream
		 * from here, though, so we have to delay the startup message
		 * until the first change processed on the stream, in a begin
		 * callback.
		 *
		 * If we ERROR there, the startup message is buffered but not
		 * sent since the callback didn't finish. So we'd have to send
		 * the startup message, finish the callback and check in the
		 * next callback if we need to ERROR.
		 *
		 * That's a bit much hoop jumping, so for now ERRORs are
		 * immediate. A way to emit a message from the startup callback
		 * is really needed to change that.
		 */
		startup_message_sent = false;

		/* Now parse the rest of the params and ERROR if we see any we don't recognise */
		oldctx = MemoryContextSwitchTo(ctx->context);
		process_parameters(ctx->output_plugin_options, data);
		MemoryContextSwitchTo(oldctx);

		if (data->client_min_proto_version > SPOCK_PROTO_VERSION_NUM)
			ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("client sent min_proto_version=%d but we only support protocol %d or lower",
					 data->client_min_proto_version, SPOCK_PROTO_VERSION_NUM)));

		if (data->client_max_proto_version < SPOCK_PROTO_MIN_VERSION_NUM)
			ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("client sent max_proto_version=%d but we only support protocol %d or higher",
					data->client_max_proto_version, SPOCK_PROTO_MIN_VERSION_NUM)));

		/*
		 * Set correct protocol format.
		 *
		 * This is the output plugin protocol format, this is different
		 * from the individual fields binary vs textual format.
		 */
		if (data->client_protocol_format != NULL
				&& strcmp(data->client_protocol_format, "json") == 0)
		{
			oldctx = MemoryContextSwitchTo(ctx->context);
			data->api = spock_init_api(SpockProtoJson);
			opt->output_type = OUTPUT_PLUGIN_TEXTUAL_OUTPUT;
			MemoryContextSwitchTo(oldctx);
		}
		else if ((data->client_protocol_format != NULL
				 && strcmp(data->client_protocol_format, "native") == 0)
				 || data->client_protocol_format == NULL)
		{
			oldctx = MemoryContextSwitchTo(ctx->context);
			data->api = spock_init_api(SpockProtoNative);
			opt->output_type = OUTPUT_PLUGIN_BINARY_OUTPUT;

			if (data->client_no_txinfo)
			{
				elog(WARNING, "no_txinfo option ignored for protocols other than json");
				data->client_no_txinfo = false;
			}
			MemoryContextSwitchTo(oldctx);
		}
		else
		{
			ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("client requested protocol %s but only \"json\" or \"native\" are supported",
					data->client_protocol_format)));
		}

		/* check for encoding match if specific encoding demanded by client */
		if (data->client_expected_encoding != NULL
				&& strlen(data->client_expected_encoding) != 0)
		{
			int wanted_encoding = pg_char_to_encoding(data->client_expected_encoding);

			if (wanted_encoding == -1)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("unrecognised encoding name %s passed to expected_encoding",
								data->client_expected_encoding)));

			if (opt->output_type == OUTPUT_PLUGIN_TEXTUAL_OUTPUT)
			{
				/*
				 * datum encoding must match assigned client_encoding in text
				 * proto, since everything is subject to client_encoding
				 * conversion.
				 */
				if (wanted_encoding != pg_get_client_encoding())
					ereport(ERROR,
							(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							 errmsg("expected_encoding must be unset or match client_encoding in text protocols")));
			}
			else
			{
				/*
				 * currently in the binary protocol we can only emit encoded
				 * datums in the server encoding. There's no support for encoding
				 * conversion.
				 */
				if (wanted_encoding != GetDatabaseEncoding())
					ereport(ERROR,
							(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							 errmsg("encoding conversion for binary datum not supported yet"),
							 errdetail("expected_encoding %s must be unset or match server_encoding %s",
								 data->client_expected_encoding, GetDatabaseEncodingName())));
			}

			data->field_datum_encoding = wanted_encoding;
		}

		/*
		 * It's obviously not possible to send binary representation of data
		 * unless we use the binary output.
		 */
		if (opt->output_type == OUTPUT_PLUGIN_BINARY_OUTPUT &&
			data->client_want_internal_basetypes)
		{
			data->allow_internal_basetypes =
				check_binary_compatibility(data);
		}

		if (opt->output_type == OUTPUT_PLUGIN_BINARY_OUTPUT &&
			data->client_want_binary_basetypes &&
			data->client_binary_basetypes_major_version == PG_VERSION_NUM / 100)
		{
			data->allow_binary_basetypes = true;
		}

		/*
		 * 9.4 lacks origins info so don't forward it.
		 *
		 * There's currently no knob for clients to use to suppress
		 * this info and it's sent if it's supported and available.
		 */
		if (PG_VERSION_NUM/100 == 904)
			data->forward_changeset_origins = false;
		else
			data->forward_changeset_origins = true;

		if (started_tx)
			CommitTransactionCommand();

		relmetacache_init(ctx->context);
	}

	/* So we can identify the process type in Valgrind logs */
	VALGRIND_PRINTF("SPOCK: spock worker output_plugin\n");
	/* For incremental leak checking */
	VALGRIND_DISABLE_ERROR_REPORTING;
	VALGRIND_DO_LEAK_CHECK;
	VALGRIND_ENABLE_ERROR_REPORTING;
}

/*
 * BEGIN callback
 */
static void
pg_decode_begin_txn(LogicalDecodingContext *ctx, ReorderBufferTXN *txn)
{
	SpockOutputData* data = (SpockOutputData*)ctx->output_plugin_private;
	bool send_replication_origin = data->forward_changeset_origins;
	MemoryContext old_ctx;

	/* Reset repair mode */
	spock_replication_repair_mode = false;

	/*
	 * Check if we are a member of a replication slot-group and if so,
	 * if another member is already working on this transaction. If
	 * nobody does, then claim this transaction for us and start
	 * working.
	 */
	if (slot_group != NULL)
	{
		LWLockAcquire(slot_group->lock, LW_EXCLUSIVE);

		/*
		 * Just do it regardless of whether we are skipping this
		 * transaction or not. Let's be safe and simply move the
		 * commit ts forward.
		 *
		 * Save the slot_group->last_commit_ts to the static local
		 * variable to avoid further locking.
		 */
		if (slot_group->last_commit_ts < txn->xact_time.commit_time)
		{
			slot_group_last_commit_ts = slot_group->last_commit_ts;
			slot_group->last_commit_ts = txn->xact_time.commit_time;
		}

		elog(DEBUG1, "SPOCK: slot-group '%s': current transaction %u commit order ts"
			 "last_commit_ts: " INT64_FORMAT " current:" INT64_FORMAT,
			 NameStr(slot_group->name),
			 txn->xid,
			 slot_group_last_commit_ts,
			 slot_group->last_commit_ts);

		if (slot_group->last_lsn >= txn->end_lsn)
		{
			elog(DEBUG1, "SPOCK: slot-group '%s' skipping transaction with end_lsn %X/%X"
					  " - last_lsn %X/%X",
				 NameStr(slot_group->name),
				 (uint32)(txn->end_lsn >> 32),
				 (uint32)(txn->end_lsn),
				 (uint32)(slot_group->last_lsn >> 32),
				 (uint32)(slot_group->last_lsn));

			LWLockRelease(slot_group->lock);

			/* We don't need to protect this variable with a lock. */
			slot_group_skip_xact = true;
			return;
		}

		elog(DEBUG1, "SPOCK: slot-group '%s' sending transaction with end_lsn %X/%X",
			 NameStr(slot_group->name),
			 (uint32)(txn->end_lsn >> 32),
			 (uint32)(txn->end_lsn));

		slot_group->last_lsn = txn->end_lsn;
		LWLockRelease(slot_group->lock);
	}

	old_ctx = MemoryContextSwitchTo(data->context);

	VALGRIND_DO_ADDED_LEAK_CHECK;

	if (!startup_message_sent)
		send_startup_message(ctx, data, false /* can't be last message */);

	OutputPluginPrepareWrite(ctx, !send_replication_origin);
	data->api->write_begin(ctx->out, data, txn);

#ifdef HAVE_REPLICATION_ORIGINS
	if (send_replication_origin)
	{
		/* Message boundary */
		OutputPluginWrite(ctx, false);
		OutputPluginPrepareWrite(ctx, true);

		/*
		 * On transactions that originated locally generate the origin
		 * message with our own and node.id. Remote transactions
		 * that we forward will have the node.id of what we got from
		 * the remote, which is the real origin of the transaction.
		 */
		if (data->api->write_origin)
		{
			if (txn->origin_id == InvalidRepOriginId)
			{
				data->api->write_origin(ctx->out, MyOutputNodeId,
										txn->origin_lsn);
			}
			else
			{
				data->api->write_origin(ctx->out, txn->origin_id,
										txn->origin_lsn);
			}
		}

		/*
		 * The commit timestamp may be zero, which is fine in case of a
		 * restart. This information should always follow origin to ensure
		 * that the origin of the commit ts is known.
		 */
		if (data->api->write_commit_order)
		{
			/* Message boundary */
			OutputPluginWrite(ctx, false);
			OutputPluginPrepareWrite(ctx, true);

			data->api->write_commit_order(ctx->out, slot_group_last_commit_ts);
		}
	}
#endif

	OutputPluginWrite(ctx, true);

	Assert(CurrentMemoryContext == data->context);
	MemoryContextSwitchTo(old_ctx);
}

/*
 * COMMIT callback
 */
static void
pg_decode_commit_txn(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
					 XLogRecPtr commit_lsn)
{
	SpockOutputData	   *data = (SpockOutputData*)ctx->output_plugin_private;
	MemoryContext		old_ctx;
	XLogRecPtr			end_lsn = txn->end_lsn - MyWalSenderIdx;

	/* Reset repair mode */
	spock_replication_repair_mode = false;

	/*
	 * If we are in slot-group skip transaction mode, we simply end
	 * it here and wait for the next transaction.
	 */
	if (slot_group_skip_xact)
	{
		slot_group_skip_xact = false;
		return;
	}

	old_ctx = MemoryContextSwitchTo(data->context);

	/*
	 * If we are configured for synchronous replication we must wait
	 * for this end_lsn to be confirmed according to the configuration
	 * of synchronous_standby_names before sending it to the subscriber.
	 * A failover to the synchronous standby may otherwise forget a
	 * transaction already sent to a Spock node.
	 *
	 * There currently is a problem in SyncRepWaitForLSN() in that it
	 * expects the wait queue to be sorted by LSN and that there are
	 * no duplicate LSNs in it. There is no good reason for uniqueness
	 * in that list, but the corresponding Assert code will TRAP if
	 * we don't use a unique LSN. We therefore use our WalSndCtl->walsnds
	 * slot number +1 and subtract that from the end_lsn. This works as
	 * long as that offset is smaller than the size of the commit record
	 * itself.
	 */
	if (MyWalSenderIdx == 0)
	{
		elog(LOG, "Spock: don't have a walsender idx - "
				  " not calling SyncRepWaitForLSN()");
	}
	else if (end_lsn <= commit_lsn)
	{
		elog(LOG, "Spock: walsender idx too big (%d) - "
				  " not calling SyncRepWaitForLSN()", MyWalSenderIdx);
	}
	else
	{
		HOLD_INTERRUPTS();
		SyncRepWaitForLSN(end_lsn, true);
		RESUME_INTERRUPTS();
	}

	/* update progress */
	OutputPluginUpdateProgress(ctx, false);

	OutputPluginPrepareWrite(ctx, true);
	data->api->write_commit(ctx->out, data, txn, commit_lsn);
	OutputPluginWrite(ctx, true);

	/*
	 * Now is a good time to get rid of invalidated relation
	 * metadata entries since nothing will be referencing them
	 * at the moment.
	 */
	relmetacache_prune();

	Assert(CurrentMemoryContext == data->context);
	MemoryContextSwitchTo(old_ctx);
	MemoryContextReset(data->context);

	VALGRIND_DO_ADDED_LEAK_CHECK;
}

/*
 * MESSAGE callback
 */
static void
pg_decode_message(LogicalDecodingContext *ctx,
				  ReorderBufferTXN *txn, XLogRecPtr message_lsn,
				  bool transactional, const char *prefix,
				  Size message_size, const char *message)
{
	SpockWalMessage	   *msg = (SpockWalMessage *)message;

	/* Ignore messages that are not meant for Spock */
	if (strcmp(prefix, SPOCK_MESSAGE_PREFIX) != 0)
		return;

	/* Check that we have at least the message type */
	if (message_size < sizeof(SpockWalMessageSimple))
	{
		elog(WARNING, "Spock custom WAL message: message_size %lu too short",
			 message_size);
		return;
	}

	switch (msg->mtype)
	{
		case SPOCK_REPAIR_MODE_ON:
			/* Turn decoding off for the remainder of the transaction */
			if (message_size != sizeof(SpockWalMessageSimple))
			{
				elog(WARNING, "Spock custom WAL message: wrong message "
							  "size %lu for simple message", message_size);
				return;
			}
			spock_replication_repair_mode = true;
			break;

		case SPOCK_REPAIR_MODE_OFF:
			/* Turn decoding back on */
			if (message_size != sizeof(SpockWalMessageSimple))
			{
				elog(WARNING, "Spock custom WAL message: wrong message "
							  "size %lu for simple message", message_size);
				return;
			}
			spock_replication_repair_mode = false;
			break;

		case SPOCK_SYNC_EVENT_MSG:
			{
				MemoryContext oldctx;
				SpockOutputData* data = (SpockOutputData*) ctx->output_plugin_private;
				TransactionId xid = InvalidTransactionId;

				if (txn != NULL)
					xid = txn->xid;

				oldctx = MemoryContextSwitchTo(data->context);

				OutputPluginPrepareWrite(ctx, true);
				spock_write_message(ctx->out,
									xid,
									message_lsn,
									true,
									prefix,
									message_size,
									message);
				OutputPluginWrite(ctx, true);

				Assert(CurrentMemoryContext == data->context);
				MemoryContextSwitchTo(oldctx);
			}
			break;

		default:
			elog(WARNING, "Spock custom WAL message: unknown message type %d",
				 msg->mtype);
			return;
	}

}

static bool
spock_change_filter(SpockOutputData *data, Relation relation,
						ReorderBufferChange *change, Bitmapset **att_list)
{
	SpockTableRepInfo *tblinfo;
	ListCell	   *lc;

	if (data->replicate_only_table)
	{
		/*
		 * Special case - we are catching up just one table.
		 * TODO: performance
		 */
		return strcmp(RelationGetRelationName(relation),
					  data->replicate_only_table->relname) == 0 &&
			RelationGetNamespace(relation) ==
				get_namespace_oid(data->replicate_only_table->schemaname, true);
	}
	else if (RelationGetRelid(relation) == get_queue_table_oid())
	{
		/* Special case - queue table */
		if (change->action == REORDER_BUFFER_CHANGE_INSERT)
		{
			HeapTuple		tup = ReorderBufferChangeHeapTuple(change, newtuple);
			QueuedMessage  *q;
			ListCell	   *qlc;

			LockRelation(relation, AccessShareLock);
			q = queued_message_from_tuple(tup);
			UnlockRelation(relation, AccessShareLock);

			/*
			 * No replication set means global message, those are always
			 * replicated.
			 */
			if (q->replication_sets == NULL)
				return true;

			foreach (qlc, q->replication_sets)
			{
				char	   *queue_set = (char *) lfirst(qlc);
				ListCell   *plc;

				foreach (plc, data->replication_sets)
				{
					SpockRepSet	   *rs = lfirst(plc);

					/* TODO: this is somewhat ugly. */
					if (strcmp(queue_set, rs->name) == 0)
						return true;
				}
			}
		}

		return false;
	}
	else if (RelationGetRelid(relation) == get_replication_set_rel_oid())
	{
		/*
		 * Special case - replication set table.
		 *
		 * We can use this to update our cached replication set info, without
		 * having to deal with cache invalidation callbacks.
		 */
		HeapTuple			tup;
		SpockRepSet	   *replicated_set;
		ListCell		   *plc;

		if (change->action == REORDER_BUFFER_CHANGE_UPDATE)
			 tup = ReorderBufferChangeHeapTuple(change, newtuple);
		else if (change->action == REORDER_BUFFER_CHANGE_DELETE)
			 tup = ReorderBufferChangeHeapTuple(change, oldtuple);
		else
			return false;

		replicated_set = replication_set_from_tuple(tup);
		foreach (plc, data->replication_sets)
		{
			SpockRepSet	   *rs = lfirst(plc);

			/* Check if the changed repset is used by us. */
			if (rs->id == replicated_set->id)
			{
				/*
				 * In case this was delete, somebody deleted one of our
				 * rep sets, bail here and let reconnect logic handle any
				 * potential issues.
				 */
				if (change->action == REORDER_BUFFER_CHANGE_DELETE)
					elog(ERROR, "replication set \"%s\" used by this connection was deleted, existing",
						 rs->name);

				/* This was update of our repset, update the cache. */
				rs->replicate_insert = replicated_set->replicate_insert;
				rs->replicate_update = replicated_set->replicate_update;
				rs->replicate_delete = replicated_set->replicate_delete;
				rs->replicate_truncate = replicated_set->replicate_truncate;

				return false;
			}
		}

		return false;
	}

	/* Normal case - use replication set membership. */
	tblinfo = get_table_replication_info(data->local_node_id, relation,
										 data->replication_sets);

	/* First try filter out by change type. */
	switch (change->action)
	{
		case REORDER_BUFFER_CHANGE_INSERT:
			if (!tblinfo->replicate_insert)
				return false;
			break;
		case REORDER_BUFFER_CHANGE_UPDATE:
			if (!tblinfo->replicate_update)
				return false;
			break;
		case REORDER_BUFFER_CHANGE_DELETE:
			if (!tblinfo->replicate_delete)
				return false;
			break;
		default:
			elog(ERROR, "Unhandled reorder buffer change type %d",
				 change->action);
			return false; /* shut compiler up */
	}

	/*
	 * Proccess row filters.
	 * XXX: we could probably cache some of the executor stuff.
	 */
	if (list_length(tblinfo->row_filter) > 0)
	{
		EState		   *estate;
		ExprContext	   *econtext;
		TupleDesc		tupdesc = RelationGetDescr(relation);
		HeapTuple		oldtup = change->data.tp.oldtuple ?
			ReorderBufferChangeHeapTuple(change, oldtuple) : NULL;
		HeapTuple		newtup = change->data.tp.newtuple ?
			ReorderBufferChangeHeapTuple(change, newtuple) : NULL;

		/* Skip empty changes. */
		if (!newtup && !oldtup)
		{
			elog(DEBUG1, "spock output got empty change");
			return false;
		}

		PushActiveSnapshot(GetTransactionSnapshot());

		estate = create_estate_for_relation(relation, false);
		econtext = prepare_per_tuple_econtext(estate, tupdesc);

		ExecStoreHeapTuple(newtup ? newtup : oldtup, econtext->ecxt_scantuple, false);

		/* Next try the row_filters if there are any. */
		foreach (lc, tblinfo->row_filter)
		{
			Node	   *row_filter = (Node *) lfirst(lc);
			ExprState  *exprstate = spock_prepare_row_filter(row_filter);
			Datum		res;
			bool		isnull;

			res = ExecEvalExpr(exprstate, econtext, &isnull);

			/* NULL is same as false for our use. */
			if (isnull)
				return false;

			if (!DatumGetBool(res))
				return false;
		}

		ExecDropSingleTupleTableSlot(econtext->ecxt_scantuple);
		FreeExecutorState(estate);

		PopActiveSnapshot();
	}

	/* Make sure caller is aware of any attribute filter. */
	*att_list = tblinfo->att_list;

	return true;
}

/*
 * Send relation description.
 */
static void
maybe_send_schema(LogicalDecodingContext *ctx, ReorderBufferChange *change,
			Relation relation)
{
	SpockOutputData *data = ctx->output_plugin_private;
	SPKRelMetaCacheEntry *cached_relmeta;

	/*
	 * If the protocol wants to write relation information and the client
	 * isn't known to have metadata cached for this relation already,
	 * send relation metadata.
	 *
	 * TODO: track hit/miss stats
	 */
	if (data->api->write_rel == NULL)
		return;

	cached_relmeta = relmetacache_get_relation(data, relation);
	if (!cached_relmeta->is_cached)
	{
		SpockTableRepInfo *tblinfo;

		tblinfo = get_table_replication_info(data->local_node_id, relation,
										data->replication_sets);


		OutputPluginPrepareWrite(ctx, false);
		data->api->write_rel(ctx->out, data, relation, tblinfo->att_list);
		OutputPluginWrite(ctx, false);
		cached_relmeta->is_cached = true;
	}
}

static void
pg_decode_change(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
				 Relation relation, ReorderBufferChange *change)
{
	SpockOutputData *data = ctx->output_plugin_private;
	MemoryContext	old;
	Bitmapset	   *att_list = NULL;

	/*
	 * If we are in slot-group skip transaction mode do nothing
	 */
	if (slot_group_skip_xact)
		return;

	/* If in repair mode skip these actions */
	if (spock_replication_repair_mode)
		return;

	/* Avoid leaking memory by using and resetting our own context */
	old = MemoryContextSwitchTo(data->context);

	/* update progress */
	OutputPluginUpdateProgress(ctx, false);

	/* First check the table filter */
	if (!spock_change_filter(data, relation, change, &att_list))
		goto cleanup;

	/* Send relation description */
	maybe_send_schema(ctx, change, relation);

	/* Send the data */
	switch (change->action)
	{
		case REORDER_BUFFER_CHANGE_INSERT:
			OutputPluginPrepareWrite(ctx, true);
			data->api->write_insert(ctx->out, data, relation,
									ReorderBufferChangeHeapTuple(change, newtuple),
									att_list);
			OutputPluginWrite(ctx, true);
			handle_stats_counter(relation, InvalidOid,
								 SPOCK_STATS_INSERT_COUNT, 1);
			break;
		case REORDER_BUFFER_CHANGE_UPDATE:
			{
				HeapTuple oldtuple = change->data.tp.oldtuple ?
					ReorderBufferChangeHeapTuple(change, oldtuple) : NULL;

				OutputPluginPrepareWrite(ctx, true);
				data->api->write_update(ctx->out, data, relation, oldtuple,
										ReorderBufferChangeHeapTuple(change, newtuple),
										att_list);
				OutputPluginWrite(ctx, true);
				handle_stats_counter(relation, InvalidOid,
									 SPOCK_STATS_UPDATE_COUNT, 1);
				break;
			}
		case REORDER_BUFFER_CHANGE_DELETE:
			if (change->data.tp.oldtuple)
			{
				OutputPluginPrepareWrite(ctx, true);
				data->api->write_delete(ctx->out, data, relation,
										ReorderBufferChangeHeapTuple(change, oldtuple),
										att_list);
				OutputPluginWrite(ctx, true);
				handle_stats_counter(relation, InvalidOid,
									 SPOCK_STATS_DELETE_COUNT, 1);
			}
			else
				elog(DEBUG1, "didn't send DELETE change because of missing oldtuple");
			break;
		default:
			Assert(false);
	}

cleanup:
	Assert(CurrentMemoryContext == data->context);
	MemoryContextSwitchTo(old);
	MemoryContextReset(data->context);
}

static void
pg_decode_truncate(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
				   int nrelations, Relation relations[],
				   ReorderBufferChange *change)
{
	SpockOutputData *data = (SpockOutputData*)ctx->output_plugin_private;
	MemoryContext old;
	int			i;
	int			nrelids;
	Oid		   *relids;

	/*
	 * If we are in slot-group skip transaction mode do nothing
	 */
	if (slot_group_skip_xact)
		return;

	/* If in repair mode skip these actions */
	if (spock_replication_repair_mode)
		return;

	old = MemoryContextSwitchTo(data->context);
	relids = palloc0(nrelations * sizeof(Oid));
	nrelids = 0;

	for (i = 0; i < nrelations; i++)
	{
		Relation	relation = relations[i];
		Oid			relid = RelationGetRelid(relation);
		List	   *repsets = get_table_replication_sets(data->local_node_id, relid);

		if (!can_replicate_truncate(repsets))
			continue;

		relids[nrelids++] = relid;
		/* Send relation description */
		maybe_send_schema(ctx, change, relation);
	}

	if (nrelids > 0)
	{
		OutputPluginPrepareWrite(ctx, true);
		data->api->write_truncate(ctx->out, nrelids, relids,
									change->data.truncate.cascade,
									change->data.truncate.restart_seqs);
		OutputPluginWrite(ctx, true);
	}

	MemoryContextSwitchTo(old);
	MemoryContextReset(data->context);
}

#ifdef HAVE_REPLICATION_ORIGINS
/*
 * Decide if the whole transaction with specific origin should be filtered out.
 */
static bool
pg_decode_origin_filter(LogicalDecodingContext *ctx,
						RepOriginId origin_id)
{
	SpockOutputData *data = ctx->output_plugin_private;
	bool ret;

	if (origin_id == InvalidRepOriginId)
		/* Never filter out locally originated tx's */
		ret = false;

	else
		/*
		 * Otherwise, ignore the origin passed in txnfilter_args->origin_id,
		 * and just forward all or nothing based on the configuration option
		 * 'forward_origins'.
		 */
		ret = list_length(data->forward_origins) == 0;

	return ret;
}
#endif

static void
send_startup_message(LogicalDecodingContext *ctx,
		SpockOutputData *data, bool last_message)
{
	List *msg;

	Assert(!startup_message_sent);

	msg = prepare_startup_message(data);

	/*
	 * We could free the extra_startup_params DefElem list here, but it's
	 * pretty harmless to just ignore it, since it's in the decoding memory
	 * context anyway, and we don't know if it's safe to free the defnames or
	 * not.
	 */

	OutputPluginPrepareWrite(ctx, last_message);
	data->api->write_startup_message(ctx->out, msg);
	OutputPluginWrite(ctx, last_message);

	list_free_deep(msg);

	startup_message_sent = true;
}


/*
 * Shutdown callback.
 */
static void
pg_decode_shutdown(LogicalDecodingContext * ctx)
{
	relmetacache_flush();

	spock_output_leave_slot_group();

	VALGRIND_PRINTF("SPOCK: output plugin shutdown\n");

	/*
	 * no need to delete data->context as it's child of ctx->context which
	 * will expire on return.
	 */
}

/*
 * Install hooks to request shared resources for slot-group management
 */
void
spock_output_plugin_shmem_init(void)
{
#if PG_VERSION_NUM < 150000
	spock_output_plugin_shmem_request();
#else
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = spock_output_plugin_shmem_request;
#endif
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = spock_output_plugin_shmem_startup;
}

/*
 * Join a slot-group if possible
 */
static void
spock_output_join_slot_group(NameData slot_name)
{
	SpockOutputSlotGroup   *groups;
	SpockOutputSlotGroup   *free_group = NULL;
	int						free_i = 0;
	NameData				group_name;
	bool					is_slot_group = false;
	char				   *cp;
	int						i;

	/*
	 * Ensure we are not already a member of a slot-group
	 */
	if (slot_group != NULL)
		elog(ERROR, "slot '%s' is already a slot-group member",
			 NameStr(slot_name));

	/*
	 * Determine the group name (if possible)
	 */
	strcpy(NameStr(group_name), NameStr(slot_name));
	for(cp = NameStr(group_name); *cp; cp++)
	{
		if (cp[0] == '_'
			&& (cp[1] >= '0' && cp[1] <= '9')
			&& cp[2] == '\0')
		{
			*cp = '\0';
			is_slot_group = true;
			break;
		}
	}
	if (!is_slot_group)
		return;

	/*
	 * Register our on_proc_exit callback if not done yet
	 */
	if (!slot_group_on_exit_set)
	{
		on_proc_exit(spock_output_plugin_on_exit, 0);
		slot_group_on_exit_set = true;
	}

	/*
	 * Find and join this group; use an empty slot if not found
	 */
	elog(LOG, "SPOCK join slot-group '%s' for slot '%s'",
		 NameStr(group_name),
		 NameStr(slot_name));
	LWLockAcquire(SpockCtx->slot_group_master_lock, LW_EXCLUSIVE);
	groups = SpockCtx->slot_groups;
	for (i = 0; i < SpockCtx->slot_ngroups; i++)
	{
		if (free_group == NULL && groups[i].nattached == 0)
		{
			free_group = &groups[i];
			free_i = i;
		}
		if (strcmp(NameStr(group_name), NameStr(groups[i].name)) == 0
			&& groups[i].nattached > 0)
		{
			slot_group = &groups[i];
			slot_group->nattached++;
			elog(LOG, "using existing slot-group %d - nattached=%d", i,
				 slot_group->nattached);
			break;
		}
	}
	if (slot_group == NULL)
	{
		elog(LOG, "using free slot-group %d", free_i);
		slot_group = free_group;
		strcpy(NameStr(slot_group->name), NameStr(group_name));
		slot_group->nattached = 1;
		slot_group->last_lsn = InvalidXLogRecPtr;
		slot_group->last_commit_ts = 0;
	}

	LWLockRelease(SpockCtx->slot_group_master_lock);
}

static void
spock_output_leave_slot_group(void)
{
	/*
	 * Nothing to do if we are not a member of a slot-group
	 */
	if (slot_group == NULL)
	{
		return;
	}

	/*
	 * Remove ourselves from the slot-group
	 */
	//LWLockAcquire(SpockCtx->slot_group_master_lock, LW_EXCLUSIVE);
	slot_group->nattached--;
	elog(LOG, "removed from slot-group '%s' - nattached=%d",
		 NameStr(slot_group->name), slot_group->nattached);
	slot_group = NULL;
	//LWLockRelease(SpockCtx->slot_group_master_lock);
}

/*
 * Reserve additional shared resources for slot-group management
 */
static void
spock_output_plugin_shmem_request(void)
{
	int		nworkers;

#if PG_VERSION_NUM >= 150000
	if (prev_shmem_request_hook != NULL)
		prev_shmem_request_hook();
#endif

	/*
	 * This is cludge for Windows (Postgres des not define the GUC variable
	 * as PGDDLIMPORT)
	 */
	nworkers = atoi(GetConfigOptionByName("max_worker_processes", NULL,
										  false));

	/*
	 * Request enough shared memory for nworkers slot-groups (worst case)
	 */
	RequestAddinShmemSpace(spock_output_plugin_shmem_size(nworkers));

	/*
	 * Request the LWlocks needed
	 */
	RequestNamedLWLockTranche("spock_slot_groups", nworkers + 1);
}

/*
 * Initialize shared resources for slot-group management
 */
static void
spock_output_plugin_shmem_startup(void)
{
	bool					found;
	int						nworkers;
	SpockOutputSlotGroup   *slot_groups;
	int						i;

	if (prev_shmem_startup_hook != NULL)
		prev_shmem_startup_hook();

	/*
	 * This is kludge for Windows (Postgres does not define the GUC variable
	 * as PGDLLIMPORT)
	 */
	nworkers = atoi(GetConfigOptionByName("max_worker_processes", NULL,
										  false));

	/* Get the shared resources */
	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	SpockCtx->slot_group_master_lock = &((GetNamedLWLockTranche("spock_slot_groups")[0]).lock);
	SpockCtx->slot_ngroups = nworkers;
	slot_groups = ShmemInitStruct("spock_slot_groups",
								 spock_output_plugin_shmem_size(nworkers),
								 &found);
	if (!found)
	{
		memset(slot_groups, 0, spock_output_plugin_shmem_size(nworkers));
		SpockCtx->slot_groups = slot_groups;
		for (i = 0; i < nworkers; i++)
		{
			slot_groups[i].lock = &((GetNamedLWLockTranche("spock_slot_groups")[i + 1]).lock);
		}
	}

	LWLockRelease(AddinShmemInitLock);
}

/*
 * Calculate the shared memory needed for slot-group management
 */
static Size
spock_output_plugin_shmem_size(int nworkers)
{
	return(nworkers * sizeof(SpockOutputSlotGroup));
}

/*
 * Cleanup called on proc_exit
 */
static void
spock_output_plugin_on_exit(int code, Datum arg)
{
	spock_output_leave_slot_group();
}


/*
 * Relation metadata invalidation, for when a relcache invalidation
 * means that we need to resend table metadata to the client.
 */
static void
relmetacache_invalidation_cb(Datum arg, Oid relid)
 {
	struct SPKRelMetaCacheEntry *hentry;
	Assert (RelMetaCache != NULL);

	/*
	 * Nobody keeps pointers to entries in this hash table around outside
	 * logical decoding callback calls - but invalidation events can come in
	 * *during* a callback if we access the relcache in the callback. Because
	 * of that we must mark the cache entry as invalid but not remove it from
	 * the hash while it could still be referenced, then prune it at a later
	 * safe point.
	 *
	 * Getting invalidations for relations that aren't in the table is
	 * entirely normal, since there's no way to unregister for an
	 * invalidation event. So we don't care if it's found or not.
	 */
	hentry = (struct SPKRelMetaCacheEntry *)
		hash_search(RelMetaCache, &relid, HASH_FIND, NULL);

	if (hentry != NULL)
	{
		hentry->is_valid = false;
		InvalidRelMetaCacheCnt++;
	}
}

/*
 * Initialize the relation metadata cache for a decoding session.
 *
 * The hash table is destoyed at the end of a decoding session. While
 * relcache invalidations still exist and will still be invoked, they
 * will just see the null hash table global and take no action.
 */
static void
relmetacache_init(MemoryContext decoding_context)
{
	HASHCTL	ctl;
	int		hash_flags;

	InvalidRelMetaCacheCnt = 0;

	if (RelMetaCache == NULL)
	{
		MemoryContext old_ctxt;

		RelMetaCacheContext = AllocSetContextCreate(TopMemoryContext,
											  "spock output relmetacache",
											  ALLOCSET_DEFAULT_SIZES);

		/* Make a new hash table for the cache */
		hash_flags = HASH_ELEM | HASH_CONTEXT;

		MemSet(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(Oid);
		ctl.entrysize = sizeof(struct SPKRelMetaCacheEntry);
		ctl.hcxt = RelMetaCacheContext;

#if PG_VERSION_NUM >= 90500
		hash_flags |= HASH_BLOBS;
#else
		ctl.hash = tag_hash;
		hash_flags |= HASH_FUNCTION;
#endif

		old_ctxt = MemoryContextSwitchTo(RelMetaCacheContext);
		RelMetaCache = hash_create("spock relation metadata cache",
								   RELMETACACHE_INITIAL_SIZE,
								   &ctl, hash_flags);
		(void) MemoryContextSwitchTo(old_ctxt);

		Assert(RelMetaCache != NULL);

		CacheRegisterRelcacheCallback(relmetacache_invalidation_cb, (Datum)0);
	}
}


/*
 * Look up an entry, creating it if not found.
 *
 * Newly created entries are returned as is_cached=false. The API
 * hook can set is_cached to skip subsequent updates if it sent a
 * complete response that the client will cache.
 *
 * Returns true on a cache hit, false on a miss.
 */
static SPKRelMetaCacheEntry *
relmetacache_get_relation(struct SpockOutputData *data,
						  Relation rel)
{
	struct SPKRelMetaCacheEntry *hentry;
	bool found;
	MemoryContext old_mctx;

	/* Find cached function info, creating if not found */
	old_mctx = MemoryContextSwitchTo(RelMetaCacheContext);
	hentry = (struct SPKRelMetaCacheEntry*) hash_search(RelMetaCache,
										 (void *)(&RelationGetRelid(rel)),
										 HASH_ENTER, &found);
	(void) MemoryContextSwitchTo(old_mctx);

	/* If not found or not valid, it can't be cached. */
	if (!found || !hentry->is_valid)
	{
		Assert(hentry->relid = RelationGetRelid(rel));
		hentry->is_cached = false;
		/* Only used for lazy purging of invalidations */
		hentry->is_valid = true;
	}

	Assert(hentry != NULL);

	return hentry;
}


/*
 * Flush the relation metadata cache at the end of a decoding session.
 *
 * We cannot truly destroy the cache because it may be referenced by later
 * relcache invalidation callbacks after the end of a SQL-level decoding
 * session.
 */
static void
relmetacache_flush(void)
{
	HASH_SEQ_STATUS status;
	struct SPKRelMetaCacheEntry *hentry;

	if (RelMetaCache != NULL)
	{
		hash_seq_init(&status, RelMetaCache);

		while ((hentry = (struct SPKRelMetaCacheEntry*) hash_seq_search(&status)) != NULL)
		{
			if (hash_search(RelMetaCache,
							(void *) &hentry->relid,
							HASH_REMOVE, NULL) == NULL)
				elog(ERROR, "hash table corrupted");
		}
	}
}

/*
 * Prune !is_valid entries from the relation metadata cache
 *
 * This must only be called when there couldn't be any references to
 * possibly-invalid entries.
 */
static void
relmetacache_prune(void)
{
	HASH_SEQ_STATUS status;
	struct SPKRelMetaCacheEntry *hentry;

	/*
	 * Since the pruning can be expensive, do it only if ig we invalidated
	 * at least half of initial cache size.
	 */
	if (InvalidRelMetaCacheCnt < RELMETACACHE_INITIAL_SIZE/2)
		return;

	hash_seq_init(&status, RelMetaCache);

	while ((hentry = (struct SPKRelMetaCacheEntry*) hash_seq_search(&status)) != NULL)
	{
		if (!hentry->is_valid)
		{
			if (hash_search(RelMetaCache,
							(void *) &hentry->relid,
							HASH_REMOVE, NULL) == NULL)
				elog(ERROR, "hash table corrupted");
		}
	}

	InvalidRelMetaCacheCnt = 0;
}

/*
 * Clone of ReorderBufferCleanSerializedTXNs; see
 * https://www.postgresql.org/message-id/CAMsr+YHdX=XECbZshDZ2CZNWGTyw-taYBnzqVfx4JzM4ExP5xg@mail.gmail.com
 */
static void
spkReorderBufferCleanSerializedTXNs(const char *slotname)
{
	DIR		   *spill_dir;
	struct dirent *spill_de;
	struct stat statbuf;
	char		path[MAXPGPATH * 2 + 12];

	sprintf(path, "pg_replslot/%s", slotname);

	/* we're only handling directories here, skip if it's not ours */
	if (lstat(path, &statbuf) == 0 && !S_ISDIR(statbuf.st_mode))
		return;

	spill_dir = AllocateDir(path);
	while ((spill_de = ReadDirExtended(spill_dir, path, INFO)) != NULL)
	{
		/* only look at names that can be ours */
		if (strncmp(spill_de->d_name, "xid", 3) == 0)
		{
			snprintf(path, sizeof(path),
					 "pg_replslot/%s/%s", slotname,
					 spill_de->d_name);

			if (unlink(path) != 0)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not remove file \"%s\" during removal of pg_replslot/%s/*.xid: %m",
								path, slotname)));
		}
	}
	FreeDir(spill_dir);
}

static bool
can_replicate_truncate(List *repsets)
{
    ListCell *rlc;

    foreach(rlc, repsets)
    {
        SpockRepSet *repset = (SpockRepSet *) lfirst(rlc);

        if (repset->replicate_truncate)
            return true;
    }

    return false;
}
