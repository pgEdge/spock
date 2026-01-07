/*-------------------------------------------------------------------------
 *
 * spock_proto_native.c
 * 		spock binary protocol functions
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/sysattr.h"
#include "access/detoast.h"
#include "catalog/pg_type.h"
#include "libpq/pqformat.h"
#include "nodes/parsenodes.h"
#include "replication/origin.h"
#include "replication/reorderbuffer.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/syscache.h"

#include "spock_worker.h"
#include "spock_output_plugin.h"
#include "spock_output_proto.h"
#include "spock_proto_native.h"

#define IS_REPLICA_IDENTITY 1

/*
 * Static variables to track negotiated protocol versions
 *
 * spock_negotiated_proto_version: Used by the publisher to track the
 * negotiated protocol version. Set during protocol negotiation.
 *
 * spock_apply_proto_version: Used by the subscriber to track the protocol
 * version received from the publisher via the startup message.
 * Defaults to SPOCK_PROTO_MIN_VERSION_NUM for backward compatibility with
 * older publishers (< 5.0.5) that don't send proto_version in startup message.
 */
static uint32 spock_negotiated_proto_version = SPOCK_PROTO_VERSION_NUM;
static uint32 spock_apply_proto_version = SPOCK_PROTO_MIN_VERSION_NUM;

/*
 * Protocol version management functions for publisher
 */
void
spock_set_proto_version(uint32 version)
{
	spock_negotiated_proto_version = version;
}

uint32
spock_get_proto_version(void)
{
	return spock_negotiated_proto_version;
}

/*
 * Protocol version management functions for subscriber
 */
void
spock_apply_set_proto_version(uint32 version)
{
	spock_apply_proto_version = version;
}

uint32
spock_apply_get_proto_version(void)
{
	return spock_apply_proto_version;
}

static void spock_write_attrs(StringInfo out, Relation rel,
							  Bitmapset *att_list);
static void spock_write_tuple(StringInfo out, SpockOutputData *data,
							  Relation rel, HeapTuple tuple,
							  Bitmapset *att_list);
static char decide_datum_transfer(Form_pg_attribute att,
								  Form_pg_type typclass,
								  bool allow_internal_basetypes,
								  bool allow_binary_basetypes);

static void spock_read_attrs(StringInfo in, char ***attrnames,
							 Oid **attrtypes,
							 Oid **attrtypmods,
							 int *nattrnames);
static void spock_read_tuple(StringInfo in, SpockRelation *rel,
							 SpockTupleData *tuple);

/*
 * Write functions
 */

/*
 * Write relation description to the output stream.
 */
void
spock_write_rel(StringInfo out, SpockOutputData *data, Relation rel,
				Bitmapset *att_list)
{
	char	   *nspname;
	uint8		nspnamelen;
	const char *relname;
	uint8		relnamelen;
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'R');		/* sending RELATION */

	/* send the flags field */
	pq_sendbyte(out, flags);

	/* use Oid as relation identifier */
	pq_sendint(out, RelationGetRelid(rel), 4);

	nspname = get_namespace_name(rel->rd_rel->relnamespace);
	if (nspname == NULL)
		elog(ERROR, "cache lookup failed for namespace %u",
			 rel->rd_rel->relnamespace);
	nspnamelen = strlen(nspname) + 1;

	relname = NameStr(rel->rd_rel->relname);
	relnamelen = strlen(relname) + 1;

	pq_sendbyte(out, nspnamelen);	/* schema name length */
	pq_sendbytes(out, nspname, nspnamelen);

	pq_sendbyte(out, relnamelen);	/* table name length */
	pq_sendbytes(out, relname, relnamelen);

	/* send the attribute info */
	spock_write_attrs(out, rel, att_list);

	pfree(nspname);
}

/*
 * Write relation attributes to the outputstream.
 */
