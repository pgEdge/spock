/*-------------------------------------------------------------------------
 *
 * spock_functions.c
 *		spock SQL visible interfaces
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/commit_ts.h"
#include "access/genam.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/sysattr.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "access/xlogrecovery.h"
#include "access/xlogutils.h"

#include "catalog/catalog.h"
#include "catalog/heap.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_inherits.h"
#include "catalog/pg_type.h"

#include "commands/dbcommands.h"
#include "commands/defrem.h"
#include "commands/event_trigger.h"

#include "executor/spi.h"

#include "funcapi.h"

#include "miscadmin.h"

#include "nodes/bitmapset.h"
#include "nodes/makefuncs.h"

#include "pgtime.h"

#include "parser/parse_coerce.h"
#include "parser/parse_collate.h"
#include "parser/parse_expr.h"
#include "parser/parse_relation.h"

#include "replication/logical.h"
#include "replication/message.h"
#include "replication/origin.h"
#include "replication/reorderbuffer.h"
#include "replication/slot.h"

#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"

#include "tcop/tcopprot.h"

#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/catcache.h"
#include "utils/fmgroids.h"
#include "utils/inval.h"
#include "utils/json.h"
#include "utils/guc.h"
#if PG_VERSION_NUM >= 160000
#include "utils/guc_hooks.h"
#endif
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "pgstat.h"

#include "spock_apply.h"
#include "spock_conflict.h"
#include "spock_dependency.h"
#include "spock_executor.h"
#include "spock_node.h"
#include "spock_output_plugin.h"
#include "spock_queue.h"
#include "spock_recovery.h"
#include "spock_relcache.h"
#include "spock_repset.h"
#include "spock_rpc.h"
#include "spock_sync.h"
#include "spock_worker.h"

#include "spock.h"

/* Node management. */
PG_FUNCTION_INFO_V1(spock_create_node);
PG_FUNCTION_INFO_V1(spock_drop_node);
PG_FUNCTION_INFO_V1(spock_alter_node_add_interface);
PG_FUNCTION_INFO_V1(spock_alter_node_drop_interface);

/* Subscription management. */
PG_FUNCTION_INFO_V1(spock_create_subscription);
PG_FUNCTION_INFO_V1(spock_drop_subscription);

PG_FUNCTION_INFO_V1(spock_alter_subscription_interface);

PG_FUNCTION_INFO_V1(spock_alter_subscription_disable);
PG_FUNCTION_INFO_V1(spock_alter_subscription_enable);

PG_FUNCTION_INFO_V1(spock_alter_subscription_add_replication_set);
PG_FUNCTION_INFO_V1(spock_alter_subscription_remove_replication_set);
PG_FUNCTION_INFO_V1(spock_alter_subscription_skip_lsn);

PG_FUNCTION_INFO_V1(spock_alter_subscription_synchronize);
PG_FUNCTION_INFO_V1(spock_alter_subscription_resynchronize_table);

PG_FUNCTION_INFO_V1(spock_show_subscription_table);
PG_FUNCTION_INFO_V1(spock_show_subscription_status);

PG_FUNCTION_INFO_V1(spock_wait_for_subscription_sync_complete);
PG_FUNCTION_INFO_V1(spock_wait_for_table_sync_complete);

PG_FUNCTION_INFO_V1(spock_create_sync_event);

/* Replication set manipulation. */
PG_FUNCTION_INFO_V1(spock_create_replication_set);
PG_FUNCTION_INFO_V1(spock_alter_replication_set);
PG_FUNCTION_INFO_V1(spock_drop_replication_set);
PG_FUNCTION_INFO_V1(spock_replication_set_add_table);
PG_FUNCTION_INFO_V1(spock_replication_set_add_all_tables);
PG_FUNCTION_INFO_V1(spock_replication_set_remove_table);
PG_FUNCTION_INFO_V1(spock_replication_set_add_sequence);
PG_FUNCTION_INFO_V1(spock_replication_set_add_all_sequences);
PG_FUNCTION_INFO_V1(spock_replication_set_remove_sequence);
PG_FUNCTION_INFO_V1(spock_replication_set_add_partition);
PG_FUNCTION_INFO_V1(spock_replication_set_remove_partition);

/* Other manipulation function */
PG_FUNCTION_INFO_V1(spock_synchronize_sequence);

/* DDL */
PG_FUNCTION_INFO_V1(spock_replicate_ddl_command);
PG_FUNCTION_INFO_V1(spock_truncate_trigger_add);
PG_FUNCTION_INFO_V1(spock_dependency_check_trigger);

/* Internal utils */
PG_FUNCTION_INFO_V1(spock_gen_slot_name);
PG_FUNCTION_INFO_V1(spock_node_info);
PG_FUNCTION_INFO_V1(spock_show_repset_table_info);
PG_FUNCTION_INFO_V1(spock_table_data_filtered);

/* Information */
PG_FUNCTION_INFO_V1(spock_version);
PG_FUNCTION_INFO_V1(spock_version_num);
PG_FUNCTION_INFO_V1(spock_min_proto_version);
PG_FUNCTION_INFO_V1(spock_max_proto_version);

PG_FUNCTION_INFO_V1(spock_xact_commit_timestamp_origin);

/* Compatibility for upgrading */
PG_FUNCTION_INFO_V1(spock_show_repset_table_info_by_target);

/* Stats/Counters */
PG_FUNCTION_INFO_V1(get_channel_stats);
PG_FUNCTION_INFO_V1(reset_channel_stats);
PG_FUNCTION_INFO_V1(prune_conflict_tracking);

/* Recovery functions */
PG_FUNCTION_INFO_V1(spock_clone_recovery_slot);
PG_FUNCTION_INFO_V1(spock_get_min_unacknowledged_timestamp);
PG_FUNCTION_INFO_V1(spock_initiate_node_recovery);
PG_FUNCTION_INFO_V1(spock_get_recovery_slot_info);
PG_FUNCTION_INFO_V1(spock_detect_failed_nodes);
PG_FUNCTION_INFO_V1(spock_coordinate_cluster_recovery);
PG_FUNCTION_INFO_V1(spock_advance_recovery_slot_to_lsn);

/* Generic delta apply functions */
PG_FUNCTION_INFO_V1(delta_apply_int2);
PG_FUNCTION_INFO_V1(delta_apply_int4);
PG_FUNCTION_INFO_V1(delta_apply_int8);
PG_FUNCTION_INFO_V1(delta_apply_float4);
PG_FUNCTION_INFO_V1(delta_apply_float8);
PG_FUNCTION_INFO_V1(delta_apply_numeric);
PG_FUNCTION_INFO_V1(delta_apply_money);

/* Function to control REPAIR mode */
PG_FUNCTION_INFO_V1(spock_repair_mode);

/* Function to get a LSN based on commit timestamp */
PG_FUNCTION_INFO_V1(spock_get_lsn_from_commit_ts);

static void gen_slot_name(Name slot_name, char *dbname,
						  const char *provider_name,
						  const char *subscriber_name);


bool in_spock_replicate_ddl_command = false;
bool in_spock_queue_ddl_command = false;

static SpockLocalNode *
check_local_node(bool for_update)
{
	SpockLocalNode *node;

	node = get_local_node(for_update, true);
	if (!node)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("current database is not configured as spock node"),
				 errhint("create spock node first")));

	return node;
}

/*
 * Create new node
 */
Datum spock_create_node(PG_FUNCTION_ARGS)
{
	char *node_name;
	char *node_dsn;
	char *location = NULL;
	char *country = NULL;
	Jsonb *info = NULL;
	SpockNode node;
	SpockInterface nodeif;
	SpockRepSet repset;

	/* node name or dsn cannot be NULL */
	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		PG_RETURN_NULL();

	node_name = NameStr(*PG_GETARG_NAME(0));
	node_dsn = text_to_cstring(PG_GETARG_TEXT_PP(1));

	if (!PG_ARGISNULL(2))
		location = text_to_cstring(PG_GETARG_TEXT_PP(2));
	if (!PG_ARGISNULL(3))
		country = text_to_cstring(PG_GETARG_TEXT_PP(3));
	if (!PG_ARGISNULL(4))
		info = PG_GETARG_JSONB_P(4);

	node.id = InvalidOid;
	node.name = node_name;
	node.location = location;
	node.country = country;
	node.info = info;
	create_node(&node);

	nodeif.id = InvalidOid;
	nodeif.name = node.name;
	nodeif.nodeid = node.id;
	nodeif.dsn = node_dsn;
	create_node_interface(&nodeif);

	/* Create predefined repsets. */
	repset.id = InvalidOid;
	repset.nodeid = node.id;
	repset.name = DEFAULT_REPSET_NAME;
	repset.replicate_insert = true;
	repset.replicate_update = true;
	repset.replicate_delete = true;
	repset.replicate_truncate = true;
	create_replication_set(&repset);

	repset.id = InvalidOid;
	repset.nodeid = node.id;
	repset.name = DEFAULT_INSONLY_REPSET_NAME;
	repset.replicate_insert = true;
	repset.replicate_update = false;
	repset.replicate_delete = false;
	repset.replicate_truncate = true;
	create_replication_set(&repset);

	repset.id = InvalidOid;
	repset.nodeid = node.id;
	repset.name = DDL_SQL_REPSET_NAME;
	repset.replicate_insert = true;
	repset.replicate_update = false;
	repset.replicate_delete = false;
	repset.replicate_truncate = false;
	create_replication_set(&repset);

	create_local_node(node.id, nodeif.id);

	PG_RETURN_OID(node.id);
}

/*
 * Drop the named node.
 *
 * TODO: support cascade (drop subscribers)
 */
Datum spock_drop_node(PG_FUNCTION_ARGS)
{
	char *node_name = NameStr(*PG_GETARG_NAME(0));
	bool ifexists = PG_GETARG_BOOL(1);
	SpockNode *node;

	node = get_node_by_name(node_name, ifexists);

	if (node != NULL)
	{
		SpockLocalNode *local_node;
		List *osubs;
		List *tsubs;

		osubs = get_node_subscriptions(node->id, true);
		tsubs = get_node_subscriptions(node->id, false);
		if (list_length(osubs) != 0 || list_length(tsubs) != 0)
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("cannot drop node \"%s\" because it still has subscriptions associated with it", node_name),
					 errhint("drop the subscriptions first")));

		/* If the node is local node, drop the record as well. */
		local_node = get_local_node(true, true);
		if (local_node && local_node->node->id == node->id)
		{
			int res;

			/*
			 * Also drop all the slots associated with the node.
			 *
			 * We do this via SPI mainly because ReplicationSlotCtl is not
			 * accessible on Windows.
			 */
			SPI_connect();
			PG_TRY();
			{
				res = SPI_execute("SELECT pg_catalog.pg_drop_replication_slot(slot_name)"
								  "  FROM pg_catalog.pg_replication_slots"
								  " WHERE (plugin = 'spock_output' OR plugin = 'spock')"
								  "   AND database = current_database()"
								  "   AND slot_name ~ 'spk_.*'",
								  false, 0);
			}
			PG_CATCH();
			{
				ereport(ERROR,
						(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
						 errmsg("cannot drop node \"%s\" because one or more replication slots for the node are still active",
								node_name),
						 errhint("drop the subscriptions connected to the node first")));
			}
			PG_END_TRY();

			if (res != SPI_OK_SELECT)
				elog(ERROR, "SPI query failed: %d", res);

			SPI_finish();

			/* And drop the local node association as well. */
			drop_local_node();
		}

		/* Drop all the interfaces. */
		drop_node_interfaces(node->id);

		/* Drop replication sets associated with the node. */
		drop_node_replication_sets(node->id);

		/* Drop the node itself. */
		drop_node(node->id);
	}

	PG_RETURN_BOOL(node != NULL);
}

/*
 * Add interface to a node.
 */
Datum spock_alter_node_add_interface(PG_FUNCTION_ARGS)
{
	char *node_name = NameStr(*PG_GETARG_NAME(0));
	char *if_name = NameStr(*PG_GETARG_NAME(1));
	char *if_dsn = text_to_cstring(PG_GETARG_TEXT_PP(2));
	SpockNode *node;
	SpockInterface *oldif,
		newif;

	node = get_node_by_name(node_name, false);
	if (node == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("node \"%s\" not found", node_name)));

	oldif = get_node_interface_by_name(node->id, if_name, true);
	if (oldif != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("node \"%s\" already has interface named \"%s\"",
						node_name, if_name)));

	newif.id = InvalidOid;
	newif.name = if_name;
	newif.nodeid = node->id;
	newif.dsn = if_dsn;
	create_node_interface(&newif);

	PG_RETURN_OID(newif.id);
}

