
#include "postgres.h"

#include "miscadmin.h"

#include "libpq/libpq-be.h"

#include "access/commit_ts.h"
#include "access/xact.h"

#include "commands/dbcommands.h"
#include "common/hashfn.h"

#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_type.h"

#include "nodes/makefuncs.h"
#include "postmaster/interrupt.h"

#include "storage/ipc.h"
#include "storage/proc.h"
#include "storage/procsignal.h"
#include "storage/procarray.h"

#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "utils/builtins.h"
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/jsonfuncs.h"
#include "utils/typcache.h"
#include "utils/attoptcache.h"

#include "parser/parse_coerce.h"

#include "replication/origin.h"
#include "replication/slot.h"

#include "pgstat.h"

#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_conflict.h"
#include "spock_relcache.h"
#include "spock_jsonb_utils.h"


/* All static function signatures in file */
static JsonParseErrorType jsonb_in_object_start(void *pstate);
static JsonParseErrorType jsonb_in_object_end(void *pstate);
static JsonParseErrorType jsonb_in_array_start(void *pstate);
static JsonParseErrorType jsonb_in_array_end(void *pstate);
static JsonParseErrorType jsonb_in_object_field_start(void *pstate, char *fname, bool isnull);
static JsonParseErrorType jsonb_in_scalar(void *pstate, char *token, JsonTokenType tokentype);
static void jsonb_put_escaped_value(StringInfo out, JsonbValue *scalarVal);
static bool checkStringLen(size_t len, Node *escontext);
static void jsonb_categorize_type(Oid typoid, JsonbTypeCategory * tcategory, Oid *outfuncoid);
static void datum_to_jsonb(Datum val, bool is_null, JsonbInState *result, JsonbTypeCategory tcategory, Oid outfuncoid, bool key_scalar);


static JsonParseErrorType
jsonb_in_object_start(void *pstate)
{
	JsonbInState *_state = (JsonbInState *) pstate;

	_state->res = pushJsonbValue(&_state->parseState, WJB_BEGIN_OBJECT, NULL);

	return JSON_SUCCESS;
}

static JsonParseErrorType
jsonb_in_object_end(void *pstate)
{
	JsonbInState *_state = (JsonbInState *) pstate;

	_state->res = pushJsonbValue(&_state->parseState, WJB_END_OBJECT, NULL);

	return JSON_SUCCESS;
}

static JsonParseErrorType
jsonb_in_array_start(void *pstate)
{
	JsonbInState *_state = (JsonbInState *) pstate;

	_state->res = pushJsonbValue(&_state->parseState, WJB_BEGIN_ARRAY, NULL);

	return JSON_SUCCESS;
}

static JsonParseErrorType
jsonb_in_array_end(void *pstate)
{
	JsonbInState *_state = (JsonbInState *) pstate;

	_state->res = pushJsonbValue(&_state->parseState, WJB_END_ARRAY, NULL);

	return JSON_SUCCESS;
}

static JsonParseErrorType
jsonb_in_object_field_start(void *pstate, char *fname, bool isnull)
{
	JsonbInState *_state = (JsonbInState *) pstate;
	JsonbValue	v;

	Assert(fname != NULL);
	v.type = jbvString;
	v.val.string.len = strlen(fname);
	if (!checkStringLen(v.val.string.len, _state->escontext))
		return JSON_SEM_ACTION_FAILED;
	v.val.string.val = fname;

	_state->res = pushJsonbValue(&_state->parseState, WJB_KEY, &v);

	return JSON_SUCCESS;
}

static void
jsonb_put_escaped_value(StringInfo out, JsonbValue *scalarVal)
{
	switch (scalarVal->type)
	{
		case jbvNull:
			appendBinaryStringInfo(out, "null", 4);
			break;
		case jbvString:
			escape_json(out, pnstrdup(scalarVal->val.string.val, scalarVal->val.string.len));
			break;
		case jbvNumeric:
			appendStringInfoString(out,
								   DatumGetCString(DirectFunctionCall1(numeric_out,
																	   PointerGetDatum(scalarVal->val.numeric))));
			break;
		case jbvBool:
			if (scalarVal->val.boolean)
				appendBinaryStringInfo(out, "true", 4);
			else
				appendBinaryStringInfo(out, "false", 5);
			break;
		default:
			elog(ERROR, "unknown jsonb scalar type");
	}
}

