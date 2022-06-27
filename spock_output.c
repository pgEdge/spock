/*-------------------------------------------------------------------------
 *
 * spock_output.c
 *		  Logical Replication output plugin which just loads and forwards
 *		  the call to the spock.
 *
 *		  This exists for backwards compatibility.
 *
 * Copyright (c) 2012-2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		  spock_output.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "replication/logical.h"

PG_MODULE_MAGIC;

extern void		_PG_output_plugin_init(OutputPluginCallbacks *cb);

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