/*
 * Drop interface from a node.
 */
Datum spock_alter_node_drop_interface(PG_FUNCTION_ARGS)
{
	char *node_name = NameStr(*PG_GETARG_NAME(0));
	char *if_name = NameStr(*PG_GETARG_NAME(1));
	SpockNode *node;
	SpockInterface *oldif;
	List *other_subs;
	ListCell *lc;

	node = get_node_by_name(node_name, false);
	if (node == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("node \"%s\" not found", node_name)));

	oldif = get_node_interface_by_name(node->id, if_name, true);
	if (oldif == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("interface \"%s\" for node node \"%s\" not found",
						if_name, node_name)));

	other_subs = get_node_subscriptions(node->id, true);
	foreach (lc, other_subs)
	{
		SpockSubscription *sub = (SpockSubscription *)lfirst(lc);
		if (oldif->id == sub->origin_if->id)
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("cannot drop interface \"%s\" for node \"%s\" because subscription \"%s\" is using it",
							oldif->name, node->name, sub->name),
					 errhint("change the subscription interface first")));
	}

	drop_node_interface(oldif->id);

	PG_RETURN_BOOL(true);
}

/*
 * Connect two existing nodes.
 */
Datum spock_create_subscription(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	char *provider_dsn = text_to_cstring(PG_GETARG_TEXT_PP(1));
	ArrayType *rep_set_names = PG_GETARG_ARRAYTYPE_P(2);
	bool sync_structure = PG_GETARG_BOOL(3);
	bool sync_data = PG_GETARG_BOOL(4);
	ArrayType *forward_origin_names = PG_GETARG_ARRAYTYPE_P(5);
	Interval *apply_delay = PG_GETARG_INTERVAL_P(6);
	bool force_text_transfer = PG_GETARG_BOOL(7);
	bool enabled = PG_GETARG_BOOL(8);
	PGconn *conn;
	SpockSubscription sub;
	SpockSyncStatus sync;
	SpockNode *origin;
	SpockNode *existing_origin;
	SpockInterface originif;
	SpockLocalNode *localnode;
	SpockInterface targetif;
	List *replication_sets;
	List *other_subs;
	ListCell *lc;
	NameData slot_name;

	/* Check that this is actually a node. */
	localnode = get_local_node(true, false);

	/* Now, fetch info about remote node. */
	conn = spock_connect(provider_dsn, sub_name, "create");
	origin = spock_remote_node_info(conn, NULL, NULL, NULL);
	PQfinish(conn);

	/* Check that we can connect remotely also in replication mode. */
	conn = spock_connect_replica(provider_dsn, sub_name, "create");
	PQfinish(conn);

	/* Check that local connection works. */
	conn = spock_connect(localnode->node_if->dsn, sub_name, "create");
	PQfinish(conn);

	/*
	 * Check for existing local representation of remote node and interface
	 * and lock it if it already exists.
	 */
	existing_origin = get_node_by_name(origin->name, true);

	/*
	 * If not found, crate local representation of remote node and interface.
	 */
	if (!existing_origin)
	{
		create_node(origin);

		originif.id = InvalidOid;
		originif.name = origin->name;
		originif.nodeid = origin->id;
		originif.dsn = provider_dsn;
		create_node_interface(&originif);
	}
	else
	{
		SpockInterface *existingif;

		existingif = get_node_interface_by_name(origin->id, origin->name, false);
		if (strcmp(existingif->dsn, provider_dsn) != 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("dsn \"%s\" points to existing node \"%s\" with different dsn \"%s\"",
							provider_dsn, origin->name, existingif->dsn)));

		memcpy(&originif, existingif, sizeof(SpockInterface));
	}

	/*
	 * Check for overlapping replication sets.
	 *
	 * Note that we can't use exclusion constraints as we use the
	 * subscriptions table in same manner as system catalog.
	 */
	replication_sets = textarray_to_list(rep_set_names);
	other_subs = get_node_subscriptions(originif.nodeid, true);
	foreach (lc, other_subs)
	{
		SpockSubscription *esub = (SpockSubscription *)lfirst(lc);
		ListCell *esetcell;

		foreach (esetcell, esub->replication_sets)
		{
			char *existingset = lfirst(esetcell);
			ListCell *nsetcell;

			foreach (nsetcell, replication_sets)
			{
				char *newset = lfirst(nsetcell);

				if (strcmp(newset, existingset) == 0)
					ereport(WARNING,
							(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							 errmsg("existing subscription \"%s\" to node "
									"\"%s\" already subscribes to replication "
									"set \"%s\"",
									esub->name, origin->name,
									newset)));
			}
		}
	}

	/*
	 * Create the subscription.
	 *
	 * Note for now we don't care much about the target interface so we fake
	 * it here to be invalid.
	 */
	targetif.id = localnode->node_if->id;
	targetif.nodeid = localnode->node->id;
	sub.id = InvalidOid;
	sub.name = sub_name;
	sub.origin_if = &originif;
	sub.target_if = &targetif;
	sub.replication_sets = replication_sets;
	sub.forward_origins = textarray_to_list(forward_origin_names);
	sub.enabled = enabled;
	gen_slot_name(&slot_name, get_database_name(MyDatabaseId),
				  origin->name, sub_name);
	sub.slot_name = pstrdup(NameStr(slot_name));
	sub.apply_delay = apply_delay;
	sub.force_text_transfer = force_text_transfer;
	sub.skiplsn	= InvalidXLogRecPtr;

	create_subscription(&sub);

	/* Create progress entry to track commit ts per local/remote origin */
	create_progress_entry(localnode->node->id, originif.nodeid, GetCurrentIntegerTimestamp());

	/* Create recovery slot for catastrophic node failure handling */
	if (!create_recovery_slot(localnode->node->id, originif.nodeid))
	{
		elog(WARNING, "Failed to create recovery slot for subscription '%s' to node '%s'",
			 sub_name, origin->name);
	}


	/* Create synchronization status for the subscription. */
	memset(&sync, 0, sizeof(SpockSyncStatus));

	if (sync_structure && sync_data)
		sync.kind = SYNC_KIND_FULL;
	else if (sync_structure)
		sync.kind = SYNC_KIND_STRUCTURE;
	else if (sync_data)
		sync.kind = SYNC_KIND_DATA;
	else
		sync.kind = SYNC_KIND_INIT;

	sync.subid = sub.id;

	if (enabled)
	{
		sync.status = SYNC_STATUS_INIT;
	}
	else
	{
		/*
		 * If we create a subscription in disabled state it is
		 * meant for Zero-Downtime-Add-Node. This cannot use any
		 * synchronization and we immediately mark the local
		 * sync status as READY.
		 */
		if (sync_structure || sync_data)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("subscription \"%s\" in disabled state is not "
							"allowed to synchronize structure or data",
							sub_name)));
		sync.status = SYNC_STATUS_READY;

		/*
		 * We also create the replication origin entry here because
		 * the way we setup the subscription causes spock_sync.c not
		 * to do anything.
		 */
		(void) replorigin_create(slot_name.data);
	}
	create_local_sync_status(&sync);

	/* Create recovery slots for this subscription */
	{
		Oid local_node_id = get_local_node(true, false)->node->id;

		/* Create recovery slot from local node to remote node */
		create_recovery_slot(local_node_id, sub.origin->id);

		/* Create recovery slot from remote node to local node */
		create_recovery_slot(sub.origin->id, local_node_id);
	}

	PG_RETURN_OID(sub.id);
}

/*
 * Remove subscribption.
 */
Datum spock_drop_subscription(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	bool ifexists = PG_GETARG_BOOL(1);
	SpockSubscription *sub;

	sub = get_subscription_by_name(sub_name, ifexists);

	if (sub != NULL)
	{
		SpockWorker *apply;
		List *other_subs;
		SpockLocalNode *node;

		node = get_local_node(true, false);

		/* First drop the status. */
		drop_subscription_sync_status(sub->id);

		/* Drop the actual subscription. */
		drop_subscription(sub->id);

		/*
		 * The rest is different depending on if we are doing this on provider
		 * or subscriber.
		 *
		 * For now on provider we just exist (there should be no records
		 * of subscribers on their provider node).
		 */
		if (sub->origin->id == node->node->id)
			PG_RETURN_BOOL(sub != NULL);

		/*
		 * If the provider node record existed only for the dropped,
		 * subscription, it should be dropped as well.
		 */
		other_subs = get_node_subscriptions(sub->origin->id, true);
		if (list_length(other_subs) == 0)
		{
			drop_node_interfaces(sub->origin->id);
			drop_node(sub->origin->id);
		}

		/* Kill the apply to unlock the resources. */
		LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
		apply = spock_apply_find(MyDatabaseId, sub->id);
		spock_worker_kill(apply);
		LWLockRelease(SpockCtx->lock);

		/* Wait for the apply to die. */
		for (;;)
		{
			int rc;

			LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
			apply = spock_apply_find(MyDatabaseId, sub->id);
			if (!spock_worker_running(apply))
			{
				LWLockRelease(SpockCtx->lock);
				break;
			}
			LWLockRelease(SpockCtx->lock);

			CHECK_FOR_INTERRUPTS();

			rc = WaitLatch(&MyProc->procLatch,
						   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH, 1000L);

			if (rc & WL_POSTMASTER_DEATH)
				proc_exit(1);

			ResetLatch(&MyProc->procLatch);
		}

		/*
		 * Drop the slot on remote side.
		 *
		 * Note, we can't fail here since we can't assume that the remote node
		 * is still reachable or even alive.
		 */
		PG_TRY();
		{
			PGconn *origin_conn = spock_connect(sub->origin_if->dsn,
												sub->name, "cleanup");
			spock_drop_remote_slot(origin_conn, sub->slot_name);
			PQfinish(origin_conn);
		}
		PG_CATCH();
		{
			FlushErrorState();
			elog(WARNING, "could not drop slot \"%s\" on provider, you will probably have to drop it manually",
				 sub->slot_name);
		}
		PG_END_TRY();

		/* Drop the origin tracking locally. */
		replorigin_drop_by_name(sub->slot_name, true, false);

		/* Drop recovery slot for this subscription */
		drop_recovery_slot(node->node->id, sub->origin->id);
	}

	PG_RETURN_BOOL(sub != NULL);
}

/*
 * Disable subscription.
 */
Datum spock_alter_subscription_disable(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	bool immediate = PG_GETARG_BOOL(1);
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);

	/* XXX: Only used for locking purposes. */
	(void)get_local_node(true, false);

	sub->enabled = false;

	alter_subscription(sub);

	if (immediate)
	{
		SpockWorker *apply;

		if ((IsTransactionBlock() || IsSubTransaction()))
			ereport(ERROR,
					(errcode(ERRCODE_ACTIVE_SQL_TRANSACTION),
					 errmsg("alter_subscription_disable with immediate = true "
							"cannot be run inside a transaction block")));

		LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
		apply = spock_apply_find(MyDatabaseId, sub->id);
		spock_worker_kill(apply);
		LWLockRelease(SpockCtx->lock);
	}

	PG_RETURN_BOOL(true);
}

/*
 * Enable subscription.
 */
Datum spock_alter_subscription_enable(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	bool immediate = PG_GETARG_BOOL(1);
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);

	/* XXX: Only used for locking purposes. */
	(void)get_local_node(true, false);

	sub->enabled = true;

	alter_subscription(sub);

	/*
	 * There is nothing more to immediate here than running it outside of
	 * transaction.
	 */
	if (immediate && (IsTransactionBlock() || IsSubTransaction()))
	{
		ereport(ERROR,
				(errcode(ERRCODE_ACTIVE_SQL_TRANSACTION),
				 errmsg("alter_subscription_enable with immediate = true "
						"cannot be run inside a transaction block")));
	}

	PG_RETURN_BOOL(true);
}

/*
 * Switch interface the subscription is using.
 */
Datum spock_alter_subscription_interface(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	char *if_name = NameStr(*PG_GETARG_NAME(1));
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);
	SpockInterface *new_if;

	/* XXX: Only used for locking purposes. */
	(void)get_local_node(true, false);

	new_if = get_node_interface_by_name(sub->origin->id, if_name, false);

	if (new_if->id == sub->origin_if->id)
		PG_RETURN_BOOL(false);

	sub->origin_if = new_if;
	alter_subscription(sub);

	PG_RETURN_BOOL(true);
}

/*
 * Add replication set to subscription.
 */
