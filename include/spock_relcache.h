/*-------------------------------------------------------------------------
 *
 * spock_relcache.h
 *		spock relation cache
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_RELCACHE_H
#define SPOCK_RELCACHE_H

#include "storage/lock.h"

typedef struct SpockRemoteRel
{
	uint32		relid;
	char	   *nspname;
	char	   *relname;
	int			natts;
	char	  **attnames;

	/* Only returned by info function, not protocol. */
	bool		hasRowFilter;
	char		relkind;
	bool		ispartition;
} SpockRemoteRel;

typedef struct SpockRelation
{
	/* Info coming from the remote side. */
	uint32		remoteid;
	char	   *nspname;		/* Schema name */
	char	   *relname;		/* Table name */
	int			natts;
	char	  **attnames;
	Oid		   *attrtypes;
	Oid		   *attrtypmods;

	/* Mapping to local relation, filled as needed. */
	Oid			reloid;
	Oid			idxoid;
	Relation	rel;
	int		   *attmap;
	bool		has_delta_columns;
	Oid		   *delta_apply_functions;

	/* Additional cache, only valid as long as relation mapping is. */
	bool		hasTriggers;

	Oid		   *delta_functions;
	bool		has_delta_apply;
} SpockRelation;

extern void spock_relation_cache_update(uint32 remoteid,
										char *schemaname, char *relname,
										int natts, char **attnames,
										Oid *attrtypes,
										Oid *attrtypmods);
extern void spock_relation_cache_updater(SpockRemoteRel *remoterel);

extern SpockRelation *spock_relation_open(uint32 remoteid,
										  LOCKMODE lockmode);
extern void spock_relation_close(SpockRelation *rel,
								 LOCKMODE lockmode);
extern void spock_relation_invalidate_cb(Datum arg, Oid reloid);

extern void spock_relation_cache_reset(void);

extern Oid	spock_lookup_delta_function(char *fname, Oid typeoid);

struct SpockTupleData;

#endif							/* SPOCK_RELCACHE_H */
