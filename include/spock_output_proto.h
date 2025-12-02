/*-------------------------------------------------------------------------
 *
 * spock_output_proto.h
 *		spock protocol
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_OUTPUT_PROTO_H
#define SPOCK_OUTPUT_PROTO_H

#include "lib/stringinfo.h"
#include "replication/reorderbuffer.h"
#include "utils/relcache.h"

#include "spock_output_plugin.h"

/*
 * Protocol capabilities
 *
 * SPOCK_PROTO_VERSION_NUM is our native protocol and the greatest version
 * we can support. SPOCK_PROTO_MIN_VERSION_NUM is the oldest version we
 * have backwards compatibility for. We negotiate protocol versions during the
 * startup handshake. See the protocol documentation for details.
 */
#define SPOCK_PROTO_VERSION_NUM 4
#define SPOCK_PROTO_MIN_VERSION_NUM 3

/*
 * The startup parameter format is versioned separately to the rest of the wire
 * protocol because we negotiate the wire protocol version using the startup
 * parameters sent to us. It hopefully won't ever need to change, but this
 * field is present in case we do need to change it, e.g. to a structured json
 * object. We can look at the startup params version to see whether we can
 * understand the startup params sent by the client and to fall back to
 * reading an older format if needed.
 */
#define SPOCK_STARTUP_PARAM_FORMAT_FLAT 1

/*
 * For similar reasons to the startup params
 * (SPOCK_STARTUP_PARAM_FORMAT_FLAT) the startup reply message format is
 * versioned separately to the rest of the protocol. The client has to be able
 * to read it to find out what protocol version was selected by the upstream
 * when using the native protocol.
 */
#define SPOCK_STARTUP_MSG_FORMAT_FLAT 1

#define TRUNCATE_CASCADE		(1<<0)
#define TRUNCATE_RESTART_SEQS	(1<<1)

#endif /* SPOCK_OUTPUT_PROTO_H */