Datum spock_alter_subscription_add_replication_set(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	char *repset_name = NameStr(*PG_GETARG_NAME(1));
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);
	ListCell *lc;

	foreach (lc, sub->replication_sets)
	{
		char *rs = (char *)lfirst(lc);

		if (strcmp(rs, repset_name) == 0)
			PG_RETURN_BOOL(false);
	}

	sub->replication_sets = lappend(sub->replication_sets, repset_name);
	alter_subscription(sub);

	PG_RETURN_BOOL(true);
}

/*
 * Remove replication set to subscription.
 */
Datum spock_alter_subscription_remove_replication_set(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	char *repset_name = NameStr(*PG_GETARG_NAME(1));
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);
	ListCell *lc;

	foreach (lc, sub->replication_sets)
	{
		char *rs = (char *)lfirst(lc);

		if (strcmp(rs, repset_name) == 0)
		{
			sub->replication_sets = foreach_delete_current(sub->replication_sets,
														   lc);
			alter_subscription(sub);

			PG_RETURN_BOOL(true);
		}
	}

	PG_RETURN_BOOL(false);
}

/*
 * Subscription skip lsn.
 */
Datum spock_alter_subscription_skip_lsn(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	XLogRecPtr	lsn = PG_GETARG_LSN(1);
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);

	/* XXX: Only used for locking purposes. */
	(void)get_local_node(true, false);

	sub->skiplsn = lsn;
	alter_subscription(sub);

	PG_RETURN_BOOL(true);
}

/*
 * Synchronize all the missing tables.
 */
Datum spock_alter_subscription_synchronize(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	bool truncate = PG_GETARG_BOOL(1);
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);
	PGconn *conn;
	List *remote_tables;
	List *local_tables;
	ListCell *lc;

	/* Read table list from provider. */
	conn = spock_connect(sub->origin_if->dsn, sub_name, "sync");
	remote_tables = spock_get_remote_repset_tables(conn, sub->replication_sets);
	PQfinish(conn);

	local_tables = get_subscription_tables(sub->id);

	/* Compare with sync status on subscription. And add missing ones. */
	foreach (lc, remote_tables)
	{
		SpockRemoteRel *remoterel = lfirst(lc);
		SpockSyncStatus *oldsync = NULL;
		ListCell *llc;

		foreach (llc, local_tables)
		{
			SpockSyncStatus *tablesync = (SpockSyncStatus *)lfirst(llc);

			if (namestrcmp(&tablesync->nspname, remoterel->nspname) == 0 &&
				namestrcmp(&tablesync->relname, remoterel->relname) == 0)
			{
				oldsync = tablesync;
				local_tables = foreach_delete_current(local_tables, llc);
				break;
			}
		}

		if (!oldsync)
		{
			SpockSyncStatus newsync;

			memset(&newsync, 0, sizeof(SpockSyncStatus));
			newsync.kind = SYNC_KIND_DATA;
			newsync.subid = sub->id;
			namestrcpy(&newsync.nspname, remoterel->nspname);
			namestrcpy(&newsync.relname, remoterel->relname);
			newsync.status = SYNC_STATUS_INIT;
			create_local_sync_status(&newsync);

			if (truncate)
				truncate_table(remoterel->nspname, remoterel->relname);
		}
	}

	/*
	 * Any leftover local tables should not be replicated, remove the status
	 * for them.
	 */
	foreach (lc, local_tables)
	{
		SpockSyncStatus *tablesync = (SpockSyncStatus *)lfirst(lc);

		drop_table_sync_status_for_sub(tablesync->subid,
									   NameStr(tablesync->nspname),
									   NameStr(tablesync->relname));
	}

	/* Tell apply to re-read sync statuses. */
	spock_subscription_changed(sub->id, false);

	PG_RETURN_BOOL(true);
}

/*
 * Resynchronize one existing table.
 */
Datum spock_alter_subscription_resynchronize_table(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	Oid reloid = PG_GETARG_OID(1);
	bool truncate = PG_GETARG_BOOL(2);
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);
	SpockSyncStatus *oldsync;
	Relation rel;
	char *nspname,
		*relname;

	rel = table_open(reloid, AccessShareLock);

	nspname = get_namespace_name(RelationGetNamespace(rel));
	relname = RelationGetRelationName(rel);

	/* Reset sync status of the table. */
	oldsync = get_table_sync_status(sub->id, nspname, relname, true);
	if (oldsync)
	{
		if (oldsync->status != SYNC_STATUS_READY &&
			oldsync->status != SYNC_STATUS_SYNCDONE &&
			oldsync->status != SYNC_STATUS_NONE)
			elog(ERROR, "table %s.%s is already being synchronized",
				 nspname, relname);

		set_table_sync_status(sub->id, nspname, relname, SYNC_STATUS_INIT,
							  InvalidXLogRecPtr);
	}
	else
	{
		SpockSyncStatus newsync;

		memset(&newsync, 0, sizeof(SpockSyncStatus));
		newsync.kind = SYNC_KIND_DATA;
		newsync.subid = sub->id;
		namestrcpy(&newsync.nspname, nspname);
		namestrcpy(&newsync.relname, relname);
		newsync.status = SYNC_STATUS_INIT;
		create_local_sync_status(&newsync);
	}

	table_close(rel, NoLock);

	if (truncate)
		truncate_table(nspname, relname);

	/* Tell apply to re-read sync statuses. */
	spock_subscription_changed(sub->id, false);

	PG_RETURN_BOOL(true);
}

/*
 * Synchronize one sequence.
 */
Datum spock_synchronize_sequence(PG_FUNCTION_ARGS)
{
	Oid reloid = PG_GETARG_OID(0);

	/* Check that this is actually a node. */
	(void)get_local_node(true, false);

	synchronize_sequence(reloid);

	PG_RETURN_BOOL(true);
}

static char *
sync_status_to_string(char status)
{
	switch (status)
	{
	case SYNC_STATUS_INIT:
		return "sync_init";
	case SYNC_STATUS_STRUCTURE:
		return "sync_structure";
	case SYNC_STATUS_DATA:
		return "sync_data";
	case SYNC_STATUS_CONSTRAINTS:
		return "sync_constraints";
	case SYNC_STATUS_SYNCWAIT:
		return "sync_waiting";
	case SYNC_STATUS_CATCHUP:
		return "catchup";
	case SYNC_STATUS_SYNCDONE:
		return "synchronized";
	case SYNC_STATUS_READY:
		return "replicating";
	default:
		return "unknown";
	}
}

/*
 * Show info about one table.
 */
Datum spock_show_subscription_table(PG_FUNCTION_ARGS)
{
	char *sub_name = NameStr(*PG_GETARG_NAME(0));
	Oid reloid = PG_GETARG_OID(1);
	SpockSubscription *sub = get_subscription_by_name(sub_name, false);
	char *nspname;
	char *relname;
	SpockSyncStatus *sync;
	char *sync_status;
	TupleDesc tupdesc;
	Datum values[3];
	bool nulls[3];
	HeapTuple result_tuple;

	tupdesc = CreateTemplateTupleDesc(3);
	TupleDescInitEntry(tupdesc, (AttrNumber)1, "nspname", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber)2, "relname", TEXTOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber)3, "status", TEXTOID, -1, 0);
	tupdesc = BlessTupleDesc(tupdesc);

	nspname = get_namespace_name(get_rel_namespace(reloid));
	relname = get_rel_name(reloid);

	/* Reset sync status of the table. */
	sync = get_table_sync_status(sub->id, nspname, relname, true);
	if (sync)
		sync_status = sync_status_to_string(sync->status);
	else
		sync_status = "unknown";

	memset(values, 0, sizeof(values));
	memset(nulls, 0, sizeof(nulls));

	values[0] = CStringGetTextDatum(nspname);
	values[1] = CStringGetTextDatum(relname);
	values[2] = CStringGetTextDatum(sync_status);

	result_tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(result_tuple));
}

/*
 * Show info about subscribtion.
 */
Datum spock_show_subscription_status(PG_FUNCTION_ARGS)
{
	List *subscriptions;
	ListCell *lc;
	ReturnSetInfo *rsinfo = (ReturnSetInfo *)fcinfo->resultinfo;
	TupleDesc tupdesc;
	Tuplestorestate *tupstore;
	SpockLocalNode *node;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;

	/* check to see if caller supports us returning a tuplestore */
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("materialize mode required, but it is not "
						"allowed in this context")));

	node = check_local_node(false);

	if (PG_ARGISNULL(0))
	{
		subscriptions = get_node_subscriptions(node->node->id, false);
	}
	else
	{
		SpockSubscription *sub;
		sub = get_subscription_by_name(NameStr(*PG_GETARG_NAME(0)), false);
		subscriptions = list_make1(sub);
	}

	/* Switch into long-lived context to construct returned data structures */
	per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);

	/* Build a tuple descriptor for our result type */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);

	foreach (lc, subscriptions)
	{
		SpockSubscription *sub = lfirst(lc);
		SpockWorker *apply;
		Datum values[7];
		bool nulls[7];
		char *status;

		memset(values, 0, sizeof(values));
		memset(nulls, 0, sizeof(nulls));

		LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
		apply = spock_apply_find(MyDatabaseId, sub->id);
		if (spock_worker_running(apply))
		{
			SpockSyncStatus *sync;
			sync = get_subscription_sync_status(sub->id, true);

			if (!sync)
				status = "unknown";
			else if (sync->status == SYNC_STATUS_READY)
				status = "replicating";
			else
				status = "initializing";
		}
		else if (!sub->enabled)
			status = "disabled";
		else
			status = "down";
		LWLockRelease(SpockCtx->lock);

		values[0] = CStringGetTextDatum(sub->name);
		values[1] = CStringGetTextDatum(status);
		values[2] = CStringGetTextDatum(sub->origin->name);
		values[3] = CStringGetTextDatum(sub->origin_if->dsn);
		values[4] = CStringGetTextDatum(sub->slot_name);
		if (sub->replication_sets)
			values[5] =
				PointerGetDatum(strlist_to_textarray(sub->replication_sets));
		else
			nulls[5] = true;
		if (sub->forward_origins)
			values[6] =
				PointerGetDatum(strlist_to_textarray(sub->forward_origins));
		else
			nulls[6] = true;

		tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	}

	PG_RETURN_VOID();
}

/*
 * Create new replication set.
 */
Datum spock_create_replication_set(PG_FUNCTION_ARGS)
{
	SpockRepSet repset;
	SpockLocalNode *node;

	node = check_local_node(true);

	repset.id = InvalidOid;

	repset.nodeid = node->node->id;
	repset.name = NameStr(*PG_GETARG_NAME(0));

	repset.replicate_insert = PG_GETARG_BOOL(1);
	repset.replicate_update = PG_GETARG_BOOL(2);
	repset.replicate_delete = PG_GETARG_BOOL(3);
	repset.replicate_truncate = PG_GETARG_BOOL(4);

	create_replication_set(&repset);

	PG_RETURN_OID(repset.id);
}

/*
 * Alter existing replication set.
 */
Datum spock_alter_replication_set(PG_FUNCTION_ARGS)
{
	SpockRepSet *repset;
	SpockLocalNode *node;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("set_name cannot be NULL")));

	node = check_local_node(true);

	repset = get_replication_set_by_name(node->node->id,
										 NameStr(*PG_GETARG_NAME(0)), false);

	if (!PG_ARGISNULL(1))
		repset->replicate_insert = PG_GETARG_BOOL(1);
	if (!PG_ARGISNULL(2))
		repset->replicate_update = PG_GETARG_BOOL(2);
	if (!PG_ARGISNULL(3))
		repset->replicate_delete = PG_GETARG_BOOL(3);
	if (!PG_ARGISNULL(4))
		repset->replicate_truncate = PG_GETARG_BOOL(4);

	alter_replication_set(repset);

	PG_RETURN_OID(repset->id);
}

/*
 * Drop existing replication set.
 */
Datum spock_drop_replication_set(PG_FUNCTION_ARGS)
{
	char *set_name = NameStr(*PG_GETARG_NAME(0));
	bool ifexists = PG_GETARG_BOOL(1);
	SpockRepSet *repset;
	SpockLocalNode *node;

	node = check_local_node(true);

	repset = get_replication_set_by_name(node->node->id, set_name, ifexists);

	if (repset != NULL)
		drop_replication_set(repset->id);

	PG_RETURN_BOOL(repset != NULL);
}

/*
 * error context callback for parse failure during spock_replication_set_add_table()
 */
static void
add_table_parser_error_callback(void *arg)
{
	const char *row_filter_str = (const char *)arg;

	errcontext("invalid row_filter expression \"%s\"", row_filter_str);

	/*
	 * Currently we just suppress any syntax error position report, rather
	 * than transforming to an "internal query" error.  It's unlikely that a
	 * type name is complex enough to need positioning.
	 */
	errposition(0);
}

