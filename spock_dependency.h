/*-------------------------------------------------------------------------
 *
 * spock_dependency.h
 *				Dependency handling
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_DEPENDENCY_H
#define SPOCK_DEPENDENCY_H

extern void spock_recordDependencyOn(const ObjectAddress *depender,
				   const ObjectAddress *referenced,
				   DependencyType behavior);

extern void spock_recordMultipleDependencies(const ObjectAddress *depender,
						   const ObjectAddress *referenced,
						   int nreferenced,
						   DependencyType behavior);

extern void spock_recordDependencyOnSingleRelExpr(const ObjectAddress *depender,
								Node *expr, Oid relId,
								DependencyType behavior,
								DependencyType self_behavior);

extern void spock_tryDropDependencies(const ObjectAddress *object,
										  DropBehavior behavior);

extern void spock_checkDependency(const ObjectAddress *object,
									  DropBehavior behavior);

#endif /* SPOCK_DEPENDENCY_H */