static void
spock_write_attrs(StringInfo out, Relation rel, Bitmapset *att_list)
{
	TupleDesc	desc;
	int			i;
	uint16		nliveatts = 0;
	Bitmapset  *idattrs;

	desc = RelationGetDescr(rel);

	pq_sendbyte(out, 'A');		/* sending ATTRS */

	/* send number of live attributes */
	for (i = 0; i < desc->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(desc, i);

		if (att->attisdropped || att->attgenerated)
			continue;
		if (att_list &&
			!bms_is_member(att->attnum - FirstLowInvalidHeapAttributeNumber,
						   att_list))
			continue;
		nliveatts++;
	}
	pq_sendint(out, nliveatts, 2);

	/* fetch bitmap of REPLICATION IDENTITY attributes */
	idattrs = RelationGetIndexAttrBitmap(rel, INDEX_ATTR_BITMAP_IDENTITY_KEY);

	/* send the attributes */
	for (i = 0; i < desc->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(desc, i);
		uint8		flags = 0;
		uint16		len;
		const char *attname;

		if (att->attisdropped || att->attgenerated)
			continue;
		if (att_list &&
			!bms_is_member(att->attnum - FirstLowInvalidHeapAttributeNumber,
						   att_list))
			continue;

		if (bms_is_member(att->attnum - FirstLowInvalidHeapAttributeNumber,
						  idattrs))
			flags |= IS_REPLICA_IDENTITY;

		pq_sendbyte(out, 'C');	/* column definition follows */
		pq_sendbyte(out, flags);

		pq_sendbyte(out, 'N');	/* column name block follows */
		attname = NameStr(att->attname);
		len = strlen(attname) + 1;
		pq_sendint(out, len, 2);
		pq_sendbytes(out, attname, len);	/* data */
		pq_sendint32(out, att->atttypid);	/* atttype */
		pq_sendint32(out, att->atttypmod);	/* atttypmod */
	}

	bms_free(idattrs);
}

/*
 * Write BEGIN to the output stream.
 */
void
spock_write_begin(StringInfo out, SpockOutputData *data,
				  ReorderBufferTXN *txn)
{
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'B');		/* BEGIN */

	/* send the flags field its self */
	pq_sendbyte(out, flags);

	/* fixed fields */
	pq_sendint64(out, txn->final_lsn);
	pq_sendint64(out, txn->xact_time.commit_time);
	pq_sendint(out, txn->xid, 4);
}

/*
 * Write COMMIT to the output stream.
 */
void
spock_write_commit(StringInfo out, SpockOutputData *data,
				   ReorderBufferTXN *txn, XLogRecPtr commit_lsn)
{
	uint8		flags = 0;
	XLogRecPtr	remote_insert_lsn = GetXLogWriteRecPtr();

	/*
	 * Protocol version 5+ includes remote_insert_lsn at the beginning of all
	 * messages. Protocol version 4 includes it at the end of COMMIT messages
	 * only.
	 */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, remote_insert_lsn);

	pq_sendbyte(out, 'C');		/* sending COMMIT */

	/* send the flags field */
	pq_sendbyte(out, flags);

	/* send fixed fields */
	pq_sendint64(out, commit_lsn);
	pq_sendint64(out, txn->end_lsn);
	pq_sendint64(out, txn->xact_time.commit_time);

	/* Protocol version 4 includes remote_insert_lsn at the end */
	if (spock_get_proto_version() == 4)
		pq_sendint64(out, remote_insert_lsn);
}

/*
 * Write ORIGIN to the output stream.
 */
void
spock_write_origin(StringInfo out, const RepOriginId origin_id,
				   XLogRecPtr origin_lsn)
{
	uint8		flags = 0;

	Assert(origin_id != InvalidRepOriginId);

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'O');		/* ORIGIN */

	/* send the flags field its self */
	pq_sendbyte(out, flags);

	/* send fields */
	pq_sendint64(out, origin_lsn);
	pq_sendint(out, origin_id, sizeof(RepOriginId));
}

/*
 * Write last commit ts for last process committed transaction
 * for the slot group.
 */
void
spock_write_commit_order(StringInfo out,
						 TimestampTz last_commit_ts)
{
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'L');		/* last commit ts */

	/* send the flags field its self */
	pq_sendbyte(out, flags);

	/* send timestamp */
	pq_sendint64(out, last_commit_ts);
}

/*
 * Write INSERT to the output stream.
 */