/*
 * For jsonb we always want the de-escaped value - that's what's in token
 */
static JsonParseErrorType
jsonb_in_scalar(void *pstate, char *token, JsonTokenType tokentype)
{
	JsonbInState *_state = (JsonbInState *) pstate;
	JsonbValue	v;
	Datum		numd;

	switch (tokentype)
	{

		case JSON_TOKEN_STRING:
			Assert(token != NULL);
			v.type = jbvString;
			v.val.string.len = strlen(token);
			if (!checkStringLen(v.val.string.len, _state->escontext))
				return JSON_SEM_ACTION_FAILED;
			v.val.string.val = token;
			break;
		case JSON_TOKEN_NUMBER:

			/*
			 * No need to check size of numeric values, because maximum
			 * numeric size is well below the JsonbValue restriction
			 */
			Assert(token != NULL);
			v.type = jbvNumeric;
			if (!DirectInputFunctionCallSafe(numeric_in, token,
											 InvalidOid, -1,
											 _state->escontext,
											 &numd))
				return JSON_SEM_ACTION_FAILED;
			v.val.numeric = DatumGetNumeric(numd);
			break;
		case JSON_TOKEN_TRUE:
			v.type = jbvBool;
			v.val.boolean = true;
			break;
		case JSON_TOKEN_FALSE:
			v.type = jbvBool;
			v.val.boolean = false;
			break;
		case JSON_TOKEN_NULL:
			v.type = jbvNull;
			break;
		default:
			/* should not be possible */
			elog(ERROR, "invalid json token type");
			break;
	}

	if (_state->parseState == NULL)
	{
		/* single scalar */
		JsonbValue	va;

		va.type = jbvArray;
		va.val.array.rawScalar = true;
		va.val.array.nElems = 1;

		_state->res = pushJsonbValue(&_state->parseState, WJB_BEGIN_ARRAY, &va);
		_state->res = pushJsonbValue(&_state->parseState, WJB_ELEM, &v);
		_state->res = pushJsonbValue(&_state->parseState, WJB_END_ARRAY, NULL);
	}
	else
	{
		JsonbValue *o = &_state->parseState->contVal;

		switch (o->type)
		{
			case jbvArray:
				_state->res = pushJsonbValue(&_state->parseState, WJB_ELEM, &v);
				break;
			case jbvObject:
				_state->res = pushJsonbValue(&_state->parseState, WJB_VALUE, &v);
				break;
			default:
				elog(ERROR, "unexpected parent of nested structure");
		}
	}

	return JSON_SUCCESS;
}

static bool
checkStringLen(size_t len, Node *escontext)
{
	if (len > JENTRY_OFFLENMASK)
		ereturn(escontext, false,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("string too long to represent as jsonb string"),
				 errdetail("Due to an implementation restriction, jsonb strings cannot exceed %d bytes.",
						   JENTRY_OFFLENMASK)));

	return true;
}

/*
 * Determine how we want to render values of a given type in datum_to_jsonb.
 *
 * Given the datatype OID, return its JsonbTypeCategory, as well as the type's
 * output function OID.  If the returned category is JSONBTYPE_JSONCAST,
 * we return the OID of the relevant cast function instead.
 */
