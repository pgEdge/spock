/*-------------------------------------------------------------------------
 *
 * spock_node.h
 *		spock node and connection catalog manipulation functions
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_NODE_H
#define SPOCK_NODE_H

#include "datatype/timestamp.h"
#include "utils/jsonb.h"

typedef struct SpockNode
{
	Oid			id;
	char	   *name;
	char	   *location;
	char	   *country;
	Jsonb	   *info;
	/* Fields contained in the info jsonb */
	int32		tiebreaker;
} SpockNode;

typedef struct SpockInterface
{
	Oid				id;
	const char	   *name;
	Oid				nodeid;
	const char	   *dsn;
} SpockInterface;

typedef struct SpockLocalNode
{
	SpockNode	*node;
	SpockInterface *node_if;
} SpockLocalNode;

typedef struct SpockSubscription
{
	Oid			id;
	char	   *name;
	SpockNode	   *origin;
   	SpockNode	   *target;
	SpockInterface *origin_if;
	SpockInterface *target_if;
	bool		enabled;
	Interval   *apply_delay;
	char	   *slot_name;
	List	   *replication_sets;
	List	   *forward_origins;
	bool		force_text_transfer;
} SpockSubscription;

extern void create_node(SpockNode *node);
extern void drop_node(Oid nodeid);

extern SpockNode *get_node(Oid nodeid);
extern SpockNode *get_node_by_name(const char *name, bool missing_ok);

extern void create_node_interface(SpockInterface *node);
extern void drop_node_interface(Oid ifid);
extern void drop_node_interfaces(Oid nodeid);
extern SpockInterface *get_node_interface(Oid ifid);
extern SpockInterface *get_node_interface_by_name(Oid nodeid,
													  const char *name,
													  bool missing_ok);

extern void create_local_node(Oid nodeid, Oid ifid);
extern void drop_local_node(void);
extern SpockLocalNode *get_local_node(bool for_update, bool missing_ok);
extern bool is_local_node(void);

extern void create_subscription(SpockSubscription *sub);
extern void alter_subscription(SpockSubscription *sub);
extern void drop_subscription(Oid subid);

extern SpockSubscription *get_subscription(Oid subid);
extern SpockSubscription *get_subscription_by_name(const char *name,
													   bool missing_ok);
extern List *get_node_subscriptions(Oid nodeid, bool origin);

#endif /* SPOCK_NODE_H */
