/*-------------------------------------------------------------------------
 *
 * spock_repset.h
 *		spock replication set manipulation functions
 *
 * Copyright (c) 2021-2022, OSCG Partners, LLC
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_REPSET_H
#define SPOCK_REPSET_H

#include "replication/reorderbuffer.h"

typedef struct SpockRepSet
{
	Oid			id;
	Oid			nodeid;
	char	   *name;
	bool		replicate_insert;
	bool		replicate_update;
	bool		replicate_delete;
	bool		replicate_truncate;
} SpockRepSet;

#define DEFAULT_REPSET_NAME "default"
#define DEFAULT_INSONLY_REPSET_NAME "default_insert_only"
#define DDL_SQL_REPSET_NAME "ddl_sql"

/* This is only valid within one output plugin instance/walsender. */
typedef struct SpockTableRepInfo
{
	Oid				reloid;				/* key */

	bool			isvalid;			/* is this entry valid? */

	bool			replicate_insert;	/* should insert be replicated? */
	bool			replicate_update;	/* should update be replicated? */
	bool			replicate_delete;	/* should delete be replicated? */

	Bitmapset	   *att_list;			/* column filter
										   NULL if everything is replicated
										   otherwise each replicated column
										   is a member */
	List		   *row_filter;			/* compiled row_filter nodes */
} SpockTableRepInfo;

/* forward declaration */
struct RepSetTableTuple;
typedef struct RepSetTableTuple RepSetTableTuple;

extern SpockRepSet *get_replication_set(Oid setid);
extern SpockRepSet *get_replication_set_by_name(Oid nodeid,
													const char *setname,
													bool missing_ok);

extern List *get_node_replication_sets(Oid nodeid);
extern List *get_replication_sets(Oid nodeid, List *replication_set_names,
								  bool missing_ok);

extern SpockTableRepInfo *get_table_replication_info(Oid nodeid,
						   Relation table, List *subs_replication_sets);
extern RepSetTableTuple *get_table_replication_row(Oid repsetid, Oid reloid,
							List **att_list, Node **row_filter);

extern void create_replication_set(SpockRepSet *repset);
extern void alter_replication_set(SpockRepSet *repset);
extern void drop_replication_set(Oid setid);
extern void drop_node_replication_sets(Oid nodeid);

extern void replication_set_add_table(Oid setid, Oid reloid,
						  List *att_list, Node *row_filter);
extern void replication_set_add_seq(Oid setid, Oid seqoid);
extern List *replication_set_get_tables(Oid setid);
extern List *replication_set_get_seqs(Oid setid);
extern PGDLLEXPORT void replication_set_remove_table(Oid setid, Oid reloid,
													 bool from_drop);
extern PGDLLEXPORT void replication_set_remove_seq(Oid setid, Oid reloid,
												   bool from_drop);

extern List *get_table_replication_sets(Oid nodeid, Oid reloid);
extern List *get_seq_replication_sets(Oid nodeid, Oid seqoid);

extern SpockRepSet *replication_set_from_tuple(HeapTuple tuple);

extern Oid get_replication_set_rel_oid(void);
extern Oid get_replication_set_table_rel_oid(void);
extern Oid get_replication_set_seq_rel_oid(void);

extern char *stringlist_to_identifierstr(List *strings);
extern char *repsetslist_to_identifierstr(List *repsets);
extern int get_att_num_by_name(TupleDesc desc, const char *attname);

#endif /* SPOCK_REPSET_H */