static void
jsonb_categorize_type(Oid typoid,
					  JsonbTypeCategory * tcategory,
					  Oid *outfuncoid)
{
	bool		typisvarlena;

	/* Look through any domain */
	typoid = getBaseType(typoid);

	*outfuncoid = InvalidOid;

	/*
	 * We need to get the output function for everything except date and
	 * timestamp types, booleans, array and composite types, json and jsonb,
	 * and non-builtin types where there's a cast to json. In this last case
	 * we return the oid of the cast function instead.
	 */

	switch (typoid)
	{
		case BOOLOID:
			*tcategory = JSONBTYPE_BOOL;
			break;

		case INT2OID:
		case INT4OID:
		case INT8OID:
		case FLOAT4OID:
		case FLOAT8OID:
		case NUMERICOID:
			getTypeOutputInfo(typoid, outfuncoid, &typisvarlena);
			*tcategory = JSONBTYPE_NUMERIC;
			break;

		case DATEOID:
			*tcategory = JSONBTYPE_DATE;
			break;

		case TIMESTAMPOID:
			*tcategory = JSONBTYPE_TIMESTAMP;
			break;

		case TIMESTAMPTZOID:
			*tcategory = JSONBTYPE_TIMESTAMPTZ;
			break;

		case JSONBOID:
			*tcategory = JSONBTYPE_JSONB;
			break;

		case JSONOID:
			*tcategory = JSONBTYPE_JSON;
			break;

		default:
			/* Check for arrays and composites */
			if (OidIsValid(get_element_type(typoid)) || typoid == ANYARRAYOID
				|| typoid == ANYCOMPATIBLEARRAYOID || typoid == RECORDARRAYOID)
				*tcategory = JSONBTYPE_ARRAY;
			else if (type_is_rowtype(typoid))	/* includes RECORDOID */
				*tcategory = JSONBTYPE_COMPOSITE;
			else
			{
				/* It's probably the general case ... */
				*tcategory = JSONBTYPE_OTHER;

				/*
				 * but first let's look for a cast to json (note: not to
				 * jsonb) if it's not built-in.
				 */
				if (typoid >= FirstNormalObjectId)
				{
					Oid			castfunc;
					CoercionPathType ctype;

					ctype = find_coercion_pathway(JSONOID, typoid,
												  COERCION_EXPLICIT, &castfunc);
					if (ctype == COERCION_PATH_FUNC && OidIsValid(castfunc))
					{
						*tcategory = JSONBTYPE_JSONCAST;
						*outfuncoid = castfunc;
					}
					else
					{
						/* not a cast type, so just get the usual output func */
						getTypeOutputInfo(typoid, outfuncoid, &typisvarlena);
					}
				}
				else
				{
					/* any other builtin type */
					getTypeOutputInfo(typoid, outfuncoid, &typisvarlena);
				}
				break;
			}
	}
}

/*
 * Turn a composite / record into JSON.
 */
static void
composite_to_jsonb(Datum composite, JsonbInState *result)
{
	HeapTupleHeader td;
	Oid			tupType;
	int32		tupTypmod;
	TupleDesc	tupdesc;
	HeapTupleData tmptup,
			   *tuple;
	int			i;

	td = DatumGetHeapTupleHeader(composite);

	/* Extract rowtype info and find a tupdesc */
	tupType = HeapTupleHeaderGetTypeId(td);
	tupTypmod = HeapTupleHeaderGetTypMod(td);
	tupdesc = lookup_rowtype_tupdesc(tupType, tupTypmod);

	/* Build a temporary HeapTuple control structure */
	tmptup.t_len = HeapTupleHeaderGetDatumLength(td);
	tmptup.t_data = td;
	tuple = &tmptup;

	result->res = pushJsonbValue(&result->parseState, WJB_BEGIN_OBJECT, NULL);

	for (i = 0; i < tupdesc->natts; i++)
	{
		Datum		val;
		bool		isnull;
		char	   *attname;
		JsonbTypeCategory tcategory;
		Oid			outfuncoid;
		JsonbValue	v;
		Form_pg_attribute att = TupleDescAttr(tupdesc, i);

		if (att->attisdropped)
			continue;

		attname = NameStr(att->attname);

		v.type = jbvString;
		/* don't need checkStringLen here - can't exceed maximum name length */
		v.val.string.len = strlen(attname);
		v.val.string.val = attname;

		result->res = pushJsonbValue(&result->parseState, WJB_KEY, &v);

		val = heap_getattr(tuple, i + 1, tupdesc, &isnull);

		if (isnull)
		{
			tcategory = JSONBTYPE_NULL;
			outfuncoid = InvalidOid;
		}
		else
			jsonb_categorize_type(att->atttypid, &tcategory, &outfuncoid);

		datum_to_jsonb(val, isnull, result, tcategory, outfuncoid, false);
	}

	result->res = pushJsonbValue(&result->parseState, WJB_END_OBJECT, NULL);
	ReleaseTupleDesc(tupdesc);
}

/*
 * Process a single dimension of an array.
 * If it's the innermost dimension, output the values, otherwise call
 * ourselves recursively to process the next dimension.
 */
static void
array_dim_to_jsonb(JsonbInState *result, int dim, int ndims, int *dims, Datum *vals,
				   bool *nulls, int *valcount, JsonbTypeCategory tcategory,
				   Oid outfuncoid)
{
	int			i;

	Assert(dim < ndims);

	result->res = pushJsonbValue(&result->parseState, WJB_BEGIN_ARRAY, NULL);

	for (i = 1; i <= dims[dim]; i++)
	{
		if (dim + 1 == ndims)
		{
			datum_to_jsonb(vals[*valcount], nulls[*valcount], result, tcategory,
						   outfuncoid, false);
			(*valcount)++;
		}
		else
		{
			array_dim_to_jsonb(result, dim + 1, ndims, dims, vals, nulls,
							   valcount, tcategory, outfuncoid);
		}
	}

	result->res = pushJsonbValue(&result->parseState, WJB_END_ARRAY, NULL);
}