static Node *
parse_row_filter(Relation rel, char *row_filter_str)
{
	Node *row_filter = NULL;
	List *raw_parsetree_list;
	SelectStmt *stmt;
	ResTarget *restarget;
	ParseState *pstate;
	char *nspname;
	char *relname;
	ParseNamespaceItem *nsitem;
	StringInfoData buf;
	ErrorContextCallback myerrcontext;

	nspname = get_namespace_name(RelationGetNamespace(rel));
	relname = RelationGetRelationName(rel);

	/*
	 * Build fake query which includes the expression so that we can
	 * pass it to the parser.
	 */
	initStringInfo(&buf);
	appendStringInfo(&buf, "SELECT %s FROM %s", row_filter_str,
					 quote_qualified_identifier(nspname, relname));

	/* Parse it, providing proper error context. */
	myerrcontext.callback = add_table_parser_error_callback;
	myerrcontext.arg = (void *)row_filter_str;
	myerrcontext.previous = error_context_stack;
	error_context_stack = &myerrcontext;

	raw_parsetree_list = pg_parse_query(buf.data);

	error_context_stack = myerrcontext.previous;

	/* Validate the output from the parser. */
	if (list_length(raw_parsetree_list) != 1)
		goto fail;
	stmt = (SelectStmt *)linitial_node(RawStmt, raw_parsetree_list)->stmt;
	if (stmt == NULL ||
		!IsA(stmt, SelectStmt) ||
		stmt->distinctClause != NIL ||
		stmt->intoClause != NULL ||
		stmt->whereClause != NULL ||
		stmt->groupClause != NIL ||
		stmt->havingClause != NULL ||
		stmt->windowClause != NIL ||
		stmt->valuesLists != NIL ||
		stmt->sortClause != NIL ||
		stmt->limitOffset != NULL ||
		stmt->limitCount != NULL ||
		stmt->lockingClause != NIL ||
		stmt->withClause != NULL ||
		stmt->op != SETOP_NONE)
		goto fail;
	if (list_length(stmt->targetList) != 1)
		goto fail;
	restarget = (ResTarget *)linitial(stmt->targetList);
	if (restarget == NULL ||
		!IsA(restarget, ResTarget) ||
		restarget->name != NULL ||
		restarget->indirection != NIL ||
		restarget->val == NULL)
		goto fail;

	row_filter = restarget->val;

	/*
	 * Create a dummy ParseState and insert the target relation as its sole
	 * rangetable entry.  We need a ParseState for transformExpr.
	 */
	pstate = make_parsestate(NULL);
	nsitem = addRangeTableEntryForRelation(pstate,
										   rel,
										   AccessShareLock,
										   NULL,
										   false,
										   true);
	addNSItemToQuery(pstate, nsitem, true, true, true);
	/*
	 * Transform the expression and check it follows limits of row_filter
	 * which are same as those of CHECK constraint so we can use the builtin
	 * checks for that.
	 *
	 * TODO: make the errors look more informative (currently they will
	 * complain about CHECK constraint. (Possibly add context?)
	 */
	row_filter = transformExpr(pstate, row_filter, EXPR_KIND_CHECK_CONSTRAINT);
	row_filter = coerce_to_boolean(pstate, row_filter, "row_filter");
	assign_expr_collations(pstate, row_filter);
	if (list_length(pstate->p_rtable) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_COLUMN_REFERENCE),
				 errmsg("only table \"%s\" can be referenced in row_filter",
						relname)));
	pfree(buf.data);

	return row_filter;

fail:
	ereport(ERROR,
			(errcode(ERRCODE_SYNTAX_ERROR),
			 errmsg("invalid row_filter expression \"%s\"", row_filter_str)));
	return NULL; /* keep compiler quiet */
}

/*
 * Add replication set / table mapping.
 */
Datum spock_replication_set_add_table(PG_FUNCTION_ARGS)
{
	Name repset_name;
	Oid reloid;
	bool synchronize;
	Node *row_filter = NULL;
	List *att_list = NIL;
	SpockRepSet *repset;
	Relation rel;
	TupleDesc tupDesc;
	SpockLocalNode *node;
	char *nspname;
	char *relname;
	StringInfoData json;
	bool inc_partitions;
	List *reloids = NIL;
	ListCell *lc;

	/* Proccess for required parameters. */
	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("set_name cannot be NULL")));
	if (PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("relation cannot be NULL")));
	if (PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("synchronize_data cannot be NULL")));

	repset_name = PG_GETARG_NAME(0);
	reloid = PG_GETARG_OID(1);
	synchronize = PG_GETARG_BOOL(2);
	inc_partitions = PG_GETARG_BOOL(5);

	/* standard check for node. */
	node = check_local_node(true);

	/* Find the replication set. */
	repset = get_replication_set_by_name(node->node->id,
										 NameStr(*repset_name), false);

	/*
	 * Make sure the relation exists (lock mode has to be the same one as
	 * in replication_set_add_relation).
	 */
	rel = table_open(reloid, ShareRowExclusiveLock);
	tupDesc = RelationGetDescr(rel);

	nspname = get_namespace_name(RelationGetNamespace(rel));
	relname = pstrdup(RelationGetRelationName(rel));

	/* Proccess att_list. */
	if (!PG_ARGISNULL(3))
	{
		ArrayType *att_names = PG_GETARG_ARRAYTYPE_P(3);
		Bitmapset *idattrs;

		/* fetch bitmap of REPLICATION IDENTITY attributes */
		idattrs = RelationGetIndexAttrBitmap(rel, INDEX_ATTR_BITMAP_IDENTITY_KEY);

		att_list = textarray_to_list(att_names);
		foreach (lc, att_list)
		{
			char *attname = (char *)lfirst(lc);
			int attnum = get_att_num_by_name(tupDesc, attname);

			if (attnum < 0)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("table %s does not have column %s",
								quote_qualified_identifier(nspname, relname),
								attname)));

			idattrs = bms_del_member(idattrs,
									 attnum - FirstLowInvalidHeapAttributeNumber);
		}

		if (!bms_is_empty(idattrs))
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("REPLICA IDENTITY columns must be replicated")));
	}

	/* Proccess row_filter if any. */
	if (!PG_ARGISNULL(4))
	{
		row_filter = parse_row_filter(rel,
									  text_to_cstring(PG_GETARG_TEXT_PP(4)));
	}

	if (inc_partitions && rel->rd_rel->relkind == RELKIND_PARTITIONED_TABLE)
		reloids = find_all_inheritors(reloid, NoLock, NULL);
	else
		reloids = lappend_oid(reloids, reloid);

	/* Need to close the relation for doing ALTER TABLE */
	table_close(rel, NoLock);

	foreach (lc, reloids)
	{
		Oid partoid = lfirst_oid(lc);

		replication_set_add_table(repset->id, partoid, att_list, row_filter);

		/* In case of partitions, only synchronize the parent table. */
		if (synchronize && (partoid == reloid))
		{
			/* It's easier to construct json manually than via Jsonb API... */
			initStringInfo(&json);
			appendStringInfo(&json, "{\"schema_name\": ");
			escape_json(&json, nspname);
			appendStringInfo(&json, ",\"table_name\": ");
			escape_json(&json, relname);
			appendStringInfo(&json, "}");
			/* Queue the synchronize request for replication. */
			queue_message(list_make1(repset->name), GetUserId(),
						  QUEUE_COMMAND_TYPE_TABLESYNC, json.data);
		}
	}

	PG_RETURN_BOOL(true);
}

/*
 * Add replication set / sequence mapping.
 */
Datum spock_replication_set_add_sequence(PG_FUNCTION_ARGS)
{
	Name repset_name = PG_GETARG_NAME(0);
	Oid reloid = PG_GETARG_OID(1);
	bool synchronize = PG_GETARG_BOOL(2);
	SpockRepSet *repset;
	Relation rel;
	SpockLocalNode *node;
	char *nspname;
	char *relname;
	StringInfoData json;

	node = check_local_node(true);

	/* Find the replication set. */
	repset = get_replication_set_by_name(node->node->id,
										 NameStr(*repset_name), false);

	/*
	 * Make sure the relation exists (lock mode has to be the same one as
	 * in replication_set_add_relation).
	 */
	rel = table_open(reloid, ShareRowExclusiveLock);

	replication_set_add_seq(repset->id, reloid);

	if (synchronize)
	{
		nspname = get_namespace_name(RelationGetNamespace(rel));
		relname = RelationGetRelationName(rel);

		/* It's easier to construct json manually than via Jsonb API... */
		initStringInfo(&json);
		appendStringInfo(&json, "{\"schema_name\": ");
		escape_json(&json, nspname);
		appendStringInfo(&json, ",\"sequence_name\": ");
		escape_json(&json, relname);
		appendStringInfo(&json, ",\"last_value\": \"" INT64_FORMAT "\"",
						 sequence_get_last_value(reloid));
		appendStringInfo(&json, "}");

		/* Add sequence to the queue. */
		queue_message(list_make1(repset->name), GetUserId(),
					  QUEUE_COMMAND_TYPE_SEQUENCE, json.data);
	}

	/* Cleanup. */
	table_close(rel, NoLock);

	PG_RETURN_BOOL(true);
}

/*
 * Common function for adding replication set / relation mapping based on
 * schemas.
 */
static Datum
spock_replication_set_add_all_relations(Name repset_name,
										ArrayType *nsp_names,
										bool synchronize, char relkind)
{
	SpockRepSet *repset;
	Relation rel;
	SpockLocalNode *node;
	ListCell *lc;
	List *existing_relations = NIL;

	node = check_local_node(true);

	/* Find the replication set. */
	repset = get_replication_set_by_name(node->node->id,
										 NameStr(*repset_name), false);

	existing_relations = replication_set_get_tables(repset->id);
	existing_relations = list_concat_unique_oid(existing_relations,
												replication_set_get_seqs(repset->id));

	rel = table_open(RelationRelationId, RowExclusiveLock);

	foreach (lc, textarray_to_list(nsp_names))
	{
		char *nspname = lfirst(lc);
		Oid nspoid = LookupExplicitNamespace(nspname, false);
		ScanKeyData skey[1];
		SysScanDesc sysscan;
		HeapTuple tuple;

		ScanKeyInit(&skey[0],
					Anum_pg_class_relnamespace,
					BTEqualStrategyNumber, F_OIDEQ,
					ObjectIdGetDatum(nspoid));

		sysscan = systable_beginscan(rel, ClassNameNspIndexId, true,
									 NULL, 1, skey);

		while (HeapTupleIsValid(tuple = systable_getnext(sysscan)))
		{
			Form_pg_class reltup = (Form_pg_class)GETSTRUCT(tuple);
			Oid reloid = reltup->oid;

			/*
			 * Only add logged relations which are not system relations
			 * (catalog, toast).
			 * Include partitioned tables as well.
			 */
			if ((reltup->relkind != RELKIND_PARTITIONED_TABLE &&
				 reltup->relkind != relkind) ||
				reltup->relpersistence != RELPERSISTENCE_PERMANENT ||
				IsSystemClass(reloid, reltup))
				continue;

			if (!list_member_oid(existing_relations, reloid))
			{
				bool ispartition;

				if (relkind == RELKIND_RELATION || relkind == RELKIND_PARTITIONED_TABLE)
				{
					replication_set_add_table(repset->id, reloid, NIL, NULL);
				}
				else
					/* FIXME: What happens if the id is a snowflake sequence? */
					replication_set_add_seq(repset->id, reloid);

				/* don't synchronize the partitions */
				ispartition = get_rel_relispartition(reloid);
				if (synchronize && !ispartition)
				{
					char *relname;
					StringInfoData json;
					char cmdtype;

					relname = get_rel_name(reloid);

					/* It's easier to construct json manually than via Jsonb API... */
					initStringInfo(&json);
					appendStringInfo(&json, "{\"schema_name\": ");
					escape_json(&json, nspname);
					switch (relkind)
					{
					case RELKIND_RELATION:
						appendStringInfo(&json, ",\"table_name\": ");
						escape_json(&json, relname);
						cmdtype = QUEUE_COMMAND_TYPE_TABLESYNC;
						break;
					case RELKIND_SEQUENCE:
						appendStringInfo(&json, ",\"sequence_name\": ");
						escape_json(&json, relname);
						appendStringInfo(&json, ",\"last_value\": \"" INT64_FORMAT "\"",
										 sequence_get_last_value(reloid));
						cmdtype = QUEUE_COMMAND_TYPE_SEQUENCE;
						break;
					default:
						elog(ERROR, "unsupported relkind '%c'", relkind);
					}
					appendStringInfo(&json, "}");

					/* Queue the truncate for replication. */
					queue_message(list_make1(repset->name), GetUserId(), cmdtype,
								  json.data);
				}
			}
		}

		systable_endscan(sysscan);
	}

	table_close(rel, RowExclusiveLock);

	PG_RETURN_BOOL(true);
}

