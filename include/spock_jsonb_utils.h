#include <postgres.h>
#include <catalog/pg_type.h>
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/jsonfuncs.h"

#include "spock_proto_native.h"

typedef enum					/* type categories for datum_to_jsonb */
{
	JSONBTYPE_NULL,				/* null, so we didn't bother to identify */
	JSONBTYPE_BOOL,				/* boolean (built-in types only) */
	JSONBTYPE_NUMERIC,			/* numeric (ditto) */
	JSONBTYPE_DATE,				/* we use special formatting for datetimes */
	JSONBTYPE_TIMESTAMP,		/* we use special formatting for timestamp */
	JSONBTYPE_TIMESTAMPTZ,		/* ... and timestamptz */
	JSONBTYPE_JSON,				/* JSON */
	JSONBTYPE_JSONB,			/* JSONB */
	JSONBTYPE_ARRAY,			/* array */
	JSONBTYPE_COMPOSITE,		/* composite */
	JSONBTYPE_JSONCAST,			/* something with an explicit cast to JSON */
	JSONBTYPE_OTHER				/* all else */
} JsonbTypeCategory;

typedef struct JsonbInState
{
	JsonbParseState *parseState;
	JsonbValue *res;
	Node	   *escontext;
} JsonbInState;

extern char *spock_tuple_to_json_cstring(SpockTupleData *tuple,
										 TupleDesc tupdesc);
extern char *heap_tuple_to_json_cstring(HeapTuple *tuple, TupleDesc tupdesc);