void
spock_write_insert(StringInfo out, SpockOutputData *data,
				   Relation rel, HeapTuple newtuple,
				   Bitmapset *att_list)
{
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'I');		/* action INSERT */

	/* send the flags field */
	pq_sendbyte(out, flags);

	/* use Oid as relation identifier */
	pq_sendint(out, RelationGetRelid(rel), 4);

	pq_sendbyte(out, 'N');		/* new tuple follows */
	spock_write_tuple(out, data, rel, newtuple, att_list);
}

/*
 * Write UPDATE to the output stream.
 */
void
spock_write_update(StringInfo out, SpockOutputData *data,
				   Relation rel, HeapTuple oldtuple, HeapTuple newtuple,
				   Bitmapset *att_list)
{
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'U');		/* action UPDATE */

	/* send the flags field */
	pq_sendbyte(out, flags);

	/* use Oid as relation identifier */
	pq_sendint(out, RelationGetRelid(rel), 4);

	/*
	 * TODO: support whole tuple (O tuple type)
	 *
	 * Right now we can only write the key-part since logical decoding doesn't
	 * know how to record the whole old tuple for us in WAL. We can't use
	 * REPLICA IDENTITY FULL for this, since that makes the key-part the whole
	 * tuple, causing issues with conflict resultion and index lookups. We
	 * need a separate decoding option to record whole tuples.
	 */
	if (oldtuple != NULL)
	{
		pq_sendbyte(out, 'K');	/* old key follows */
		spock_write_tuple(out, data, rel, oldtuple, att_list);
	}

	pq_sendbyte(out, 'N');		/* new tuple follows */
	spock_write_tuple(out, data, rel, newtuple, att_list);
}

/*
 * Write DELETE to the output stream.
 */
void
spock_write_delete(StringInfo out, SpockOutputData *data,
				   Relation rel, HeapTuple oldtuple,
				   Bitmapset *att_list)
{
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'D');		/* action DELETE */

	/* send the flags field */
	pq_sendbyte(out, flags);

	/* use Oid as relation identifier */
	pq_sendint(out, RelationGetRelid(rel), 4);

	/*
	 * TODO support whole tuple ('O' tuple type)
	 *
	 * See notes on update for details
	 */
	pq_sendbyte(out, 'K');		/* old key follows */
	spock_write_tuple(out, data, rel, oldtuple, att_list);
}

/*
 * Most of the brains for startup message creation lives in
 * spock_config.c, so this presently just sends the set of key/value pairs.
 *
 * NOTE: The startup message NEVER includes remote_insert_lsn, even for
 * protocol 5+. This is because the startup message is the mechanism by which
 * the subscriber learns the negotiated protocol version. The subscriber cannot
 * know to read remote_insert_lsn before it processes the startup message.
 */
void
write_startup_message(StringInfo out, List *msg)
{
	ListCell   *lc;

	/* Startup message never includes remote_insert_lsn - see comment above */

	pq_sendbyte(out, 'S');		/* message type field */
	pq_sendbyte(out, SPOCK_STARTUP_MSG_FORMAT_FLAT);	/* startup message
														 * version */
	foreach(lc, msg)
	{
		DefElem    *param = (DefElem *) lfirst(lc);

		Assert(IsA(param->arg, String) && strVal(param->arg) != NULL);
		/* null-terminated key and value pairs, in client_encoding */
		pq_sendstring(out, param->defname);
		pq_sendstring(out, strVal(param->arg));
	}
}

/*
 * Write a tuple to the outputstream, in the most efficient format possible.
 */