/*
 * Add replication set / table mapping based on schemas.
 */
Datum spock_replication_set_add_all_tables(PG_FUNCTION_ARGS)
{
	Name repset_name = PG_GETARG_NAME(0);
	ArrayType *nsp_names = PG_GETARG_ARRAYTYPE_P(1);
	bool synchronize = PG_GETARG_BOOL(2);

	return spock_replication_set_add_all_relations(repset_name, nsp_names,
												   synchronize,
												   RELKIND_RELATION);
}

/*
 * Add replication set / sequence mapping based on schemas.
 */
Datum spock_replication_set_add_all_sequences(PG_FUNCTION_ARGS)
{
	Name repset_name = PG_GETARG_NAME(0);
	ArrayType *nsp_names = PG_GETARG_ARRAYTYPE_P(1);
	bool synchronize = PG_GETARG_BOOL(2);

	return spock_replication_set_add_all_relations(repset_name, nsp_names,
												   synchronize,
												   RELKIND_SEQUENCE);
}

/*
 * Remove replication set / table mapping.
 *
 * Unlike the spock_replication_set_add_table, this function does not care
 * if table is valid or not, as we are just removing the record from repset.
 */
Datum spock_replication_set_remove_table(PG_FUNCTION_ARGS)
{
	Oid reloid = PG_GETARG_OID(1);
	SpockRepSet *repset;
	SpockLocalNode *node;
	char relkind;
	bool inc_partitions;
	List *reloids = NIL;
	ListCell *lc;

	node = check_local_node(true);

	/* Find the replication set. */
	repset = get_replication_set_by_name(node->node->id,
										 NameStr(*PG_GETARG_NAME(0)), false);

	inc_partitions = PG_GETARG_BOOL(2);
	relkind = get_rel_relkind(reloid);
	if (relkind == RELKIND_PARTITIONED_TABLE && inc_partitions)
		reloids = find_all_inheritors(reloid, NoLock, NULL);
	else
		reloids = lappend_oid(reloids, reloid);

	foreach (lc, reloids)
	{
		Oid partoid = lfirst_oid(lc);
		bool ignore_err = false;

		/*
		 * Ignore error reporting for a missing partitions. It's possible that
		 * we have dropped some partitions at one point, and then we try to drop
		 * all partitions.
		 */
		ignore_err = get_rel_relispartition(partoid);
		replication_set_remove_table(repset->id, partoid, ignore_err);
	}

	PG_RETURN_BOOL(true);
}

/*
 * Remove replication set / sequence mapping.
 */
Datum spock_replication_set_remove_sequence(PG_FUNCTION_ARGS)
{
	Oid seqoid = PG_GETARG_OID(1);
	SpockRepSet *repset;
	SpockLocalNode *node;

	node = check_local_node(true);

	/* Find the replication set. */
	repset = get_replication_set_by_name(node->node->id,
										 NameStr(*PG_GETARG_NAME(0)), false);

	replication_set_remove_seq(repset->id, seqoid, false);

	PG_RETURN_BOOL(true);
}

Datum spock_replication_set_add_partition(PG_FUNCTION_ARGS)
{
	Relation rel;
	Oid parent_reloid = InvalidOid;
	Oid partition_rel = InvalidOid;
	SpockLocalNode *local_node;
	List *repsets = NIL;
	List *reloids = NIL;
	Node *row_filter = NULL;
	ListCell *lc;
	int nrows = 0;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("parent table cannot be NULL")));

	parent_reloid = PG_GETARG_OID(0);
	rel = table_open(parent_reloid, AccessShareLock);

	/* specific partition */
	if (!PG_ARGISNULL(1))
		partition_rel = PG_GETARG_OID(1);

	/* row filter */
	if (!PG_ARGISNULL(2))
	{
		/* Proccess row_filter if any. */
		row_filter = parse_row_filter(rel,
									  text_to_cstring(PG_GETARG_TEXT_PP(2)));
	}

	/* standard check for node. */
	local_node = check_local_node(true);
	repsets = get_table_replication_sets(local_node->node->id, parent_reloid);

	/* relation is not partitioned. nothing to do here. */
	if (rel->rd_rel->relkind != RELKIND_PARTITIONED_TABLE)
	{
		table_close(rel, NoLock);
		PG_RETURN_INT32(0);
	}

	/* prepare list of tables/partitions to be removed from replication set */
	if (OidIsValid(partition_rel))
		reloids = lappend_oid(reloids, partition_rel);
	else
		reloids = find_all_inheritors(parent_reloid, NoLock, NULL);

	foreach (lc, repsets)
	{
		SpockRepSet *repset = (SpockRepSet *)lfirst(lc);
		List *att_list = NIL;
		Node *reptbl_row_filter = NULL;
		ListCell *rlc;

		/* get columns list and row filter for the parent table. */
		get_table_replication_row(repset->id, parent_reloid, &att_list, &reptbl_row_filter);

		/* use parent's row_filter, if not given. */
		if (row_filter == NULL)
			row_filter = reptbl_row_filter;

		foreach (rlc, reloids)
		{
			Oid partoid = lfirst_oid(rlc);

			/* skip adding parent table, It's already there. */
			if (partoid == parent_reloid)
				continue;

			/* skip, if a partitions already existed. */
			if (get_table_replication_row(repset->id, partoid, NULL, NULL))
				continue;

			replication_set_add_table(repset->id, partoid, att_list, row_filter);
			nrows++;
		}

		if (reptbl_row_filter)
			pfree(reptbl_row_filter);
		list_free(att_list);
	}

	table_close(rel, NoLock);
	PG_RETURN_INT32(nrows);
}

Datum spock_replication_set_remove_partition(PG_FUNCTION_ARGS)
{
	Relation rel;
	Oid parent_reloid = InvalidOid;
	Oid partition_rel = InvalidOid;
	SpockLocalNode *local_node;
	List *repsets = NIL;
	List *reloids = NIL;
	ListCell *lc;
	int nrows = 0;
	bool ignore_err = false;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("parent table cannot be NULL")));

	parent_reloid = PG_GETARG_OID(0);
	rel = table_open(parent_reloid, AccessShareLock);

	/* specific partition */
	if (!PG_ARGISNULL(1))
		partition_rel = PG_GETARG_OID(1);

	/* standard check for node. */
	local_node = check_local_node(true);
	repsets = get_table_replication_sets(local_node->node->id, parent_reloid);

	/* relation is not partitioned. nothing to do here. */
	if (rel->rd_rel->relkind != RELKIND_PARTITIONED_TABLE)
	{
		table_close(rel, NoLock);
		PG_RETURN_INT32(0);
	}

	/* prepare list of tables/partitions to be removed from replication set */
	if (OidIsValid(partition_rel))
		reloids = lappend_oid(reloids, partition_rel);
	else
		reloids = find_all_inheritors(parent_reloid, NoLock, NULL);

	ignore_err = list_length(reloids) > 1;
	foreach (lc, repsets)
	{
		SpockRepSet *repset = (SpockRepSet *)lfirst(lc);
		ListCell *rlc;

		foreach (rlc, reloids)
		{
			Oid partoid = lfirst_oid(rlc);

			/* skip parent table being removed. */
			if (partoid == parent_reloid)
				continue;

			/*
			 * don't report error while removing multiple parttions. some of
			 * them may have been removed.
			 */
			replication_set_remove_table(repset->id, partoid, ignore_err);
			nrows++;
		}
	}

	table_close(rel, NoLock);
	PG_RETURN_INT32(nrows);
}

/*
 * spock_replicate_ddl_command
 *
 * Queues the input SQL for replication.
 */
Datum spock_replicate_ddl_command(PG_FUNCTION_ARGS)
{
	text *command = PG_GETARG_TEXT_PP(0);
	char *query = text_to_cstring(command);
	int save_nestlevel;
	List *replication_sets;
	ListCell *lc;
	SpockLocalNode *node;
	StringInfoData cmd;
	StringInfoData q;
	List *path_list = NIL;
	char *search_path;
	char *role;

	node = check_local_node(false);

	replication_sets = textarray_to_list(PG_GETARG_ARRAYTYPE_P(1));
	search_path = text_to_cstring(PG_GETARG_TEXT_PP(2));
	role = text_to_cstring(PG_GETARG_TEXT_PP(3));

	/* validate given search path */
	if (!check_search_path(&search_path, NULL, PGC_S_SESSION))
		elog(ERROR, "provided search path is not valid");

	/* Validate replication sets. */
	foreach (lc, replication_sets)
	{
		char *setname = lfirst(lc);

		(void)get_replication_set_by_name(node->node->id, setname, false);
	}

	save_nestlevel = NewGUCNestLevel();

	/* Force everything in the query to be fully qualified. */
	(void)set_config_option("search_path", search_path,
							PGC_USERSET, PGC_S_SESSION,
							GUC_ACTION_SAVE, true, 0, false);

	/* Add search path to the query for execution on the target node */
	initStringInfo(&q);
	SplitIdentifierString(search_path, ',', &path_list);
	if (path_list != NIL)
	{
		ListCell *lc2;

		appendStringInfoString(&q, "SET search_path TO ");
		foreach (lc2, path_list)
		{
			if (lc2 != list_head(path_list))
				appendStringInfoChar(&q, ',');
			appendStringInfo(&q, "%s", quote_identifier((char *)lfirst(lc2)));
		}
		appendStringInfo(&q, "; ");
	}
	else
		appendStringInfo(&q, "SET search_path TO ''; ");
	appendStringInfoString(&q, query);

	/* Convert the query to json string. */
	initStringInfo(&cmd);
	escape_json(&cmd, q.data);

	/* Queue the query for replication. */
	queue_message(replication_sets, get_role_oid(role, false),
				  QUEUE_COMMAND_TYPE_SQL, cmd.data);

	/*
	 * Execute the query locally.
	 * Use PG_TRY to ensure in_spock_replicate_ddl_command gets cleaned up
	 */
	in_spock_replicate_ddl_command = true;
	PG_TRY();
	{
		spock_execute_sql_command(query, role, false);
	}
	PG_CATCH();
	{
		in_spock_replicate_ddl_command = false;
		PG_RE_THROW();
	}
	PG_END_TRY();

	in_spock_replicate_ddl_command = false;

	/*
	 * Restore the GUC variables we set above.
	 */
	AtEOXact_GUC(true, save_nestlevel);

	PG_RETURN_BOOL(true);
}

/*
 * spock_auto_replicate_ddl
 *
 * Add the DDL statement to the spock.queue table so it can
 * be replicated to connected nodes. It also sends the current
 * search_path along with the query.
 */
