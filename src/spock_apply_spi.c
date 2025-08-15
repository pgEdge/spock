/*-------------------------------------------------------------------------
 *
 * spock_apply_spi.c
 * 		spock apply functions using SPI
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 * NOTES
 *	  The multi-insert support is not done through SPI but using binary
 *	  COPY through a pipe (virtual or file).
 *
 *-------------------------------------------------------------------------
 */
#include <stdio.h>
#include <unistd.h>

#include "postgres.h"

#include "access/htup_details.h"
#include "access/sysattr.h"
#include "access/xact.h"

#include "commands/copy.h"

#include "executor/executor.h"
#include "executor/spi.h"

#include "replication/origin.h"
#include "replication/reorderbuffer.h"

#include "storage/fd.h"

#include "tcop/pquery.h"
#include "tcop/utility.h"

#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/builtins.h"

#include "spock.h"
#include "spock_apply_spi.h"
#include "spock_conflict.h"

/* for htonl/htons */
#include <arpa/inet.h>

/* State related to bulk insert */
typedef struct spock_copyState
{
	SpockRelation  *rel;

	StringInfo		copy_stmt;
	List		   *copy_parsetree;
	File			copy_file;
	char			copy_mechanism;
	FILE		   *copy_read_file;
	FILE		   *copy_write_file;
	StringInfo		msgbuf;
	MemoryContext	rowcontext;
	FmgrInfo	   *out_functions;
	List		   *attnumlist;
	int				copy_buffered_tuples;
	size_t			copy_buffered_size;
} spock_copyState;

static spock_copyState *spkcstate = NULL;

static const char BinarySignature[11] = "PGCOPY\n\377\r\n\0";

static void spock_start_copy(SpockRelation *rel);
static void spock_proccess_copy(spock_copyState *spkcstate);

static void spock_copySendData(spock_copyState *spkcstate,
								   const void *databuf, int datasize);
static void spock_copySendEndOfRow(spock_copyState *spkcstate);
static void spock_copySendInt32(spock_copyState *spkcstate, int32 val);
static void spock_copySendInt16(spock_copyState *spkcstate, int16 val);
static void spock_copyOneRowTo(spock_copyState *spkcstate,
								   Datum *values, bool *nulls);

/*
 * Handle begin (connect SPI).
 */
void
spock_apply_spi_begin(void)
{
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed");
	MemoryContextSwitchTo(MessageContext);
}

/*
 * Handle commit (finish SPI).
 */
void
spock_apply_spi_commit(void)
{
	if (SPI_finish() != SPI_OK_FINISH)
		elog(ERROR, "SPI_finish failed");
	MemoryContextSwitchTo(MessageContext);
}

/*
 * Handle insert via SPI.
 */
void
spock_apply_spi_insert(SpockRelation *rel, SpockTupleData *newtup)
{
	TupleDesc		desc = RelationGetDescr(rel->rel);
	Oid				argtypes[MaxTupleAttributeNumber];
	Datum			values[MaxTupleAttributeNumber];
	char			nulls[MaxTupleAttributeNumber];
	StringInfoData	cmd;
	int	att,
		narg;

	initStringInfo(&cmd);
	appendStringInfo(&cmd, "INSERT INTO %s (",
					 quote_qualified_identifier(rel->nspname, rel->relname));

	for (att = 0, narg = 0; att < desc->natts; att++)
	{
		if (TupleDescAttr(desc,att)->attisdropped)
			continue;

		if (!newtup->changed[att])
			continue;

		if (narg > 0)
			appendStringInfo(&cmd, ", %s",
					quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)));
		else
			appendStringInfo(&cmd, "%s",
					quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)));
		narg++;
	}

	appendStringInfoString(&cmd, ") VALUES (");

	for (att = 0, narg = 0; att < desc->natts; att++)
	{
		if (TupleDescAttr(desc,att)->attisdropped)
			continue;

		if (!newtup->changed[att])
			continue;

		if (narg > 0)
			appendStringInfo(&cmd, ", $%u", narg + 1);
		else
			appendStringInfo(&cmd, "$%u", narg + 1);

		argtypes[narg] = TupleDescAttr(desc,att)->atttypid;
		values[narg] = newtup->values[att];
		nulls[narg] = newtup->nulls[att] ? 'n' : ' ';
		narg++;
	}

	appendStringInfoString(&cmd, ")");

	if (SPI_execute_with_args(cmd.data, narg, argtypes, values, nulls, false,
							  0) != SPI_OK_INSERT)
		elog(ERROR, "SPI_execute_with_args failed");
	MemoryContextSwitchTo(MessageContext);

	pfree(cmd.data);
}