static void
spock_write_tuple(StringInfo out, SpockOutputData *data,
				  Relation rel, HeapTuple tuple, Bitmapset *att_list)
{
	TupleDesc	desc;
	Datum		values[MaxTupleAttributeNumber];
	bool		isnull[MaxTupleAttributeNumber];
	int			i;
	uint16		nliveatts = 0;

	desc = RelationGetDescr(rel);

	pq_sendbyte(out, 'T');		/* sending TUPLE */

	for (i = 0; i < desc->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(desc, i);

		if (att->attisdropped || att->attgenerated)
			continue;
		if (att_list &&
			!bms_is_member(att->attnum - FirstLowInvalidHeapAttributeNumber,
						   att_list))
			continue;
		nliveatts++;
	}
	pq_sendint(out, nliveatts, 2);

	/* try to allocate enough memory from the get go */
	enlargeStringInfo(out, tuple->t_len +
					  nliveatts * (1 + 4));

	/*
	 * XXX: should this prove to be a relevant bottleneck, it might be
	 * interesting to inline heap_deform_tuple() here, we don't actually need
	 * the information in the form we get from it.
	 */
	heap_deform_tuple(tuple, desc, values, isnull);

	for (i = 0; i < desc->natts; i++)
	{
		HeapTuple	typtup;
		Form_pg_type typclass;
		Form_pg_attribute att = TupleDescAttr(desc, i);
		char		transfer_type;

		/* skip dropped columns */
		if (att->attisdropped || att->attgenerated)
			continue;
		if (att_list &&
			!bms_is_member(att->attnum - FirstLowInvalidHeapAttributeNumber,
						   att_list))
			continue;

		if (isnull[i])
		{
			pq_sendbyte(out, 'n');	/* null column */
			continue;
		}
		else if (att->attlen == -1 && VARATT_IS_EXTERNAL_ONDISK(values[i]))
		{
			pq_sendbyte(out, 'u');	/* unchanged toast column */
			continue;
		}

		typtup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(att->atttypid));
		if (!HeapTupleIsValid(typtup))
			elog(ERROR, "cache lookup failed for type %u", att->atttypid);
		typclass = (Form_pg_type) GETSTRUCT(typtup);

		transfer_type = decide_datum_transfer(att, typclass,
											  data->allow_internal_basetypes,
											  data->allow_binary_basetypes);

		switch (transfer_type)
		{
			case 'i':
				pq_sendbyte(out, 'i');	/* internal-format binary data follows */

				/* pass by value */
				if (att->attbyval)
				{
					pq_sendint(out, att->attlen, 4);	/* length */

					enlargeStringInfo(out, att->attlen);
					store_att_byval(out->data + out->len, values[i],
									att->attlen);
					out->len += att->attlen;
					out->data[out->len] = '\0';
				}
				/* fixed length non-varlena pass-by-reference type */
				else if (att->attlen > 0)
				{
					pq_sendint(out, att->attlen, 4);	/* length */

					appendBinaryStringInfo(out, DatumGetPointer(values[i]),
										   att->attlen);
				}
				/* varlena type */
				else if (att->attlen == -1)
				{
					char	   *data = DatumGetPointer(values[i]);

					/* send indirect datums inline */
					if (VARATT_IS_EXTERNAL_INDIRECT(values[i]))
					{
						struct varatt_indirect redirect;

						VARATT_EXTERNAL_GET_POINTER(redirect, data);
						data = (char *) redirect.pointer;
					}

					Assert(!VARATT_IS_EXTERNAL(data));

					pq_sendint(out, VARSIZE_ANY(data), 4);	/* length */

					appendBinaryStringInfo(out, data, VARSIZE_ANY(data));
				}
				else
					elog(ERROR, "unsupported tuple type");

				break;

			case 'b':
				{
					bytea	   *outputbytes;
					int			len;

					pq_sendbyte(out, 'b');	/* binary send/recv data follows */

					outputbytes = OidSendFunctionCall(typclass->typsend,
													  values[i]);

					len = VARSIZE(outputbytes) - VARHDRSZ;
					pq_sendint(out, len, 4);	/* length */
					pq_sendbytes(out, VARDATA(outputbytes), len);	/* data */
					pfree(outputbytes);
				}
				break;

			default:
				{
					char	   *outputstr;
					int			len;

					pq_sendbyte(out, 't');	/* 'text' data follows */

					outputstr = OidOutputFunctionCall(typclass->typoutput,
													  values[i]);
					len = strlen(outputstr) + 1;
					pq_sendint(out, len, 4);	/* length */
					appendBinaryStringInfo(out, outputstr, len);	/* data */
					pfree(outputstr);
				}
		}

		ReleaseSysCache(typtup);
	}
}

void
spock_write_message(StringInfo out, TransactionId xid, XLogRecPtr lsn,
					bool transactional, const char *prefix, Size sz,
					const char *message)
{
	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'M');		/* message type field */

	/* send out message contents */
	pq_sendint32(out, xid);
	pq_sendint64(out, lsn);

	pq_sendbyte(out, transactional);
	pq_sendstring(out, prefix);
	pq_sendint32(out, sz);
	pq_sendbytes(out, message, sz);
}

