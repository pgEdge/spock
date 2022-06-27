/*-------------------------------------------------------------------------
 *
 * spock_executor.h
 *              spock replication plugin
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *              spock_executor.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_EXECUTOR_H
#define SPOCK_EXECUTOR_H

#include "executor/executor.h"

extern List *spock_truncated_tables;

extern EState *create_estate_for_relation(Relation rel, bool forwrite);
extern ExprContext *prepare_per_tuple_econtext(EState *estate, TupleDesc tupdesc);
extern ExprState *spock_prepare_row_filter(Node *row_filter);

extern void spock_executor_init(void);

#endif /* SPOCK_EXECUTOR_H */
