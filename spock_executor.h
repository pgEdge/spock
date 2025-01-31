/*-------------------------------------------------------------------------
 *
 * spock_executor.h
 *              spock replication plugin
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_EXECUTOR_H
#define SPOCK_EXECUTOR_H

#include "executor/executor.h"
#if PG_VERSION_NUM < 160000
#include "utils/queryjumble.h"
#else
#include "nodes/queryjumble.h"
#endif
#include "parser/parse_node.h"


extern EState *create_estate_for_relation(Relation rel, bool forwrite);
extern ExprContext *prepare_per_tuple_econtext(EState *estate, TupleDesc tupdesc);
extern ExprState *spock_prepare_row_filter(Node *row_filter);
extern void spock_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate);
extern void spock_ExecutorStart(QueryDesc *queryDesc, int eflags);

extern void spock_executor_init(void);

#endif /* SPOCK_EXECUTOR_H */