void
spock_auto_replicate_ddl(const char *query, List *replication_sets,
						 Oid roleoid, Node *stmt)
{
	ListCell *lc;
	SpockLocalNode *node;
	StringInfoData	cmd;
	StringInfoData	q;
	char		   *search_path;
	bool			add_search_path = true;
	bool			warn = false;

	node = check_local_node(false);

	/* Validate replication sets. */
	foreach (lc, replication_sets)
	{
		char *setname = lfirst(lc);

		(void)get_replication_set_by_name(node->node->id, setname, false);
	}

	/* not all objects require search path setting. */
	switch(nodeTag(stmt))
	{
		case T_CreatedbStmt:	/* DATABASE */
		case T_DropdbStmt:
		case T_AlterDatabaseStmt:
#if PG_VERSION_NUM >= 150000
		case T_AlterDatabaseRefreshCollStmt:
#endif
		case T_AlterDatabaseSetStmt:
		case T_AlterSystemStmt:		/* ALTER SYSTEM */
		case T_CreateSubscriptionStmt:	/* SUBSCRIPTION */
		case T_DropSubscriptionStmt:
		case T_AlterSubscriptionStmt:
			add_search_path = false;
			goto skip_ddl;
			break;
		case T_AlterOwnerStmt:
			if (castNode(AlterOwnerStmt, stmt)->objectType == OBJECT_DATABASE ||
				castNode(AlterOwnerStmt, stmt)->objectType == OBJECT_SUBSCRIPTION)
				goto skip_ddl;
			if (castNode(AlterOwnerStmt, stmt)->objectType == OBJECT_TABLESPACE)
				add_search_path = false;
			break;

		case T_RenameStmt:
			if (castNode(RenameStmt, stmt)->renameType == OBJECT_DATABASE ||
				castNode(RenameStmt, stmt)->renameType == OBJECT_SUBSCRIPTION)
				goto skip_ddl;
			if (castNode(RenameStmt, stmt)->renameType == OBJECT_TABLESPACE)
				add_search_path = false;
			break;

		case T_CreateTableAsStmt:
			{
				CreateTableAsStmt *ctas = castNode(CreateTableAsStmt, stmt);

				if (ctas->into->rel->relpersistence == RELPERSISTENCE_TEMP)
					goto skip_ddl;
				if (castNode(Query, ctas->query)->commandType == CMD_UTILITY &&
					IsA(castNode(Query, ctas->query)->utilityStmt, ExecuteStmt))
						goto skip_ddl;
				warn = true;
			}
			break;

		case T_CreateStmt:
			if (castNode(CreateStmt, stmt)->relation->relpersistence == RELPERSISTENCE_TEMP)
				goto skip_ddl;
			break;

		case T_CreateSeqStmt:
			if (castNode(CreateSeqStmt, stmt)->sequence->relpersistence == RELPERSISTENCE_TEMP)
				goto skip_ddl;
			break;

		case T_ViewStmt:
			if (castNode(ViewStmt, stmt)->view->relpersistence == RELPERSISTENCE_TEMP)
				goto skip_ddl;
			break;

		case T_CreateTableSpaceStmt:	/* TABLESPACE */
		case T_DropTableSpaceStmt:
		case T_AlterTableSpaceOptionsStmt:
		case T_ClusterStmt:				/* CLUSTER */
			add_search_path = false;
			break;

		case T_AlterTableStmt:
			{
				ListCell *cell;
				AlterTableStmt *atstmt = (AlterTableStmt *) stmt;

				foreach(cell, atstmt->cmds)
				{
					AlterTableCmd *cmd = (AlterTableCmd *) lfirst(cell);
					if (cmd->subtype == AT_DetachPartition &&
						((PartitionCmd *) cmd->def)->concurrent)
						goto skip_ddl;
				}
			}
			break;

		case T_IndexStmt:
			if (castNode(IndexStmt, stmt)->concurrent)
				goto skip_ddl;
			break;

		case T_DropStmt:
			if (castNode(DropStmt, stmt)->removeType == OBJECT_INDEX &&
				castNode(DropStmt, stmt)->concurrent)
				goto skip_ddl;
			break;

		case T_ExplainStmt:		/* for EXPLAIN ANALYZE only */
			{
				ListCell   *cell;
				ExplainStmt *estmt = (ExplainStmt *) stmt;
				bool		analyze = false;

				/* Look through an EXPLAIN ANALYZE to the contained stmt */
				foreach(cell, estmt->options)
				{
					DefElem    *opt = (DefElem *) lfirst(cell);

					if (strcmp(opt->defname, "analyze") == 0)
						analyze = defGetBoolean(opt);
					/* don't "break", as explain.c will use the last value */
				}

				if (analyze &&
					castNode(Query, estmt->query)->commandType == CMD_UTILITY)
				{
					spock_auto_replicate_ddl(query, replication_sets, roleoid,
							castNode(Query, estmt->query)->utilityStmt);
				}

				return;		/* nothing more to do. */
			}
			break;

		default:
			add_search_path = true;
			break;
	}

	if (warn)
		elog(WARNING, "DDL statement replicated, but could be unsafe.");
	else
		elog(INFO, "DDL statement replicated.");

	initStringInfo(&q);
	if (add_search_path)
	{
		/* Add search path to the query for execution on the target node */
		search_path = GetConfigOptionByName("search_path", NULL, false);
		if (strlen(search_path) > 0)
			appendStringInfo(&q, "SET search_path TO %s; ", search_path);
		else
			appendStringInfo(&q, "SET search_path TO ''; ");
	}
	/* add query to buffer */
	appendStringInfoString(&q, query);

	/* Convert the query to json string. */
	initStringInfo(&cmd);
	escape_json(&cmd, q.data);

	/* Queue the query for replication. */
	queue_message(replication_sets, roleoid, QUEUE_COMMAND_TYPE_DDL, cmd.data);

	return;

skip_ddl:
	elog(WARNING, "This DDL statement will not be replicated.");
}


/*
 * spock_dependency_check_trigger
 *
 * No longer used, present for smoother upgrades.
 */
Datum spock_dependency_check_trigger(PG_FUNCTION_ARGS)
{
	PG_RETURN_VOID();
}

Datum spock_node_info(PG_FUNCTION_ARGS)
{
	TupleDesc tupdesc;
	Datum values[8];
	bool nulls[8];
	HeapTuple htup;
	char sysid[32];
	List *repsets;
	SpockLocalNode *node;

	/* Build a tuple descriptor for our result type */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	tupdesc = BlessTupleDesc(tupdesc);

	node = get_local_node(false, false);

	snprintf(sysid, sizeof(sysid), UINT64_FORMAT,
			 GetSystemIdentifier());
	repsets = get_node_replication_sets(node->node->id);

	memset(nulls, 0, sizeof(nulls));
	values[0] = ObjectIdGetDatum(node->node->id);
	values[1] = CStringGetTextDatum(node->node->name);
	values[2] = CStringGetTextDatum(sysid);
	values[3] = CStringGetTextDatum(get_database_name(MyDatabaseId));
	values[4] = CStringGetTextDatum(repsetslist_to_identifierstr(repsets));

	if (node->node->location)
		values[5] = CStringGetTextDatum(node->node->location);
	else
		nulls[5] = true;

	if (node->node->country)
		values[6] = CStringGetTextDatum(node->node->country);
	else
		nulls[6] = true;

	if (node->node->info)
		values[7] = JsonbPGetDatum(node->node->info);
	else
		nulls[7] = true;

	htup = heap_form_tuple(tupdesc, values, nulls);

	PG_RETURN_DATUM(HeapTupleGetDatum(htup));
}

/*
 * Get replication info about table.
 *
 * This is called by downstream sync worker on the upstream to obtain
 * info needed to do initial synchronization correctly. Be careful
 * about changing it, as it must be upward- and downward-compatible.
 */
Datum spock_show_repset_table_info(PG_FUNCTION_ARGS)
{
	Oid reloid = PG_GETARG_OID(0);
	ArrayType *rep_set_names = PG_GETARG_ARRAYTYPE_P(1);
	Relation rel;
	List *replication_sets;
	TupleDesc reldesc;
	TupleDesc rettupdesc;
	int i;
	List *att_list = NIL;
	Datum values[7];
	bool nulls[7];
	char *nspname;
	char *relname;
	HeapTuple htup;
	SpockLocalNode *node;
	SpockTableRepInfo *tableinfo;

	node = get_local_node(false, false);

	/* Build a tuple descriptor for our result type */
	if (get_call_result_type(fcinfo, NULL, &rettupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	rettupdesc = BlessTupleDesc(rettupdesc);

	rel = table_open(reloid, AccessShareLock);
	reldesc = RelationGetDescr(rel);
	replication_sets = textarray_to_list(rep_set_names);
	replication_sets = get_replication_sets(node->node->id,
											replication_sets,
											false);

	nspname = get_namespace_name(RelationGetNamespace(rel));
	relname = RelationGetRelationName(rel);

	/* Build the replication info for the table. */
	tableinfo = get_table_replication_info(node->node->id, rel,
										   replication_sets);

	/* Build the column list. */
	for (i = 0; i < reldesc->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(reldesc, i);

		/* Skip dropped columns. */
		if (att->attisdropped)
			continue;

		/* Skip filtered columns if any. */
		if (tableinfo->att_list &&
			!bms_is_member(att->attnum - FirstLowInvalidHeapAttributeNumber,
						   tableinfo->att_list))
			continue;

		att_list = lappend(att_list, NameStr(att->attname));
	}

	/* And now build the result. */
	memset(nulls, false, sizeof(nulls));
	values[0] = ObjectIdGetDatum(RelationGetRelid(rel));
	values[1] = CStringGetTextDatum(nspname);
	values[2] = CStringGetTextDatum(relname);
	values[3] = PointerGetDatum(strlist_to_textarray(att_list));
	values[4] = BoolGetDatum(list_length(tableinfo->row_filter) > 0);
	values[5] = CharGetDatum(rel->rd_rel->relkind);
	values[6] = BoolGetDatum(rel->rd_rel->relispartition);

	htup = heap_form_tuple(rettupdesc, values, nulls);

	table_close(rel, NoLock);

	PG_RETURN_DATUM(HeapTupleGetDatum(htup));
}

/*
 * Dummy function to allow upgrading through all intermediate versions
 */
Datum spock_show_repset_table_info_by_target(PG_FUNCTION_ARGS)
{
	abort();
}

/*
 * Do sequential table scan and return all rows that pass the row filter(s)
 * defined in speficied replication set(s) for a table.
 *
 * This is called by downstream sync worker on the upstream to obtain
 * filtered data for initial COPY.
 */
Datum spock_table_data_filtered(PG_FUNCTION_ARGS)
{
	Oid argtype = get_fn_expr_argtype(fcinfo->flinfo, 0);
	Oid reloid;
	ArrayType *rep_set_names;
	ReturnSetInfo *rsi;
	Relation rel;
	List *replication_sets;
	ListCell *lc;
	TupleDesc tupdesc;
	TupleDesc reltupdesc;
	EState *estate;
	ExprContext *econtext;
	Tuplestorestate *tupstore;
	SpockLocalNode *node;
	SpockTableRepInfo *tableinfo;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;
	StringInfoData query;
	int i = 0;
	int rc;

	node = get_local_node(false, false);

	/* Validate parameter. */
	if (PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("relation cannot be NULL")));
	if (PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("repsets cannot be NULL")));

	reloid = PG_GETARG_OID(1);
	rep_set_names = PG_GETARG_ARRAYTYPE_P(2);

	if (!type_is_rowtype(argtype))
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("first argument of %s must be a row type",
						"spock_table_data_filtered")));

	rsi = (ReturnSetInfo *)fcinfo->resultinfo;

	if (!rsi || !IsA(rsi, ReturnSetInfo) ||
		(rsi->allowedModes & SFRM_Materialize) == 0 ||
		rsi->expectedDesc == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that "
						"cannot accept a set")));

	/* Switch into long-lived context to construct returned data structures */
	per_query_ctx = rsi->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);

	/*
	 * get the tupdesc from the result set info - it must be a record type
	 * because we already checked that arg1 is a record type, or we're in a
	 * to_record function which returns a setof record.
	 */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context "
						"that cannot accept type record")));
	tupdesc = BlessTupleDesc(tupdesc);

	/* Prepare output tuple store. */
	tupstore = tuplestore_begin_heap(false, false, work_mem);
	rsi->returnMode = SFRM_Materialize;
	rsi->setResult = tupstore;
	rsi->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);

	/* Check output type and table row type are the same. */
	rel = table_open(reloid, AccessShareLock);
	reltupdesc = RelationGetDescr(rel);
	if (!equalTupleDescs(tupdesc, reltupdesc))
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("return type of %s must be same as row type of the relation",
						"spock_table_data_filtered")));

	/* Build the replication info for the table. */
	replication_sets = textarray_to_list(rep_set_names);
	replication_sets = get_replication_sets(node->node->id,
											replication_sets,
											false);
	tableinfo = get_table_replication_info(node->node->id, rel,
										   replication_sets);

	/* Prepare executor. */
	estate = create_estate_for_relation(rel, false);
	econtext = prepare_per_tuple_econtext(estate, reltupdesc);

	/* Prepare query with row filter expression. */
	initStringInfo(&query);
	appendStringInfo(&query, "SELECT * FROM %s.%s",
					 quote_identifier(get_namespace_name(RelationGetNamespace(rel))),
					 quote_identifier(RelationGetRelationName(rel)));

	if (list_length(tableinfo->row_filter) > 0)
		appendStringInfoString(&query, " WHERE ");

	foreach (lc, tableinfo->row_filter)
	{
		Node *row_filter = (Node *)lfirst(lc);
		Datum row_filter_d;
		Datum resqual;

		row_filter_d = CStringGetTextDatum(nodeToString(row_filter));
		resqual = DirectFunctionCall2(pg_get_expr, row_filter_d,
									  ObjectIdGetDatum(reloid));
		if (i > 0)
			appendStringInfo(&query, " OR ");

		appendStringInfo(&query, " %s",
						 text_to_cstring(DatumGetTextP(resqual)));
		i++;
		pfree(DatumGetTextP(resqual));
		pfree(DatumGetTextPP(row_filter_d));
	}

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPOCK: SPI_connect() failed");

	rc = SPI_execute(query.data, true, 0);
	if (rc != SPI_OK_SELECT)
		elog(ERROR, "SPOCK: SPI_execute() failed");

	for (i = 0; i < SPI_processed; i++)
	{
		HeapTuple tup = SPI_tuptable->vals[i];

		tuplestore_puttuple(tupstore, tup);
	}

	/* Cleanup. */
	ExecDropSingleTupleTableSlot(econtext->ecxt_scantuple);
	FreeExecutorState(estate);

	SPI_freetuptable(SPI_tuptable);
	SPI_finish();
	table_close(rel, NoLock);

	PG_RETURN_NULL();
}