/*
 * Make the executive decision about which protocol to use.
 */
static char
decide_datum_transfer(Form_pg_attribute att, Form_pg_type typclass,
					  bool allow_internal_basetypes,
					  bool allow_binary_basetypes)
{
	/*
	 * Use the binary protocol, if allowed, for builtin & plain datatypes.
	 */
	if (allow_internal_basetypes &&
		typclass->typtype == 'b' &&
		att->atttypid < FirstNormalObjectId &&
		typclass->typelem == InvalidOid)
	{
		return 'i';
	}

	/*
	 * Use send/recv, if allowed, if the type is plain or builtin.
	 *
	 * XXX: we can't use send/recv for array or composite types for now due to
	 * the embedded oids.
	 */
	else if (allow_binary_basetypes &&
			 OidIsValid(typclass->typreceive) &&
			 (att->atttypid < FirstNormalObjectId || typclass->typtype != 'c') &&
			 (att->atttypid < FirstNormalObjectId || typclass->typelem == InvalidOid))
	{
		return 'b';
	}

	return 't';
}


/*
 * Read functions.
 */

/*
 * Read transaction BEGIN from the stream.
 */
void
spock_read_begin(StringInfo in, XLogRecPtr *remote_lsn,
				 TimestampTz *committime,
				 TransactionId *remote_xid)
{
	/* read flags */
	uint8		flags = pq_getmsgbyte(in);

	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read fields */
	*remote_lsn = pq_getmsgint64(in);
	Assert(*remote_lsn != InvalidXLogRecPtr);
	*committime = pq_getmsgint64(in);
	*remote_xid = pq_getmsgint(in, 4);
}

/*
 * Read transaction COMMIT from the stream.
 *
 * For protocol version 4, remote_insert_lsn is read from the end of the COMMIT
 * message and returned to the caller. For protocol version 5+, remote_insert_lsn
 * is sent at the beginning of all messages (handled in apply_work), so this
 * function sets *remote_insert_lsn to InvalidXLogRecPtr.
 *
 * Callers must check if *remote_insert_lsn != InvalidXLogRecPtr before using it.
 */
void
spock_read_commit(StringInfo in,
				  XLogRecPtr *commit_lsn,
				  XLogRecPtr *end_lsn,
				  TimestampTz *committime,
				  XLogRecPtr *remote_insert_lsn)
{
	/* read flags */
	uint8		flags = pq_getmsgbyte(in);

	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read fields */
	*commit_lsn = pq_getmsgint64(in);
	*end_lsn = pq_getmsgint64(in);
	*committime = pq_getmsgint64(in);

	/*
	 * Protocol version 4 includes remote_insert_lsn at the end of COMMIT
	 * messages. Protocol version 5+ includes it at the beginning of ALL
	 * messages (handled in apply_work).
	 */
	if (spock_apply_get_proto_version() == 4)
		*remote_insert_lsn = pq_getmsgint64(in);
	else
		*remote_insert_lsn = InvalidXLogRecPtr;
}

/*
 * Read ORIGIN from the output stream.
 */
RepOriginId
spock_read_origin(StringInfo in, XLogRecPtr *origin_lsn)
{
	uint8		flags;

	/* read the flags */
	flags = pq_getmsgbyte(in);
	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read fields */
	*origin_lsn = pq_getmsgint64(in);
	return pq_getmsgint(in, sizeof(RepOriginId));
}

/*
 * Read LAST commit ts info from the output stream.
 */
TimestampTz
spock_read_commit_order(StringInfo in)
{
	uint8		flags;

	/* read the flags */
	flags = pq_getmsgbyte(in);
	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read fields */
	return pq_getmsgint64(in);
}

/*
 * Read INSERT from stream.
 *
 * Fills the new tuple.
 */