/*
 * Turn an array into JSON.
 */
static void
array_to_jsonb_internal(Datum array, JsonbInState *result)
{
	ArrayType  *v = DatumGetArrayTypeP(array);
	Oid			element_type = ARR_ELEMTYPE(v);
	int		   *dim;
	int			ndim;
	int			nitems;
	int			count = 0;
	Datum	   *elements;
	bool	   *nulls;
	int16		typlen;
	bool		typbyval;
	char		typalign;
	JsonbTypeCategory tcategory;
	Oid			outfuncoid;

	ndim = ARR_NDIM(v);
	dim = ARR_DIMS(v);
	nitems = ArrayGetNItems(ndim, dim);

	if (nitems <= 0)
	{
		result->res = pushJsonbValue(&result->parseState, WJB_BEGIN_ARRAY, NULL);
		result->res = pushJsonbValue(&result->parseState, WJB_END_ARRAY, NULL);
		return;
	}

	get_typlenbyvalalign(element_type,
						 &typlen, &typbyval, &typalign);

	jsonb_categorize_type(element_type,
						  &tcategory, &outfuncoid);

	deconstruct_array(v, element_type, typlen, typbyval,
					  typalign, &elements, &nulls,
					  &nitems);

	array_dim_to_jsonb(result, 0, ndim, dim, elements, nulls, &count, tcategory,
					   outfuncoid);

	pfree(elements);
	pfree(nulls);
}

/*
 * Turn a Datum into jsonb, adding it to the result JsonbInState.
 *
 * tcategory and outfuncoid are from a previous call to json_categorize_type,
 * except that if is_null is true then they can be invalid.
 *
 * If key_scalar is true, the value is stored as a key, so insist
 * it's of an acceptable type, and force it to be a jbvString.
 *
 * Note: currently, we assume that result->escontext is NULL and errors
 * will be thrown.
 */