/*
 * Handle update via SPI.
 */
void
spock_apply_spi_update(SpockRelation *rel, SpockTupleData *oldtup,
						   SpockTupleData *newtup)
{
	TupleDesc		desc = RelationGetDescr(rel->rel);
	Oid				argtypes[MaxTupleAttributeNumber];
	Datum			values[MaxTupleAttributeNumber];
	char			nulls[MaxTupleAttributeNumber];
	StringInfoData	cmd;
	Bitmapset	   *id_attrs;
	int	att,
		narg,
		firstarg;

	id_attrs = RelationGetIndexAttrBitmap(rel->rel,
										  INDEX_ATTR_BITMAP_IDENTITY_KEY);

	initStringInfo(&cmd);
	appendStringInfo(&cmd, "UPDATE %s SET ",
					 quote_qualified_identifier(rel->nspname, rel->relname));

	for (att = 0, narg = 0; att < desc->natts; att++)
	{
		if (TupleDescAttr(desc,att)->attisdropped)
			continue;

		if (!newtup->changed[att])
			continue;

		if (narg > 0)
			appendStringInfo(&cmd, ", %s = $%u",
							 quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)),
							 narg + 1);
		else
			appendStringInfo(&cmd, "%s = $%u",
							 quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)),
							 narg + 1);

		argtypes[narg] = TupleDescAttr(desc,att)->atttypid;
		values[narg] = newtup->values[att];
		nulls[narg] = newtup->nulls[att] ? 'n' : ' ';
		narg++;
	}

	appendStringInfoString(&cmd, " WHERE");

	firstarg = narg;
	for (att = 0; att < desc->natts; att++)
	{
		if (!bms_is_member(TupleDescAttr(desc,att)->attnum - FirstLowInvalidHeapAttributeNumber,
						   id_attrs))
			continue;

		if (narg > firstarg)
			appendStringInfo(&cmd, " AND %s = $%u",
							 quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)),
							 narg + 1);
		else
			appendStringInfo(&cmd, " %s = $%u",
							 quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)),
							 narg + 1);

		argtypes[narg] = TupleDescAttr(desc,att)->atttypid;
		values[narg] = oldtup->values[att];
		nulls[narg] = oldtup->nulls[att] ? 'n' : ' ';
		narg++;
	}

	if (SPI_execute_with_args(cmd.data, narg, argtypes, values, nulls, false,
							  0) != SPI_OK_UPDATE)
		elog(ERROR, "SPI_execute_with_args failed");
	MemoryContextSwitchTo(MessageContext);

	pfree(cmd.data);
}

/*
 * Handle delete via SPI.
 */
void
spock_apply_spi_delete(SpockRelation *rel, SpockTupleData *oldtup)
{
	TupleDesc		desc = RelationGetDescr(rel->rel);
	Oid				argtypes[MaxTupleAttributeNumber];
	Datum			values[MaxTupleAttributeNumber];
	char			nulls[MaxTupleAttributeNumber];
	StringInfoData	cmd;
	Bitmapset	   *id_attrs;
	int	att,
		narg;

	id_attrs = RelationGetIndexAttrBitmap(rel->rel,
										  INDEX_ATTR_BITMAP_IDENTITY_KEY);

	initStringInfo(&cmd);
	appendStringInfo(&cmd, "DELETE FROM %s WHERE",
					 quote_qualified_identifier(rel->nspname, rel->relname));

	for (att = 0, narg = 0; att < desc->natts; att++)
	{
		if (!bms_is_member(TupleDescAttr(desc,att)->attnum - FirstLowInvalidHeapAttributeNumber,
						   id_attrs))
			continue;

		if (narg > 0)
			appendStringInfo(&cmd, " AND %s = $%u",
							 quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)),
							 narg + 1);
		else
			appendStringInfo(&cmd, " %s = $%u",
							 quote_identifier(NameStr(TupleDescAttr(desc,att)->attname)),
							 narg + 1);

		argtypes[narg] = TupleDescAttr(desc,att)->atttypid;
		values[narg] = oldtup->values[att];
		nulls[narg] = oldtup->nulls[att] ? 'n' : ' ';
		narg++;
	}

	if (SPI_execute_with_args(cmd.data, narg, argtypes, values, nulls, false,
							  0) != SPI_OK_DELETE)
		elog(ERROR, "SPI_execute_with_args failed");
	MemoryContextSwitchTo(MessageContext);

	pfree(cmd.data);
}