SpockRelation *
spock_read_insert(StringInfo in, LOCKMODE lockmode, SpockTupleData *newtup)
{
	char		action;
	uint32		relid;
	uint8		flags;
	SpockRelation *rel;

	/* read the flags */
	flags = pq_getmsgbyte(in);
	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read the relation id */
	relid = pq_getmsgint(in, 4);

	action = pq_getmsgbyte(in);
	if (action != 'N')
		elog(ERROR, "expected new tuple but got %d",
			 action);

	rel = spock_relation_open(relid, lockmode);
	if (unlikely(rel == NULL))
	{
		if (!MyApplyWorker->use_try_block)
			elog(ERROR, "Spock can't find relation with oid %u", relid);
		else
			return NULL;
	}

	spock_read_tuple(in, rel, newtup);

	return rel;
}

/*
 * Read UPDATE from stream.
 *
 * Cause an ERROR if table is not found. In a try-block just return NULL.
 */
SpockRelation *
spock_read_update(StringInfo in, LOCKMODE lockmode, bool *hasoldtup,
				  SpockTupleData *oldtup, SpockTupleData *newtup)
{
	char		action;
	Oid			relid;
	uint8		flags;
	SpockRelation *rel;

	/* read the flags */
	flags = pq_getmsgbyte(in);
	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read the relation id */
	relid = pq_getmsgint(in, 4);

	/* read and verify action */
	action = pq_getmsgbyte(in);
	if (action != 'K' && action != 'O' && action != 'N')
		elog(ERROR, "expected action 'N', 'O' or 'K', got %c",
			 action);

	rel = spock_relation_open(relid, lockmode);
	if (unlikely(rel == NULL))
	{
		if (!MyApplyWorker->use_try_block)

			/*
			 * TODO: We may do it smarter and extract table name beforehand to
			 * show it in the error message.
			 */
			elog(ERROR, "Spock can't find relation with oid %u", relid);
		else
			return NULL;
	}

	/* check for old tuple */
	if (action == 'K' || action == 'O')
	{
		spock_read_tuple(in, rel, oldtup);
		*hasoldtup = true;
		action = pq_getmsgbyte(in);
	}
	else
		*hasoldtup = false;

	/* check for new  tuple */
	if (action != 'N')
		elog(ERROR, "expected action 'N', got %c",
			 action);

	spock_read_tuple(in, rel, newtup);

	return rel;
}

/*
 * Read DELETE from stream.
 *
 * Fills the old tuple.
 */
SpockRelation *
spock_read_delete(StringInfo in, LOCKMODE lockmode,
				  SpockTupleData *oldtup)
{
	char		action;
	Oid			relid;
	uint8		flags;
	SpockRelation *rel;

	/* read the flags */
	flags = pq_getmsgbyte(in);
	Assert(flags == 0);
	(void) flags;				/* unused */

	/* read the relation id */
	relid = pq_getmsgint(in, 4);

	/* read and verify action */
	action = pq_getmsgbyte(in);
	if (action != 'K' && action != 'O')
		elog(ERROR, "expected action 'O' or 'K' %c", action);

	rel = spock_relation_open(relid, lockmode);
	if (unlikely(rel == NULL))
	{
		if (!MyApplyWorker->use_try_block)

			/*
			 * TODO: We may do it smarter and extract table name beforehand to
			 * show it in the error message.
			 */
			elog(ERROR, "Spock can't find relation with oid %u", relid);
		else
			return NULL;
	}

	spock_read_tuple(in, rel, oldtup);

	return rel;
}


/*
 * Read tuple in remote format from stream.
 *
 * The returned tuple is converted to the local relation tuple format.
 */