/*
 * Wait for subscription and initial sync to complete, or, if relation info is
 * given, for sync to complete for a specific table.
 *
 * We have to play games with snapshots to achieve this, since we're looking at
 * spock tables in the future as far as our snapshot is concerned.
 */
static void
spock_wait_for_sync_complete(char *subscription_name, char *relnamespace, char *relname)
{
	SpockSubscription *sub;

	/*
	 * If we wait in SERIALIZABLE, then the next snapshot after we return
	 * won't reflect the new state.
	 */
	if (IsolationUsesXactSnapshot())
		elog(ERROR, "cannot wait for sync in REPEATABLE READ or SERIALIZABLE isolation");

	sub = get_subscription_by_name(subscription_name, false);

	do
	{
		SpockSyncStatus *subsync;
		List *tables;
		bool isdone = false;
		int rc;

		/* We need to see the latest rows */
		PushActiveSnapshot(GetLatestSnapshot());

		subsync = get_subscription_sync_status(sub->id, true);
		isdone = subsync && subsync->status == SYNC_STATUS_READY;
		free_sync_status(subsync);

		if (isdone)
		{
			/*
			 * Subscription itself is synced, but what about separately
			 * synced tables?
			 */
			if (relname != NULL)
			{
				SpockSyncStatus *table = get_table_sync_status(sub->id, relnamespace, relname, false);
				isdone = table && table->status == SYNC_STATUS_READY;
				free_sync_status(table);
			}
			else
			{
				/*
				 * XXX This is plenty inefficient and we should probably just do a direct catalog
				 * scan, but meh, it hardly has to be fast.
				 */
				ListCell *lc;
				tables = get_unsynced_tables(sub->id);
				isdone = tables == NIL;
				foreach (lc, tables)
				{
					SpockSyncStatus *table = lfirst(lc);
					free_sync_status(table);
				}
				list_free(tables);
			}
		}

		PopActiveSnapshot();

		if (isdone)
			break;

		CHECK_FOR_INTERRUPTS();

		/* some kind of backoff could be useful here */
		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH, 200L);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		ResetLatch(&MyProc->procLatch);
	} while (1);
}

Datum spock_wait_for_subscription_sync_complete(PG_FUNCTION_ARGS)
{
	char *subscription_name = NameStr(*PG_GETARG_NAME(0));

	spock_wait_for_sync_complete(subscription_name, NULL, NULL);

	PG_RETURN_VOID();
}

Datum spock_wait_for_table_sync_complete(PG_FUNCTION_ARGS)
{
	char *subscription_name = NameStr(*PG_GETARG_NAME(0));
	Oid relid = PG_GETARG_OID(1);
	char *relname, *relnamespace;

	relname = get_rel_name(relid);
	relnamespace = get_namespace_name(get_rel_namespace(relid));

	spock_wait_for_sync_complete(subscription_name, relnamespace, relname);

	PG_RETURN_VOID();
}

/*
 * Like pg_xact_commit_timestamp but extended for replorigin
 * too.
 */
Datum spock_xact_commit_timestamp_origin(PG_FUNCTION_ARGS)
{
#ifdef HAVE_REPLICATION_ORIGINS
	TransactionId xid = PG_GETARG_UINT32(0);
	TimestampTz ts;
	RepOriginId origin;
	bool found;
#endif
	TupleDesc tupdesc;
	Datum values[2];
	bool nulls[2] = {false, false};
	HeapTuple tup;

	/*
	 * Construct a tuple descriptor for the result row. Must match the
	 * function declaration.
	 */
	tupdesc = CreateTemplateTupleDesc(2);
	TupleDescInitEntry(tupdesc, (AttrNumber)1, "timestamp",
					   TIMESTAMPTZOID, -1, 0);
	TupleDescInitEntry(tupdesc, (AttrNumber)2, "roident",
					   OIDOID, -1, 0);
	tupdesc = BlessTupleDesc(tupdesc);

#ifdef HAVE_REPLICATION_ORIGINS
	found = TransactionIdGetCommitTsData(xid, &ts, &origin);

	if (found)
	{
		values[0] = TimestampTzGetDatum(ts);
		values[1] = ObjectIdGetDatum(origin);
	}
	else
#endif
	{
		values[0] = (Datum)0;
		nulls[0] = true;
		values[1] = (Datum)0;
		nulls[1] = true;
	}

	tup = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tup));
}

Datum spock_gen_slot_name(PG_FUNCTION_ARGS)
{
	char *dbname = NameStr(*PG_GETARG_NAME(0));
	char *provider_node_name = NameStr(*PG_GETARG_NAME(1));
	char *subscription_name = NameStr(*PG_GETARG_NAME(2));
	Name slot_name;

	slot_name = (Name)palloc0(NAMEDATALEN);

	gen_slot_name(slot_name, dbname, provider_node_name,
				  subscription_name);

	PG_RETURN_NAME(slot_name);
}

/*
 * Generate slot name (used also for origin identifier)
 *
 * The current format is:
 * spk_<subscriber database name>_<provider node name>_<subscription name>
 *
 * Note that we want to leave enough free space for 8 bytes of suffix
 * which in practice means 9 bytes including the underscore.
 */
static void
gen_slot_name(Name slot_name, char *dbname, const char *provider_node,
			  const char *subscription_name)
{
	char *cp;

	memset(NameStr(*slot_name), 0, NAMEDATALEN);
	snprintf(NameStr(*slot_name), NAMEDATALEN,
			 "spk_%s_%s_%s",
			 shorten_hash(dbname, 16),
			 shorten_hash(provider_node, 16),
			 shorten_hash(subscription_name, 16));
	NameStr(*slot_name)[NAMEDATALEN - 1] = '\0';

	/* Replace all the invalid characters in slot name with underscore. */
	for (cp = NameStr(*slot_name); *cp; cp++)
	{
		if (!((*cp >= 'a' && *cp <= 'z') || (*cp >= '0' && *cp <= '9') || (*cp == '_')))
		{
			*cp = '_';
		}
	}
}

Datum spock_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(SPOCK_VERSION));
}

Datum spock_version_num(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(SPOCK_VERSION_NUM);
}

Datum spock_max_proto_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(SPOCK_PROTO_VERSION_NUM);
}

Datum spock_min_proto_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(SPOCK_PROTO_MIN_VERSION_NUM);
}

/* Dummy functions for backward comptibility. */
Datum spock_truncate_trigger_add(PG_FUNCTION_ARGS)
{
	PG_RETURN_VOID();
}

PGDLLEXPORT extern Datum spock_hooks_setup(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(spock_hooks_setup);
Datum spock_hooks_setup(PG_FUNCTION_ARGS)
{
	PG_RETURN_VOID();
}

PGDLLEXPORT extern Datum get_channel_stats(PG_FUNCTION_ARGS);
Datum get_channel_stats(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *)fcinfo->resultinfo;
	TupleDesc tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;
	HASH_SEQ_STATUS hash_seq;
	spockStatsEntry *entry;
	Datum *values;
	bool *nulls;

	if (!SpockCtx || !SpockHash)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock must be loaded via shared_preload_libraries")));

	/* check to see if caller supports us returning a tuplestore */
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("materialize mode required, but it is not "
						"allowed in this context")));

	/* Switch into long-lived context to construct returned data structures */
	per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);

	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	hash_seq_init(&hash_seq, SpockHash);

	values = palloc0(sizeof(Datum) * (SPOCK_STATS_NUM_COUNTERS + 2));
	nulls = palloc0(sizeof(bool) * (SPOCK_STATS_NUM_COUNTERS + 2));

	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		int i = 0;
		int j;

		if (entry->key.dboid != MyDatabaseId)
			continue;

		memset(values, 0, sizeof(Datum) * (SPOCK_STATS_NUM_COUNTERS + 2));
		memset(nulls, 0, sizeof(bool) * (SPOCK_STATS_NUM_COUNTERS + 2));

		values[i++] = ObjectIdGetDatum(entry->key.subid);
		values[i++] = ObjectIdGetDatum(entry->key.relid);

		for (j = 0; j < SPOCK_STATS_NUM_COUNTERS; j++)
			values[i++] = Int64GetDatum(entry->counter[j]);

		tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	}

	spock_stats_hash_full = false;

	LWLockRelease(SpockCtx->lock);

	MemoryContextSwitchTo(oldcontext);

	return (Datum)0;
}

PGDLLEXPORT extern Datum reset_channel_stats(PG_FUNCTION_ARGS);
Datum reset_channel_stats(PG_FUNCTION_ARGS)
{
	HASH_SEQ_STATUS hash_seq;
	spockStatsEntry *entry;

	if (!SpockCtx || !SpockHash)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock must be loaded via shared_preload_libraries")));

	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);

	hash_seq_init(&hash_seq, SpockHash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		hash_search(SpockHash, &entry->key, HASH_REMOVE, NULL);
	}

	LWLockRelease(SpockCtx->lock);
	PG_RETURN_VOID();
}

/* Generic delta apply functions */
Datum delta_apply_int2(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(int2mi, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(int2pl, local_val, delta));
}

Datum delta_apply_int4(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(int4mi, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(int4pl, local_val, delta));
}

Datum delta_apply_int8(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(int8mi, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(int8pl, local_val, delta));
}

Datum delta_apply_float4(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(float4mi, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(float4pl, local_val, delta));
}

Datum delta_apply_float8(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(float8mi, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(float8pl, local_val, delta));
}

Datum delta_apply_numeric(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(numeric_sub, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(numeric_add, local_val, delta));
}

Datum delta_apply_money(PG_FUNCTION_ARGS)
{
	Datum old_value = PG_GETARG_DATUM(0);
	Datum new_value = PG_GETARG_DATUM(1);
	Datum local_val = PG_GETARG_DATUM(2);
	Datum delta;

	delta = DirectFunctionCall2(cash_mi, new_value, old_value);
	PG_RETURN_DATUM(DirectFunctionCall2(cash_pl, local_val, delta));
}

/*
 * Function to control REPAIR mode
 *
 * The Spock output plugin with suppress all DML messages after decoding
 * the SPOCK_REPAIR_MODE_ON message. Normal operation will resume after
 * receiving the SPOCK_REPAIR_MODE_OFF message or on transaction end.
 *
 * This is equivalent to session_replication_role=local.
 */
Datum
spock_repair_mode(PG_FUNCTION_ARGS)
{
	SpockWalMessageSimple	message;
	XLogRecPtr				lsn;
	bool					enabled = PG_GETARG_BOOL(0);

	message.mtype = (enabled) ? SPOCK_REPAIR_MODE_ON : SPOCK_REPAIR_MODE_OFF;
	lsn = LogLogicalMessage(SPOCK_MESSAGE_PREFIX, (char *)&message, sizeof(message), true);
	PG_RETURN_LSN(lsn);
}

/*
 * spock_create_sync_event
 *
 * This function creates a synchronization event on the provider. It leverages
 * the LogLogicalMessage API to log a custom message within the logical
 * replication framework. By doing so, it generates a unique Log Sequence Number
 * (LSN) that serves as a marker for synchronization purposes.
 *
 * The generated LSN is returned to the caller and can be used by the
 * spock_wait_for_sync_event procedure on the subscriber side. Subscribers can
 * block and wait for this LSN to arrive, ensuring that all changes up to and
 * including the event have been replicated.
 *
 * an LSN is returned to caller.
 */
Datum
spock_create_sync_event(PG_FUNCTION_ARGS)
{
	SpockLocalNode		   *node;
	SpockSyncEventMessage	message;
	XLogRecPtr				lsn;

	node = check_local_node(true);
	message.mtype = SPOCK_SYNC_EVENT_MSG;
	message.eorigin = node->node->id;
	memset(NameStr(message.ename), 0, NAMEDATALEN);

	lsn = LogLogicalMessage(SPOCK_MESSAGE_PREFIX, (char *)&message, sizeof(message), true);

	PG_RETURN_LSN(lsn);
}

/*
 * Helper function for finding the endptr for a particular commit timestamp
 */