static void
datum_to_jsonb(Datum val, bool is_null, JsonbInState *result,
			   JsonbTypeCategory tcategory, Oid outfuncoid,
			   bool key_scalar)
{
	char	   *outputstr;
	bool		numeric_error;
	JsonbValue	jb;
	bool		scalar_jsonb = false;

	check_stack_depth();

	/* Convert val to a JsonbValue in jb (in most cases) */
	if (is_null)
	{
		Assert(!key_scalar);
		jb.type = jbvNull;
	}
	else if (key_scalar &&
			 (tcategory == JSONBTYPE_ARRAY ||
			  tcategory == JSONBTYPE_COMPOSITE ||
			  tcategory == JSONBTYPE_JSON ||
			  tcategory == JSONBTYPE_JSONB ||
			  tcategory == JSONBTYPE_JSONCAST))
	{
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("key value must be scalar, not array, composite, or json")));
	}
	else
	{
		if (tcategory == JSONBTYPE_JSONCAST)
			val = OidFunctionCall1(outfuncoid, val);

		switch (tcategory)
		{
			case JSONBTYPE_ARRAY:
				array_to_jsonb_internal(val, result);
				break;
			case JSONBTYPE_COMPOSITE:
				composite_to_jsonb(val, result);
				break;
			case JSONBTYPE_BOOL:
				if (key_scalar)
				{
					outputstr = DatumGetBool(val) ? "true" : "false";
					jb.type = jbvString;
					jb.val.string.len = strlen(outputstr);
					jb.val.string.val = outputstr;
				}
				else
				{
					jb.type = jbvBool;
					jb.val.boolean = DatumGetBool(val);
				}
				break;
			case JSONBTYPE_NUMERIC:
				outputstr = OidOutputFunctionCall(outfuncoid, val);
				if (key_scalar)
				{
					/* always quote keys */
					jb.type = jbvString;
					jb.val.string.len = strlen(outputstr);
					jb.val.string.val = outputstr;
				}
				else
				{
					/*
					 * Make it numeric if it's a valid JSON number, otherwise
					 * a string. Invalid numeric output will always have an
					 * 'N' or 'n' in it (I think).
					 */
					numeric_error = (strchr(outputstr, 'N') != NULL ||
									 strchr(outputstr, 'n') != NULL);
					if (!numeric_error)
					{
						Datum		numd;

						jb.type = jbvNumeric;
						numd = DirectFunctionCall3(numeric_in,
												   CStringGetDatum(outputstr),
												   ObjectIdGetDatum(InvalidOid),
												   Int32GetDatum(-1));
						jb.val.numeric = DatumGetNumeric(numd);
						pfree(outputstr);
					}
					else
					{
						jb.type = jbvString;
						jb.val.string.len = strlen(outputstr);
						jb.val.string.val = outputstr;
					}
				}
				break;
			case JSONBTYPE_DATE:
				jb.type = jbvString;
				jb.val.string.val = JsonEncodeDateTime(NULL, val,
													   DATEOID, NULL);
				jb.val.string.len = strlen(jb.val.string.val);
				break;
			case JSONBTYPE_TIMESTAMP:
				jb.type = jbvString;
				jb.val.string.val = JsonEncodeDateTime(NULL, val,
													   TIMESTAMPOID, NULL);
				jb.val.string.len = strlen(jb.val.string.val);
				break;
			case JSONBTYPE_TIMESTAMPTZ:
				jb.type = jbvString;
				jb.val.string.val = JsonEncodeDateTime(NULL, val,
													   TIMESTAMPTZOID, NULL);
				jb.val.string.len = strlen(jb.val.string.val);
				break;
			case JSONBTYPE_JSONCAST:
			case JSONBTYPE_JSON:
				{
					/* parse the json right into the existing result object */
					JsonLexContext *lex;
					JsonSemAction sem;
					text	   *json = DatumGetTextPP(val);

					lex = makeJsonLexContext(json, true);

					memset(&sem, 0, sizeof(sem));

					sem.semstate = (void *) result;

					sem.object_start = jsonb_in_object_start;
					sem.array_start = jsonb_in_array_start;
					sem.object_end = jsonb_in_object_end;
					sem.array_end = jsonb_in_array_end;
					sem.scalar = jsonb_in_scalar;
					sem.object_field_start = jsonb_in_object_field_start;

					pg_parse_json_or_ereport(lex, &sem);
				}
				break;
			case JSONBTYPE_JSONB:
				{
					Jsonb	   *jsonb = DatumGetJsonbP(val);
					JsonbIterator *it;

					it = JsonbIteratorInit(&jsonb->root);

					if (JB_ROOT_IS_SCALAR(jsonb))
					{
						(void) JsonbIteratorNext(&it, &jb, true);
						Assert(jb.type == jbvArray);
						(void) JsonbIteratorNext(&it, &jb, true);
						scalar_jsonb = true;
					}
					else
					{
						JsonbIteratorToken type;

						while ((type = JsonbIteratorNext(&it, &jb, false))
							   != WJB_DONE)
						{
							if (type == WJB_END_ARRAY || type == WJB_END_OBJECT ||
								type == WJB_BEGIN_ARRAY || type == WJB_BEGIN_OBJECT)
								result->res = pushJsonbValue(&result->parseState,
															 type, NULL);
							else
								result->res = pushJsonbValue(&result->parseState,
															 type, &jb);
						}
					}
				}
				break;
			default:
				outputstr = OidOutputFunctionCall(outfuncoid, val);
				jb.type = jbvString;
				jb.val.string.len = strlen(outputstr);
				(void) checkStringLen(jb.val.string.len, NULL);
				jb.val.string.val = outputstr;
				break;
		}
	}

	/* Now insert jb into result, unless we did it recursively */
	if (!is_null && !scalar_jsonb &&
		tcategory >= JSONBTYPE_JSON && tcategory <= JSONBTYPE_JSONCAST)
	{
		/* work has been done recursively */
		return;
	}
	else if (result->parseState == NULL)
	{
		/* single root scalar */
		JsonbValue	va;

		va.type = jbvArray;
		va.val.array.rawScalar = true;
		va.val.array.nElems = 1;

		result->res = pushJsonbValue(&result->parseState, WJB_BEGIN_ARRAY, &va);
		result->res = pushJsonbValue(&result->parseState, WJB_ELEM, &jb);
		result->res = pushJsonbValue(&result->parseState, WJB_END_ARRAY, NULL);
	}
	else
	{
		JsonbValue *o = &result->parseState->contVal;

		switch (o->type)
		{
			case jbvArray:
				result->res = pushJsonbValue(&result->parseState, WJB_ELEM, &jb);
				break;
			case jbvObject:
				result->res = pushJsonbValue(&result->parseState,
											 key_scalar ? WJB_KEY : WJB_VALUE,
											 &jb);
				break;
			default:
				elog(ERROR, "unexpected parent of nested structure");
		}
	}
}