/* We currently can't support multi insert using COPY on windows. */
#if !defined(WIN32) && !defined(SPK_NO_STDIN_ASSIGN)

bool
spock_apply_spi_can_mi(SpockRelation *rel)
{
	/* Multi insert is only supported when conflicts result in errors. */
	return spock_conflict_resolver == SPOCK_RESOLVE_ERROR;
}

void
spock_apply_spi_mi_add_tuple(SpockRelation *rel,
								 SpockTupleData *tup)
{
	Datum	*values;
	bool	*nulls;

	/* Start COPY if not already done so */
	spock_start_copy(rel);

#define MAX_BUFFERED_TUPLES		10000
#define MAX_BUFFER_SIZE			60000
	/*
	 * If sufficient work is pending, process that first
	 */
	if (spkcstate->copy_buffered_tuples > MAX_BUFFERED_TUPLES ||
		spkcstate->copy_buffered_size > MAX_BUFFER_SIZE)
	{
		spock_apply_spi_mi_finish(rel);
		spock_start_copy(rel);
	}

	/*
	 * Write the tuple to the COPY stream.
	 */
	values = (Datum *) tup->values;
	nulls = (bool *) tup->nulls;
	spock_copyOneRowTo(spkcstate, values, nulls);
}


/*
 * Initialize copy state for reation.
 */
static void
spock_start_copy(SpockRelation *rel)
{
	MemoryContext oldcontext;
	TupleDesc		desc;
	ListCell	   *cur;
	int				num_phys_attrs;
	char		   *delim;
	StringInfoData  attrnames;
	int				i;

	/* We are already doing COPY for requested relation, nothing to do. */
	if (spkcstate && spkcstate->rel == rel)
		return;

	/* We are in COPY but for different relation, finish it first. */
	if (spkcstate && spkcstate->rel != rel)
		spock_apply_spi_mi_finish(spkcstate->rel);

	oldcontext = MemoryContextSwitchTo(TopTransactionContext);

	/* Initialize new COPY state. */
	spkcstate = palloc0(sizeof(spock_copyState));

	spkcstate->copy_file = -1;
	spkcstate->msgbuf = makeStringInfo();
	spkcstate->rowcontext = AllocSetContextCreate(CurrentMemoryContext,
												  "COPY TO",
												  ALLOCSET_DEFAULT_SIZES);

	spkcstate->rel = rel;

	for (i = 0; i < rel->natts; i++)
		spkcstate->attnumlist = lappend_int(spkcstate->attnumlist,
											rel->attmap[i]);

	desc = RelationGetDescr(rel->rel);
	num_phys_attrs = desc->natts;

	/* Get info about the columns we need to process. */
	spkcstate->out_functions = (FmgrInfo *) palloc(num_phys_attrs * sizeof(FmgrInfo));

	/* Get attribute list in a CSV form */
	initStringInfo(&attrnames);
	delim = "";

	/*
	 * Now that we have a list of attributes from the remote side and their
	 * mapping to our side, build a COPY statement that can be parsed and
	 * executed later to bulk load the incoming tuples.
	 */
	foreach(cur, spkcstate->attnumlist)
	{
		int         attnum = lfirst_int(cur);
		Oid         out_func_oid;
		bool        isvarlena;

		getTypeBinaryOutputInfo(TupleDescAttr(desc,attnum)->atttypid,
								&out_func_oid,
								&isvarlena);
		fmgr_info(out_func_oid, &spkcstate->out_functions[attnum]);
		appendStringInfo(&attrnames, "%s %s",
						 delim,
						 quote_identifier(NameStr(TupleDescAttr(desc,attnum)->attname)));
		delim = ", ";

	}

	spkcstate->copy_stmt = makeStringInfo();
	appendStringInfo(spkcstate->copy_stmt, "COPY %s.%s (%s) FROM STDIN "
					 "WITH (FORMAT BINARY)",
					 quote_identifier(rel->nspname),
					 quote_identifier(rel->relname),
					 attrnames.data);
	pfree(attrnames.data);


	/*
	 * This is a bit of kludge to let COPY FROM read from the STDIN. In
	 * spock, the apply worker is accumulating tuples received from the
	 * publisher and queueing them for a bulk load. But the COPY API can only
	 * deal with either a file or a PROGRAM or STDIN.
	 *
	 * We could either use pipe-based implementation where the apply worker
	 * first writes to one end of the pipe and later reads from the other end.
	 * But pipe's internal buffer is limited in size and hence we cannot
	 * accumulate much data without writing it out to the table.
	 *
	 * The temporary file based implementation is more flexible. The only
	 * disadvantage being that the data may get written to the disk and that
	 * may cause performance issues.
	 *
	 * A more ideal solution would be to teach COPY to write to and read from a
	 * buffer. But that will require changes to the in-core COPY
	 * infrastructure. Instead, we setup things such that a pipe is created
	 * between STDIN and a unnamed stream. The tuples are written to the one
	 * end of the pipe and read back from the other end. Since we can fiddle
	 * with the existing STDIN, we assign the read end of the pipe to STDIN.
	 *
	 * This seems ok since the apply worker being a background worker is not
	 * going to read anything from the STDIN normally. So our highjacking of
	 * the stream seems ok.
	 */
	if (spkcstate->copy_file == -1)
		spkcstate->copy_file = OpenTemporaryFile(true);

	Assert(spkcstate->copy_file > 0);

	spkcstate->copy_write_file = fopen(FilePathName(spkcstate->copy_file), "w");
	spkcstate->copy_read_file = fopen(FilePathName(spkcstate->copy_file), "r");
	spkcstate->copy_mechanism = 'f';

	spkcstate->copy_parsetree = pg_parse_query(spkcstate->copy_stmt->data);
	MemoryContextSwitchTo(oldcontext);

	spock_copySendData(spkcstate, BinarySignature,
						   sizeof(BinarySignature));
	spock_copySendInt32(spkcstate, 0);
	spock_copySendInt32(spkcstate, 0);
}

