/*-------------------------------------------------------------------------
 *
 * spock_output_config.h
 *              spock output config helper functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_OUTPUT_CONFIG_H
#define SPOCK_OUTPUT_CONFIG_H

#include "nodes/pg_list.h"
#include "spock_output_plugin.h"

inline static bool
server_float4_byval(void)
{
#ifdef USE_FLOAT4_BYVAL
	return true;
#else
	return false;
#endif
}

inline static bool
server_float8_byval(void)
{
#ifdef USE_FLOAT8_BYVAL
	return true;
#else
	return false;
#endif
}

inline static bool
server_integer_datetimes(void)
{
#ifdef USE_INTEGER_DATETIMES
	return true;
#else
	return false;
#endif
}

inline static bool
server_bigendian(void)
{
#ifdef WORDS_BIGENDIAN
	return true;
#else
	return false;
#endif
}

extern int process_parameters(List *options, SpockOutputData *data);

extern List *prepare_startup_message(SpockOutputData *data);

#endif
