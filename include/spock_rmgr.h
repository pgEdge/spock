#ifndef SPOCK_RMGR_H
#define SPOCK_RMGR_H

#include "access/xlog.h"
#include "access/xlog_internal.h"

/* Spock resouce manager */
#define SPOCK_RMGR_NAME             	    "spock_custom_rmgr"
#define SPOCK_RMGR_ID		    	        RM_EXPERIMENTAL_ID

/* Spock RMGR tags. */
#define SPOCK_RMGR_PROGRESS_INFO			0x10
#define SPOCK_RMGR_SUBTRANS_COMMIT_TS       0x20

typedef struct ProgressInfoEntry
{
	Oid         dbid;
	Oid         node_id;
    Oid         remote_node_id;
	TimestampTz remote_commit_ts;
    XLogRecPtr  remote_lsn;
    XLogRecPtr  remote_insert_lsn;
	TimestampTz last_updated_ts;
    bool        updated_by_decode;
} ProgressInfoEntry;

typedef struct SubTransactionCommitTsEntry
{
	TransactionId	xid;
	TimestampTz		time;
	RepOriginId		nodeid;
} SubTransactionCommitTsEntry;

extern void spock_rmgr_init(void);
extern void spock_rmgr_desc(StringInfo buf, XLogReaderState *record);
extern const char *spock_rmgr_identify(uint8 info);
extern void spock_rmgr_redo(XLogReaderState *record);
extern void spock_rmgr_startup(void);
extern void spock_rmgr_cleanup(void);


#endif /* SPOCK_RMGR_H */