static void
spock_read_tuple(StringInfo in, SpockRelation *rel,
				 SpockTupleData *tuple)
{
	int			i;
	int			natts;
	char		action;
	TupleDesc	desc;

	action = pq_getmsgbyte(in);
	if (action != 'T')
		elog(ERROR, "expected TUPLE, got %c", action);

	memset(tuple->nulls, 1, sizeof(tuple->nulls));
	memset(tuple->changed, 0, sizeof(tuple->changed));

	natts = pq_getmsgint(in, 2);
	if (rel->natts != natts)
		elog(ERROR, "tuple natts mismatch for relation (%s) between remote relation metadata cache (natts=%u) and remote tuple data (natts=%u)", rel->relname, rel->natts, natts);

	desc = RelationGetDescr(rel->rel);

	/* Read the data */
	for (i = 0; i < natts; i++)
	{
		int			attid = rel->attmap[i];
		Oid			attrtype = rel->attrtypes[i];
		Oid			attrtypmod = rel->attrtypmods[i];
		Form_pg_attribute att = TupleDescAttr(desc, attid);
		char		kind = pq_getmsgbyte(in);
		const char *data;
		int			len;

		switch (kind)
		{
			case 'n':			/* null */
				/* already marked as null */
				tuple->values[attid] = 0xdeadbeef;
				tuple->changed[attid] = true;
				break;
			case 'u':			/* unchanged column */
				tuple->values[attid] = 0xfbadbeef;	/* make bad usage more
													 * obvious */
				break;
			case 'i':			/* internal binary format */
				tuple->nulls[attid] = false;
				tuple->changed[attid] = true;

				len = pq_getmsgint(in, 4);	/* read length */
				data = pq_getmsgbytes(in, len);

				/* and data */
				if (att->attbyval)
					tuple->values[attid] = fetch_att(data, true, len);
				else
					tuple->values[attid] = PointerGetDatum(data);
				break;
			case 'b':			/* binary send/recv format */
				{
					Oid			typreceive;
					Oid			typioparam;
					StringInfoData buf;

					tuple->nulls[attid] = false;
					tuple->changed[attid] = true;

					len = pq_getmsgint(in, 4);	/* read length */

					/*
					 * From a security standpoint, it doesn't matter whether
					 * the input's column type matches what we expect: the
					 * column type's receive function has to be robust enough
					 * to cope with invalid data. However, from a
					 * user-friendliness standpoint, it's nicer to complain
					 * about type mismatches than to throw "improper binary
					 * format" errors.  But there's a problem: only built-in
					 * types have OIDs that are stable enough to believe that
					 * a mismatch is a real issue.  So complain only if both
					 * OIDs are in the built-in range. Otherwise, carry on
					 * with the column type we "should" be getting.
					 */
					if ((att->atttypid != attrtype ||
						 att->atttypmod != attrtypmod) &&
						att->atttypid < FirstNormalObjectId &&
						attrtype < FirstNormalObjectId)
					{
						bits16		flags = FORMAT_TYPE_TYPEMOD_GIVEN | FORMAT_TYPE_ALLOW_INVALID;

						ereport(ERROR,
								(errcode(ERRCODE_DATATYPE_MISMATCH),
								 errmsg("binary data has type %u (%s) instead of expected %u (%s)",
										attrtype,
										format_type_extended(attrtype, attrtypmod, flags),
										att->atttypid,
										format_type_extended(att->atttypid, att->atttypmod, flags)),
								 errdetail("check attribute '%s' of table '%s'",
										   NameStr(att->attname),
										   NameStr(rel->rel->rd_rel->relname))));
					}

					getTypeBinaryInputInfo(att->atttypid,
										   &typreceive, &typioparam);

					/* create StringInfo pointing into the bigger buffer */
					initStringInfo(&buf);
					/* and data */
					buf.data = (char *) pq_getmsgbytes(in, len);
					buf.len = len;
					tuple->values[attid] = OidReceiveFunctionCall(
																  typreceive, &buf, typioparam, att->atttypmod);

					if (buf.len != buf.cursor)
						ereport(ERROR,
								(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
								 errmsg("incorrect binary data format for column '%s' of table '%s'",
										NameStr(att->attname),
										NameStr(rel->rel->rd_rel->relname))));
					break;
				}
			case 't':			/* text format */
				{
					Oid			typinput;
					Oid			typioparam;

					tuple->nulls[attid] = false;
					tuple->changed[attid] = true;

					len = pq_getmsgint(in, 4);	/* read length */

					getTypeInputInfo(att->atttypid, &typinput, &typioparam);
					/* and data */
					data = (char *) pq_getmsgbytes(in, len);
					tuple->values[attid] = OidInputFunctionCall(
																typinput, (char *) data, typioparam, att->atttypmod);
				}
				break;
			default:
				elog(ERROR, "unknown data representation type '%c'", kind);
		}
	}
}

/*
 * Read schema.relation from stream and return as SpockRelation opened in
 * lockmode.
 */
