/*-------------------------------------------------------------------------
 *
 * spock_dependency.h
 *				Dependency handling
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *				spock_dependency.h
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