static void
spock_proccess_copy(spock_copyState *spkcstate)
{
	uint64	processed;
	FILE	*save_stdin;

	if (!spkcstate->copy_parsetree || !spkcstate->copy_buffered_tuples)
		return;

	/*
	 * First send a file trailer so that when DoCopy is run below, it sees an
	 * end of the file marker and terminates COPY once all queued tuples are
	 * processed. We also close the file descriptor because DoCopy expects to
	 * see a real EOF too
	 */
	spock_copySendInt16(spkcstate, -1);

	/* Also ensure that the data is flushed to the stream */
	spock_copySendEndOfRow(spkcstate);

	/*
	 * Now close the write end of the pipe so that DoCopy sees end of the
	 * stream.
	 *
	 * XXX This is really sad because ideally we would have liked to keep the
	 * pipe open and use that for next batch of bulk copy. But given the way
	 * COPY protocol currently works, we don't have any other option but to
	 * close the stream.
	 */
	fflush(spkcstate->copy_write_file);
	fclose(spkcstate->copy_write_file);
	spkcstate->copy_write_file = NULL;

	/*
	 * The COPY statement previously crafted will read from STDIN. So we
	 * override the 'stdin' stream to point to the read end of the pipe created
	 * for this relation. Before that we save the current 'stdin' stream and
	 * restore it back when the COPY is done
	 */
	save_stdin = stdin;
	stdin = spkcstate->copy_read_file;

	/* Initiate the actual COPY */
	SPKDoCopy((CopyStmt*)((RawStmt *)linitial(spkcstate->copy_parsetree))->stmt,
		spkcstate->copy_stmt->data, &processed);

	fclose(spkcstate->copy_read_file);
	spkcstate->copy_read_file = NULL;
	stdin = save_stdin;

	/* Ensure we processed correct number of tuples */
	Assert(processed == spkcstate->copy_buffered_tuples);

	list_free_deep(spkcstate->copy_parsetree);
	spkcstate->copy_parsetree = NIL;

	spkcstate->copy_buffered_tuples = 0;
	spkcstate->copy_buffered_size = 0;

	CommandCounterIncrement();
}