Jsonb *
spock_tuple_data_to_jsonb(SpockTupleData *tuple, TupleDesc tupleDesc)
{
	JsonbParseState *state = NULL;
	JsonbValue *jval,
				val;
	JsonbTypeCategory tcategory;
	JsonbInState result;
	Jsonb	   *jsonb_val;
	int			natts = tupleDesc->natts;
	Datum		attr;
	bool		isNull;
	int			natt;
	bool		first = true;
	static const int MAX_CONFLICT_LOG_ATTR_LEN = 40;

	/* Start building the JSON object */
	(void) pushJsonbValue(&state, WJB_BEGIN_OBJECT, NULL);

	/* print all columns individually */
	for (natt = 0; natt < tupleDesc->natts; natt++)
	{
		Form_pg_attribute attr; /* the attribute itself */
		Oid			typid;		/* type of current attribute */
		HeapTuple	type_tuple; /* information about a type */
		Form_pg_type type_form;
		Oid			typoutput;	/* output function */
		bool		typisvarlena;
		Datum		origval = PointerGetDatum(NULL);	/* possibly toasted
														 * Datum */
		Datum		datumval = PointerGetDatum(NULL);	/* definitely detoasted
														 * Datum */
		char	   *outputstr = NULL;
		bool		isnull = false; /* column is null? */

		attr = TupleDescAttr(tupleDesc, natt);

		/*
		 * don't print dropped columns, we can't be sure everything is
		 * available for them
		 */
		if (attr->attisdropped)
			continue;

		/*
		 * Don't print system columns
		 */
		if (attr->attnum < 0)
			continue;
		
		/* Skip over hidden columns 
		 * TODO: Using get_attribute_options fails here because the realtion 
		 * is a SpockTuple and not a HeapTuple.
		 * Use a better method than this temporary fix here */
		if (strncmp(NameStr(attr->attname), "_Spock", 6) == 0)
			continue;
		
		typid = attr->atttypid;

		/* gather type name */
		type_tuple = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typid));

		if (!HeapTupleIsValid(type_tuple))
			elog(ERROR, "cache lookup failed for type %u", typid);

		type_form = (Form_pg_type) GETSTRUCT(type_tuple);

		/* query output function */
		getTypeOutputInfo(typid,
						  &typoutput, &typisvarlena);

		ReleaseSysCache(type_tuple);

		val.type = jbvString;
		val.val.string.val = NameStr(attr->attname);
		val.val.string.len = strlen(val.val.string.val);

		elog(DEBUG1, "SpockErrorLog: Added attribute name to JSON object: %s", val.val.string.val);
		/* Key for JSON object */
		(void) pushJsonbValue(&state, WJB_KEY, &val);

		memset(&result, 0, sizeof(JsonbInState));

		if (tuple->nulls[natt])
			isnull = true;
		else
			origval = tuple->values[natt];

		if (typisvarlena && VARATT_IS_EXTERNAL_ONDISK(origval))
			outputstr = "(unchanged-toast-datum)";
		else if (typisvarlena)
			datumval = PointerGetDatum(PG_DETOAST_DATUM(origval));
		else
			datumval = origval;

		if (outputstr != NULL)
			datumval = PointerGetDatum(cstring_to_text(outputstr));

		jsonb_categorize_type(typid, &tcategory, &typoutput);
		elog(DEBUG1, "SpockErrorLog: Category of type: %d", tcategory);

		/* Value for JSON object */
		datum_to_jsonb(datumval, isnull, &state, tcategory, typoutput, false);

		elog(DEBUG1, "SpockErrorLog: Converted datum to JSON object");

		//(void) pushJsonbValue(&state, WJB_VALUE, result.res);

	}

	/* End the JSON object */
	jval = pushJsonbValue(&state, WJB_END_OBJECT, NULL);

	/* Convert JsonbValue to Jsonb */
	return JsonbValueToJsonb(jval);
}