uint32
spock_read_rel(StringInfo in)
{
	uint8		flags;
	uint32		relid;
	int			len;
	char	   *schemaname;
	char	   *relname;
	int			natts;
	char	  **attrnames;
	Oid		   *attrtypes;
	Oid		   *attrtypmods;

	/* read the flags */
	flags = pq_getmsgbyte(in);
	Assert(flags == 0);
	(void) flags;				/* unused */

	relid = pq_getmsgint(in, 4);

	/* Read relation from stream */
	len = pq_getmsgbyte(in);
	schemaname = (char *) pq_getmsgbytes(in, len);

	len = pq_getmsgbyte(in);
	relname = (char *) pq_getmsgbytes(in, len);

	/* Get attribute description */
	spock_read_attrs(in, &attrnames, &attrtypes, &attrtypmods, &natts);

	spock_relation_cache_update(relid, schemaname, relname, natts, attrnames, attrtypes, attrtypmods);

	return relid;
}

/*
 * Read relation attributes from the outputstream.
 *
 * TODO handle flags.
 */
static void
spock_read_attrs(StringInfo in, char ***attrnames, Oid **attrtypes,
				 Oid **attrtypmods, int *nattrnames)
{
	int			i;
	uint16		nattrs;
	char	  **attrs;
	Oid		   *types;
	Oid		   *typmods;
	char		blocktype;

	blocktype = pq_getmsgbyte(in);
	if (blocktype != 'A')
		elog(ERROR, "expected ATTRS, got %c", blocktype);

	nattrs = pq_getmsgint(in, 2);
	attrs = palloc(nattrs * sizeof(char *));
	types = (Oid *) palloc(nattrs * sizeof(Oid));
	typmods = (Oid *) palloc(nattrs * sizeof(Oid));

	/* read the attributes */
	for (i = 0; i < nattrs; i++)
	{
		uint16		len;

		blocktype = pq_getmsgbyte(in);	/* column definition follows */
		if (blocktype != 'C')
			elog(ERROR, "expected COLUMN, got %c", blocktype);
		/* read flags (we ignore them so far) */
		(void) pq_getmsgbyte(in);

		blocktype = pq_getmsgbyte(in);	/* column name block follows */
		if (blocktype != 'N')
			elog(ERROR, "expected NAME, got %c", blocktype);

		/* attribute name */
		len = pq_getmsgint(in, 2);
		/* the string is NULL terminated */
		attrs[i] = (char *) pq_getmsgbytes(in, len);
		types[i] = pq_getmsgint(in, 4); /* atttype */
		typmods[i] = pq_getmsgint(in, 4);	/* atttypmod */
	}

	*attrnames = attrs;
	*attrtypes = types;
	*attrtypmods = typmods;
	*nattrnames = nattrs;
}

/*
 * Write TRUNCATE command to the outputstream.
 */
void
spock_write_truncate(StringInfo out, int nrelids, Oid relids[], bool cascade,
					 bool restart_seqs)
{
	int			i;
	uint8		flags = 0;

	/* Protocol version 5+ includes remote_insert_lsn at the beginning */
	if (spock_get_proto_version() >= 5)
		pq_sendint64(out, GetXLogWriteRecPtr());

	pq_sendbyte(out, 'T');

	pq_sendint32(out, nrelids);

	/* encode and send truncate flags */
	if (cascade)
		flags |= TRUNCATE_CASCADE;
	if (restart_seqs)
		flags |= TRUNCATE_RESTART_SEQS;
	pq_sendint8(out, flags);

	for (i = 0; i < nrelids; i++)
		pq_sendint32(out, relids[i]);
}

/*
 * Read TRUNCATE command from the outputstream.
 */
List *
spock_read_truncate(StringInfo in, bool *cascade, bool *restart_seqs)
{
	int			i;
	int			nrelids;
	List	   *relids = NIL;
	uint8		flags;

	nrelids = pq_getmsgint(in, 4);

	/* read and decode truncate flags */
	flags = pq_getmsgint(in, 1);
	*cascade = (flags & TRUNCATE_CASCADE) > 0;
	*restart_seqs = (flags & TRUNCATE_RESTART_SEQS) > 0;

	for (i = 0; i < nrelids; i++)
		relids = lappend_oid(relids, pq_getmsgint(in, 4));

	return relids;
}
