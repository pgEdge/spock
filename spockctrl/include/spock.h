#ifndef SPOCK_H
#define SPOCK_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libpq-fe.h>
#include <getopt.h>
#include "dbconn.h"
#include "conf.h"
#include "logger.h"

extern Config config;

int call_wait_for_sync_event(PGconn *conn, const char *origin_type, const char *origin, const char *lsn, int timeout);
int handle_spock_wait_for_sync_event_command(int argc, char *argv[]);
int handle_spock_sync_event_command(int argc, char *argv[]);

#endif // SPOCK_H
