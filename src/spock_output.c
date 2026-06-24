/*-------------------------------------------------------------------------
 *
 * spock_output.c
 *		  Logical Replication output plugin which just loads and forwards
 *		  the call to the spock.
 *
 *		  This exists for backwards compatibility.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "replication/logical.h"

#include "spock.h"

#if PG_VERSION_NUM >= 180000
PG_MODULE_MAGIC_EXT(
					.name = "spock_output",
					.version = SPOCK_VERSION
);
#else
PG_MODULE_MAGIC;
#endif

extern void _PG_output_plugin_init(OutputPluginCallbacks *cb);

void
_PG_output_plugin_init(OutputPluginCallbacks *cb)
{
	LogicalOutputPluginInit plugin_init;

	AssertVariableIsOfType(&_PG_output_plugin_init, LogicalOutputPluginInit);

	plugin_init = (LogicalOutputPluginInit)
		load_external_function("spock", "_PG_output_plugin_init", false, NULL);

	if (plugin_init == NULL)
		elog(ERROR, "could not load spock output plugin");

	plugin_init(cb);
}