static XLogRecPtr
spock_logical_replication_slot_scan(TimestampTz committs)
{
	LogicalDecodingContext *ctx;
	ResourceOwner old_resowner = CurrentResourceOwner;
	XLogRecPtr	retlsn;

	PG_TRY();
	{
		/*
		 * Create our decoding context in fast_forward mode, passing start_lsn
		 * as InvalidXLogRecPtr, so that we start processing from my slot's
		 * confirmed_flush.
		 */
		ctx = CreateDecodingContext(InvalidXLogRecPtr,
									NIL,
									true,	/* fast_forward */
									XL_ROUTINE(.page_read = read_local_xlog_page,
											   .segment_open = wal_segment_open,
											   .segment_close = wal_segment_close),
									NULL, NULL, NULL);

		/*
		 * Start reading at the slot's restart_lsn, which we know to point to
		 * a valid record.
		 */
		XLogBeginRead(ctx->reader, MyReplicationSlot->data.restart_lsn);
		retlsn = MyReplicationSlot->data.restart_lsn;

		/* invalidate non-timetravel entries */
		InvalidateSystemCaches();

		/* Decode at least one record, until we run out of records */
		while (true)
		{
			char	   *errm = NULL;
			XLogRecord *record;

			/*
			 * Read records.  No changes are generated in fast_forward mode,
			 * but snapbuilder/slot statuses are updated properly.
			 */
			record = XLogReadRecord(ctx->reader, &errm);
			if (errm)
				elog(ERROR, "could not find record while advancing replication slot: %s",
					 errm);

			if (record)
			{
				if (record->xl_rmid == RM_XACT_ID)
				{
					RepOriginId		nodeid;
					TimestampTz		ts;

					if (record->xl_xid == InvalidTransactionId)
						continue;

					TransactionIdGetCommitTsData(record->xl_xid,
												 &ts, &nodeid);

					if (nodeid == 0 && ts > committs)
						break;

					if (nodeid == 0)
						retlsn = ctx->reader->EndRecPtr;
				}
			}
			else
			{
				break;
			}

			CHECK_FOR_INTERRUPTS();
		}

		/*
		 * Logical decoding could have clobbered CurrentResourceOwner during
		 * transaction management, so restore the executor's value.  (This is
		 * a kluge, but it's not worth cleaning up right now.)
		 */
		CurrentResourceOwner = old_resowner;

		/* free context, call shutdown callback */
		FreeDecodingContext(ctx);

		InvalidateSystemCaches();
	}
	PG_CATCH();
	{
		/* clear all timetravel entries */
		InvalidateSystemCaches();

		PG_RE_THROW();
	}
	PG_END_TRY();

	return retlsn;
}

/*
 * SQL function for moving the position in a replication slot.
 */
Datum
spock_get_lsn_from_commit_ts(PG_FUNCTION_ARGS)
{
	Name		slotname = PG_GETARG_NAME(0);
	TimestampTz	targettz = PG_GETARG_TIMESTAMPTZ(1);
	XLogRecPtr	endlsn;

	Assert(!MyReplicationSlot);

	CheckSlotPermissions();

	/* Acquire the slot so we "own" it */
#if PG_VERSION_NUM >= 180000
	ReplicationSlotAcquire(NameStr(*slotname), true, true);
#else
	ReplicationSlotAcquire(NameStr(*slotname), true);
#endif

	/* A slot whose restart_lsn has never been reserved cannot be advanced */
	if (XLogRecPtrIsInvalid(MyReplicationSlot->data.restart_lsn))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("replication slot \"%s\" cannot be advanced",
						NameStr(*slotname)),
				 errdetail("This slot has never previously reserved WAL, or it has been invalidated.")));

	/* Do the actual slot scanning */
	if (OidIsValid(MyReplicationSlot->data.database))
		endlsn = spock_logical_replication_slot_scan(targettz);
	else
		elog(ERROR, "not a logical replication slot");

	ReplicationSlotRelease();

	PG_RETURN_LSN(endlsn);
}

PG_FUNCTION_INFO_V1(get_apply_worker_status);
/*
 * Show info about apply workers.
 */
Datum
get_apply_worker_status(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *)fcinfo->resultinfo;
    TupleDesc tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext per_query_ctx;
    MemoryContext oldcontext;

    /* Check if caller supports returning a tuplestore */
    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not allowed in this context")));

    /* Switch to long-lived context */
    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    /* Build tuple descriptor */
    tupdesc = CreateTemplateTupleDesc(4);
    TupleDescInitEntry(tupdesc, (AttrNumber)1, "worker_pid", INT8OID, -1, 0);
    TupleDescInitEntry(tupdesc, (AttrNumber)2, "worker_dboid", INT4OID, -1, 0);
    TupleDescInitEntry(tupdesc, (AttrNumber)3, "worker_subid", INT8OID, -1, 0);
    TupleDescInitEntry(tupdesc, (AttrNumber)4, "worker_status", TEXTOID, -1, 0);

    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tupstore;
    rsinfo->setDesc = tupdesc;

    MemoryContextSwitchTo(oldcontext);

    /* Fetch and emit worker rows */
    if (SpockCtx == NULL)
        ereport(ERROR, (errmsg("Spock context is not initialized")));

    LWLockAcquire(SpockCtx->lock, LW_SHARED);
    for (int i = 0; i < SpockCtx->total_workers; i++)
    {
        SpockWorker *worker = &SpockCtx->workers[i];

        if (worker->worker_type == SPOCK_WORKER_APPLY && worker->proc != NULL)
        {
            Datum values[4];
            bool nulls[4] = {false, false, false, false};
            const char *status_text;

            /* Map worker_status to text */
            switch (worker->worker_status)
            {
                case SPOCK_WORKER_STATUS_NONE:
                    status_text = "none";
                    break;
                case SPOCK_WORKER_STATUS_IDLE:
                    status_text = "idle";
                    break;
                case SPOCK_WORKER_STATUS_RUNNING:
                    status_text = "running";
                    break;
                case SPOCK_WORKER_STATUS_STOPPING:
                    status_text = "stopping";
                    break;
                case SPOCK_WORKER_STATUS_STOPPED:
                    status_text = "stopped";
                    break;
                case SPOCK_WORKER_STATUS_FAILED:
                    status_text = "failed";
                    break;
                default:
                    status_text = "unknown";
                    break;
            }

            values[0] = Int64GetDatum((int64)worker->proc->pid);
            values[1] = Int32GetDatum(worker->dboid);
            values[2] = Int64GetDatum((int64)worker->worker.apply.subid);
            values[3] = CStringGetTextDatum(status_text);

            tuplestore_putvalues(tupstore, tupdesc, values, nulls);
        }
    }
    LWLockRelease(SpockCtx->lock);

    PG_RETURN_VOID();
}

/*
 * Clone a recovery slot for rescue operations
 */
Datum
spock_clone_recovery_slot(PG_FUNCTION_ARGS)
{
    text       *source_slot_text = PG_GETARG_TEXT_PP(0);
    text       *target_lsn_text = PG_GETARG_TEXT_PP(1);
    char       *source_slot;
    char       *target_lsn_str;
    char       *clone_name;
    XLogRecPtr  target_lsn;
    uint32      high, low;

    source_slot = text_to_cstring(source_slot_text);
    target_lsn_str = text_to_cstring(target_lsn_text);

    /* Parse the LSN */
    if (sscanf(target_lsn_str, "%X/%X", &high, &low) != 2)
    {
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("invalid LSN format: %s", target_lsn_str)));
    }
    target_lsn = ((uint64)high << 32) | low;

    /* Clone the recovery slot */
    clone_name = clone_recovery_slot(source_slot, target_lsn);

    PG_RETURN_TEXT_P(cstring_to_text(clone_name));
}

/*
 * Get minimum unacknowledged timestamp for a failed node
 */
Datum
spock_get_min_unacknowledged_timestamp(PG_FUNCTION_ARGS)
{
    Oid         failed_node_id = PG_GETARG_OID(0);
    TimestampTz min_ts;

    min_ts = get_min_unacknowledged_timestamp(failed_node_id);

    if (min_ts == 0)
        PG_RETURN_NULL();

    PG_RETURN_TIMESTAMPTZ(min_ts);
}

/*
 * Initiate recovery process for a failed node
 */
Datum
spock_initiate_node_recovery(PG_FUNCTION_ARGS)
{
    Oid failed_node_id = PG_GETARG_OID(0);
    bool success;

    success = initiate_node_recovery(failed_node_id);

    PG_RETURN_BOOL(success);
}

/*
 * Get information about recovery slots
 */
Datum
spock_get_recovery_slot_info(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc   tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext per_query_ctx;
    MemoryContext oldcontext;
    int         i;

    /* Check to see if caller supports us returning a tuplestore */
    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not allowed in this context")));

    /* Build a tuple descriptor for our result type */
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning record called in context that cannot accept type record")));

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tupstore;
    rsinfo->setDesc = tupdesc;

    MemoryContextSwitchTo(oldcontext);

    /* Check if recovery context is initialized */
    if (!SpockRecoveryCtx)
    {
        /* Return empty set if not initialized */
        tuplestore_donestoring(tupstore);
        return (Datum) 0;
    }

    LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);

    for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
    {
        SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
        Datum       values[9];
        bool        nulls[9] = {false, false, false, false, false, false, false, false, false};

        if (slot->local_node_id == InvalidOid)
            continue;

        values[0] = ObjectIdGetDatum(slot->local_node_id);
        values[1] = ObjectIdGetDatum(slot->remote_node_id);
        values[2] = CStringGetTextDatum(slot->slot_name);
        values[3] = LSNGetDatum(slot->restart_lsn);
        values[4] = LSNGetDatum(slot->confirmed_flush_lsn);
        values[5] = TimestampTzGetDatum(slot->min_unacknowledged_ts);
        values[6] = BoolGetDatum(slot->active);
        values[7] = BoolGetDatum(slot->in_recovery);
        values[8] = UInt32GetDatum(pg_atomic_read_u32(&slot->recovery_generation));

        tuplestore_putvalues(tupstore, tupdesc, values, nulls);
    }

    LWLockRelease(SpockRecoveryCtx->lock);

    tuplestore_donestoring(tupstore);

    return (Datum) 0;
}

/*
 * Detect failed nodes by checking connectivity and heartbeat
 */
Datum
spock_detect_failed_nodes(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc   tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;
	/* TODO: Implement node failure detection logic */
	/* This would check connectivity, heartbeat, etc. */

	/* Build a tuple descriptor for our result type */
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("materialize mode required, but it is not allowed in this context")));

	/* Build tuple descriptor for (node_id oid, node_name text, failure_reason text) */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context that cannot accept type record")));

	per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);

	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);

	/* For now, return empty set - in full implementation this would detect failed nodes */
	tuplestore_donestoring(tupstore);

	return (Datum) 0;
}

/*
 * Coordinate cluster-wide recovery orchestration
 */
Datum
spock_coordinate_cluster_recovery(PG_FUNCTION_ARGS)
{
	Oid failed_node_id = PG_GETARG_OID(0);
	bool success = false;

	/* TODO: Implement cluster-wide recovery coordination */
	/* This would coordinate recovery across all surviving nodes */

	elog(LOG, "Coordinating cluster recovery for failed node %u", failed_node_id);

	/* For now, just initiate recovery on this node */
	success = initiate_node_recovery(failed_node_id);

	PG_RETURN_BOOL(success);
}

/*
 * Advance recovery slot to a specific LSN
 */
Datum
spock_advance_recovery_slot_to_lsn(PG_FUNCTION_ARGS)
{
	text	   *slot_name_text = PG_GETARG_TEXT_PP(0);
	text	   *target_lsn_text = PG_GETARG_TEXT_PP(1);
	char	   *slot_name;
	char	   *target_lsn_str;
	bool		success;
	uint32      high, low;
	TimestampTz approx_timestamp;

	slot_name = text_to_cstring(slot_name_text);
	target_lsn_str = text_to_cstring(target_lsn_text);

	/* Parse the LSN */
	if (sscanf(target_lsn_str, "%X/%X", &high, &low) != 2)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid LSN format: %s", target_lsn_str)));
	}

	/* Advance the slot to the target LSN */
	/* For now, we use a reasonable past timestamp for advancement */
	approx_timestamp = GetCurrentTimestamp() - 60000000; /* 1 minute ago in PostgreSQL timestamp units */
	success = advance_recovery_slot_to_timestamp(slot_name, approx_timestamp);

	/* Note: In a full implementation, we would use the actual LSN advancement */
	/* For now, we use timestamp-based advancement as a proxy */

	PG_RETURN_BOOL(success);
}