void
spock_apply_spi_mi_finish(SpockRelation *rel)
{
	if (!spkcstate)
		return;

	Assert(spkcstate->rel == rel);

	spock_proccess_copy(spkcstate);

	if (spkcstate->copy_stmt)
	{
		pfree(spkcstate->copy_stmt->data);
		pfree(spkcstate->copy_stmt);
	}

	if (spkcstate->attnumlist)
		list_free(spkcstate->attnumlist);

	if (spkcstate->copy_file != -1)
		FileClose(spkcstate->copy_file);

	if (spkcstate->copy_write_file)
		fclose(spkcstate->copy_write_file);

	if (spkcstate->copy_read_file)
		fclose(spkcstate->copy_read_file);

	if (spkcstate->msgbuf)
	{
		pfree(spkcstate->msgbuf->data);
		pfree(spkcstate->msgbuf);
	}

	if (spkcstate->rowcontext)
	{
		MemoryContextDelete(spkcstate->rowcontext);
		spkcstate->rowcontext = NULL;
	}

	pfree(spkcstate);

	spkcstate = NULL;
}

/*
 * spock_copySendInt32 sends an int32 in network byte order
 */
static void
spock_copySendInt32(spock_copyState *spkcstate, int32 val)
{
	uint32		buf;

	buf = htonl((uint32) val);
	spock_copySendData(spkcstate, &buf, sizeof(buf));
}

/*
 * spock_copySendInt16 sends an int16 in network byte order
 */
static void
spock_copySendInt16(spock_copyState *spkcstate, int16 val)
{
	uint16		buf;

	buf = htons((uint16) val);
	spock_copySendData(spkcstate, &buf, sizeof(buf));
}

/*----------
 * spock_copySendData sends output data to the destination (file or frontend)
 * spock_copySendEndOfRow does the appropriate thing at end of each data row
 *	(data is not actually flushed except by spock_copySendEndOfRow)
 *
 * NB: no data conversion is applied by these functions
 *----------
 */
static void
spock_copySendData(spock_copyState *spkcstate, const void *databuf,
					   int datasize)
{
	appendBinaryStringInfo(spkcstate->msgbuf, databuf, datasize);
}

static void
spock_copySendEndOfRow(spock_copyState *spkcstate)
{
	StringInfo	msgbuf = spkcstate->msgbuf;

	if (fwrite(msgbuf->data, msgbuf->len, 1,
				spkcstate->copy_write_file) != 1 ||
			ferror(spkcstate->copy_write_file))
	{
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write to COPY file: %m")));
	}

	resetStringInfo(msgbuf);
}

/*
 * Emit one row during CopyTo().
 */
static void
spock_copyOneRowTo(spock_copyState *spkcstate, Datum *values,
					   bool *nulls)
{
	FmgrInfo   *out_functions = spkcstate->out_functions;
	MemoryContext oldcontext;
	ListCell   *cur;

	MemoryContextReset(spkcstate->rowcontext);
	oldcontext = MemoryContextSwitchTo(spkcstate->rowcontext);

	/* Binary per-tuple header */
	spock_copySendInt16(spkcstate, list_length(spkcstate->attnumlist));

	foreach(cur, spkcstate->attnumlist)
	{
		int			attnum = lfirst_int(cur);
		Datum		value = values[attnum];
		bool		isnull = nulls[attnum];

		if (isnull)
			spock_copySendInt32(spkcstate, -1);
		else
		{
			bytea	   *outputbytes;

			outputbytes = SendFunctionCall(&out_functions[attnum],
										   value);
			spock_copySendInt32(spkcstate, VARSIZE(outputbytes) - VARHDRSZ);
			spock_copySendData(spkcstate, VARDATA(outputbytes),
						 VARSIZE(outputbytes) - VARHDRSZ);
		}
	}

	spkcstate->copy_buffered_tuples++;
	spkcstate->copy_buffered_size += spkcstate->msgbuf->len;

	spock_copySendEndOfRow(spkcstate);

	MemoryContextSwitchTo(oldcontext);
}

#else /* WIN32 */

bool
spock_apply_spi_can_mi(SpockRelation *rel)
{
	return false;
}

void
spock_apply_spi_mi_add_tuple(SpockRelation *rel,
								 SpockTupleData *tup)
{
	elog(ERROR, "spock_apply_spi_mi_add_tuple called unexpectedly");
}

void
spock_apply_spi_mi_finish(SpockRelation *rel)
{
	elog(ERROR, "spock_apply_spi_mi_finish called unexpectedly");
}

#endif /* WIN32 */
