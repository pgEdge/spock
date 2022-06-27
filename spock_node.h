/*-------------------------------------------------------------------------
 *
 * spock_node.h
 *		spock node and connection catalog manipulation functions
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		spock_node.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_NODE_H
#define SPOCK_NODE_H

#include "datatype/timestamp.h"

typedef struct SpockNode
{
	Oid			id;
	char	   *name;
} SpockNode;

typedef struct PGlogicalInterface
{
	Oid				id;
	const char	   *name;
	Oid				nodeid;
	const char	   *dsn;
} PGlogicalInterface;

typedef struct SpockLocalNode
{
	SpockNode	*node;
	PGlogicalInterface *node_if;
} SpockLocalNode;

typedef struct SpockSubscription
{
	Oid			id;
	char	   *name;
	SpockNode	   *origin;
   	SpockNode	   *target;
	PGlogicalInterface *origin_if;
	PGlogicalInterface *target_if;
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

extern void create_node_interface(PGlogicalInterface *node);
extern void drop_node_interface(Oid ifid);
extern void drop_node_interfaces(Oid nodeid);
extern PGlogicalInterface *get_node_interface(Oid ifid);
extern PGlogicalInterface *get_node_interface_by_name(Oid nodeid,
													  const char *name,
													  bool missing_ok);

extern void create_local_node(Oid nodeid, Oid ifid);
extern void drop_local_node(void);
extern SpockLocalNode *get_local_node(bool for_update, bool missing_ok);

extern void create_subscription(SpockSubscription *sub);
extern void alter_subscription(SpockSubscription *sub);
extern void drop_subscription(Oid subid);

extern SpockSubscription *get_subscription(Oid subid);
extern SpockSubscription *get_subscription_by_name(const char *name,
													   bool missing_ok);
extern List *get_node_subscriptions(Oid nodeid, bool origin);

#endif /* SPOCK_NODE_H */
