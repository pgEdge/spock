#include "postgres.h"

#include "miscadmin.h"

#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_conflict.h"
#include "spock_relcache.h"


/*
 * SpockReadonlyMode --- controls write restrictions on the node.
 *
 * READONLY_OFF		No restrictions; all users may write.
 * READONLY_LOCAL	Non-superuser local sessions are read-only; replicated
 *					writes from apply workers are still permitted.
 *					(GUC values "local" and the legacy alias "user".)
 * READONLY_ALL		The node is fully read-only: both local sessions and
 *					apply workers are blocked from writing.
 *
 * The values are ordered so that (spock_readonly >= READONLY_LOCAL) is a
 * convenient test for "any read-only mode is active".
 */
typedef enum SpockReadonlyMode
{
	READONLY_OFF,
	READONLY_LOCAL,
	READONLY_ALL
} SpockReadonlyMode;

extern int	spock_readonly;
