#include "postgres.h"

#include "miscadmin.h"

#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_conflict.h"
#include "spock_relcache.h"


typedef enum SpockReadonlyMode
{
	READONLY_OFF,
	READONLY_USER,
	READONLY_ALL
} SpockReadonlyMode;

extern int	spock_readonly;
