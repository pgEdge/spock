/*-------------------------------------------------------------------------
 *
 * spock_quorum_etcd.c
 *		Quorum provider backed by an external etcd daemon.
 *
 * etcd runs as its own daemon, so this provider is a client: it speaks the
 * v3 HTTP/JSON gateway, which keeps the dependency to an HTTP library rather
 * than a gRPC stack.  The whole file is guarded by SPOCK_HAVE_LIBCURL; a build
 * without it still compiles and still offers the provider, which then
 * reports why it cannot be used.  Selecting a provider you did not build is
 * a configuration mistake, not a reason to fail to start.
 *
 * Liveness model.  etcd's own member list describes etcd, not Spock, so it
 * cannot answer "is node n3 up".  Instead each Spock node registers itself
 * under a prefix with a lease and renews that lease on every refresh():
 *
 *		<cluster_id>/nodes/<node_name>  ->  <node_name>   (lease TTL)
 *		<cluster_id>/leader             ->  <node_name>   (lease TTL)
 *
 * A node that stops renewing has its keys expired by etcd, so presence under
 * the prefix *is* liveness, judged by the cluster rather than by whichever
 * node happens to be asking.  That is the property Spock cannot get locally
 * and the reason for the whole layer.
 *
 * The gateway is spoken to without authentication or TLS.  Point the
 * endpoints at a local proxy if the etcd cluster requires either.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "common/base64.h"
#include "lib/stringinfo.h"
#include "parser/scansup.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/timestamp.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_quorum.h"

#ifdef SPOCK_HAVE_LIBCURL
#include <curl/curl.h>
#endif

/*
 * Lease TTL, in seconds.  Must comfortably exceed the interval at which
 * refresh() is called, or a slow tick would expire our own registration and
 * make this node look dead to its peers.
 */
#define ETCD_LEASE_TTL_SECONDS	30

#define ETCD_NODES_INFIX		"/nodes/"
#define ETCD_LEADER_SUFFIX		"/leader"

#ifdef SPOCK_HAVE_LIBCURL

static bool curl_initialized = false;
static int64 etcd_lease_id = 0;
static char *etcd_self_name = NULL;

/*
 * Split a comma-separated endpoint list.
 *
 * Deliberately not SplitIdentifierString(): that downcases unquoted text and
 * truncates each element to NAMEDATALEN, both of which silently corrupt a
 * URL.  Endpoints are opaque strings here, so only whitespace is trimmed.
 */
static List *
split_endpoints(const char *raw)
{
	List	   *result = NIL;
	char	   *copy = pstrdup(raw);
	char	   *cursor = copy;
	char	   *comma;

	for (;;)
	{
		char	   *item = cursor;
		char	   *tail;

		comma = strchr(cursor, ',');
		if (comma != NULL)
		{
			*comma = '\0';
			cursor = comma + 1;
		}

		while (*item != '\0' && scanner_isspace(*item))
			item++;
		tail = item + strnlen(item, MaxAllocSize);
		while (tail > item && scanner_isspace(*(tail - 1)))
			*(--tail) = '\0';

		if (*item != '\0')
			result = lappend(result, item);

		if (comma == NULL)
			break;
	}

	return result;
}

/* Accumulates a response body. */
static size_t
write_cb(void *contents, size_t size, size_t nmemb, void *userp)
{
	StringInfo	buf = (StringInfo) userp;
	size_t		total = size * nmemb;

	appendBinaryStringInfo(buf, (const char *) contents, (int) total);
	return total;
}

/*
 * POST a JSON body to etcd and return the response body, or NULL with
 * *errdetail set.
 *
 * Endpoints are tried in rotation, starting where the last call left off and
 * moving on when one cannot be reached, so a dead member costs a connection
 * attempt and not the answer.  The whole call shares one deadline: each
 * attempt gets what is left of spock.quorum_timeout, so a hung member cannot
 * stretch the call to one timeout per endpoint.
 */
static char *
etcd_post(const char *path, const char *body, char **errdetail)
{
	static int	endpoint_cursor = 0;
	List	   *endpoints;
	int			nendpoints;
	int			attempt;
	TimestampTz deadline;

	if (spock_quorum_etcd_endpoints == NULL ||
		spock_quorum_etcd_endpoints[0] == '\0')
	{
		*errdetail = pstrdup("spock.quorum_etcd_endpoints is not set");
		return NULL;
	}

	endpoints = split_endpoints(spock_quorum_etcd_endpoints);
	nendpoints = list_length(endpoints);
	if (nendpoints == 0)
	{
		*errdetail = pstrdup("spock.quorum_etcd_endpoints is malformed");
		return NULL;
	}

	deadline = TimestampTzPlusMilliseconds(GetCurrentTimestamp(),
										   spock_quorum_timeout);
	*errdetail = NULL;

	for (attempt = 0; attempt < nendpoints; attempt++)
	{
		const char *chosen = (const char *) list_nth(endpoints,
													 endpoint_cursor % nendpoints);
		CURL	   *curl;
		CURLcode	res;
		StringInfoData resp;
		StringInfoData url;
		struct curl_slist *headers = NULL;
		long		http_code = 0;
		long		remaining;

		remaining = (deadline - GetCurrentTimestamp()) / 1000;
		if (remaining < 1)
		{
			if (*errdetail == NULL)
				*errdetail = psprintf("etcd %s: no time left within %d ms",
									  chosen, spock_quorum_timeout);
			return NULL;
		}

		initStringInfo(&url);
		appendStringInfo(&url, "%s%s", chosen, path);

		curl = curl_easy_init();
		if (curl == NULL)
		{
			*errdetail = pstrdup("could not initialise HTTP client");
			return NULL;
		}

		initStringInfo(&resp);
		headers = curl_slist_append(headers, "Content-Type: application/json");

		curl_easy_setopt(curl, CURLOPT_URL, url.data);
		curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
		curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
		curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *) &resp);

		/*
		 * The deadline is the contract; without it a hung etcd hangs the
		 * tick.
		 */
		curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, remaining);
		curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, remaining);
		curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

		res = curl_easy_perform(curl);
		if (res == CURLE_OK)
			curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

		curl_slist_free_all(headers);
		curl_easy_cleanup(curl);

		if (res == CURLE_OK && http_code == 200)
			return resp.data;

		/*
		 * This endpoint is no good.  Remember why, move the cursor past it,
		 * and let the next attempt use what is left of the deadline.
		 */
		if (res != CURLE_OK)
			*errdetail = psprintf("etcd %s: %s", chosen, curl_easy_strerror(res));
		else
			*errdetail = psprintf("etcd %s returned HTTP %ld", chosen, http_code);
		endpoint_cursor++;
	}

	return NULL;
}

/*
 * Base64, as the v3 gateway requires for every key and value.  The buffer
 * arguments are declared char in older PostgreSQL releases and uint8 in
 * newer ones; void pointers convert to either.
 */
static char *
b64(const char *src)
{
	int			srclen = (int) strnlen(src, MaxAllocSize);
	int			maxlen = pg_b64_enc_len(srclen) + 1;
	char	   *dst = palloc(maxlen);
	int			len = pg_b64_encode((const void *) src, srclen, dst, maxlen - 1);

	if (len < 0)
		return pstrdup("");
	dst[len] = '\0';
	return dst;
}

static char *
unb64(const char *src)
{
	int			srclen = (int) strnlen(src, MaxAllocSize);
	int			maxlen = pg_b64_dec_len(srclen) + 1;
	char	   *dst = palloc(maxlen);
	int			len = pg_b64_decode(src, srclen, (void *) dst, maxlen - 1);

	if (len < 0)
		return pstrdup("");
	dst[len] = '\0';
	return dst;
}

/*
 * Parse a response body, returning NULL rather than throwing.
 *
 * etcd's replies are small and infrequent, so the server's own parser is
 * used rather than a hand-rolled scanner.  It has to be wrapped, though:
 * jsonb_in raises on malformed input, and a provider is contractually
 * forbidden from throwing.  An internal subtransaction, not a bare PG_TRY:
 * catching the error with FlushErrorState() alone would leave the
 * surrounding transaction aborted, and this runs inside whatever transaction
 * the operator called spock.quorum_status() from.
 */
static Jsonb *
parse_json(const char *json)
{
	volatile bool ok = true;
	Jsonb	   *volatile result = NULL;
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;

	if (json == NULL)
		return NULL;

	BeginInternalSubTransaction(NULL);

	PG_TRY();
	{
		result = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
													CStringGetDatum(json)));

		/* Copy out before the subtransaction that allocated it goes away. */
		MemoryContextSwitchTo(oldcxt);
		result = (Jsonb *) PG_DETOAST_DATUM_COPY(PointerGetDatum(result));

		ReleaseCurrentSubTransaction();
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldcxt);
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		ok = false;
	}
	PG_END_TRY();

	MemoryContextSwitchTo(oldcxt);
	CurrentResourceOwner = oldowner;

	return ok ? result : NULL;
}

/*
 * One scalar field of an object, as text, or NULL when absent.
 *
 * The container API is used in preference to jsonb_object_field_text
 * because DirectFunctionCall raises "function returned NULL" whenever the
 * field is missing, which for an optional field is the normal case, not an
 * error.
 */
static char *
jb_field(JsonbContainer *obj, const char *field)
{
	JsonbValue *v;

	if (obj == NULL || !JsonContainerIsObject(obj))
		return NULL;

	v = getKeyJsonValueFromContainer(obj, field,
									 (int) strnlen(field, NAMEDATALEN), NULL);
	if (v == NULL)
		return NULL;

	switch (v->type)
	{
		case jbvString:
			return pnstrdup(v->val.string.val, v->val.string.len);
		case jbvBool:
			return pstrdup(v->val.boolean ? "true" : "false");
		case jbvNumeric:
			return DatumGetCString(DirectFunctionCall1(numeric_out,
													   NumericGetDatum(v->val.numeric)));
		default:
			return NULL;
	}
}

/* One field of an object that is itself an object or an array, or NULL. */
static JsonbContainer *
jb_container(JsonbContainer *obj, const char *field)
{
	JsonbValue *v;

	if (obj == NULL || !JsonContainerIsObject(obj))
		return NULL;

	v = getKeyJsonValueFromContainer(obj, field,
									 (int) strnlen(field, NAMEDATALEN), NULL);
	if (v == NULL || v->type != jbvBinary)
		return NULL;
	return v->val.binary.data;
}

/* The i'th element of an array, if it is an object or an array, or NULL. */
static JsonbContainer *
jb_element(JsonbContainer *arr, int i)
{
	JsonbValue *v;

	if (arr == NULL || !JsonContainerIsArray(arr))
		return NULL;

	v = getIthJsonbValueFromContainer(arr, (uint32) i);
	if (v == NULL || v->type != jbvBinary)
		return NULL;
	return v->val.binary.data;
}

/* Convenience for the common "parse, then take one top-level field" shape. */
static char *
json_field(const char *json, const char *field)
{
	Jsonb	   *jb = parse_json(json);

	return jb ? jb_field(&jb->root, field) : NULL;
}

/* One string field of the i'th kv of a "kvs" array, base64-decoded. */
static char *
kv_field(JsonbContainer *kvs, int i, const char *field)
{
	char	   *raw = jb_field(jb_element(kvs, i), field);

	return raw ? unb64(raw) : NULL;
}

/* Number of elements of an array container, 0 for anything else. */
static int
jb_count(JsonbContainer *arr)
{
	if (arr == NULL || !JsonContainerIsArray(arr))
		return 0;
	return (int) JsonContainerSize(arr);
}

/* The prefix under which this cluster's nodes register. */
static char *
nodes_prefix(void)
{
	return psprintf("%s%s", spock_quorum_cluster_id, ETCD_NODES_INFIX);
}

static char *
leader_key(void)
{
	return psprintf("%s%s", spock_quorum_cluster_id, ETCD_LEADER_SUFFIX);
}

/*
 * range_end for a prefix scan is the prefix with its last byte incremented,
 * which is how etcd expresses "everything under this prefix".
 */
static char *
prefix_end(const char *prefix)
{
	char	   *end = pstrdup(prefix);
	int			len = (int) strnlen(end, MaxAllocSize);

	if (len > 0)
		end[len - 1]++;
	return end;
}

static bool
etcd_grant_lease(char **errdetail)
{
	char	   *body = psprintf("{\"TTL\":\"%d\"}", ETCD_LEASE_TTL_SECONDS);
	char	   *resp = etcd_post("/v3/lease/grant", body, errdetail);
	char	   *id;

	if (resp == NULL)
		return false;

	id = json_field(resp, "ID");
	if (id == NULL)
	{
		*errdetail = pstrdup("etcd lease grant returned no ID");
		return false;
	}

	etcd_lease_id = strtoll(id, NULL, 10);
	if (etcd_lease_id == 0)
	{
		*errdetail = pstrdup("etcd lease grant returned a zero ID");
		return false;
	}
	return true;
}

/* Register (or re-register) this node under the nodes prefix. */
static bool
etcd_put_self(char **errdetail)
{
	char	   *key = psprintf("%s%s", nodes_prefix(), etcd_self_name);
	char	   *body = psprintf("{\"key\":\"%s\",\"value\":\"%s\",\"lease\":\"%lld\"}",
								b64(key), b64(etcd_self_name),
								(long long) etcd_lease_id);

	return etcd_post("/v3/kv/put", body, errdetail) != NULL;
}

/*
 * Campaign for leadership by create-if-absent on a leased key.  The txn
 * compares the key's create_revision against 0, which is etcd's idiom for
 * "does not exist", so exactly one node can win.  The lease means a leader
 * that dies releases the key without anyone having to notice and intervene.
 * Whether we hold it is learnt by read(), which is the only place answers
 * come from.
 */
static bool
etcd_campaign(char **errdetail)
{
	char	   *kb = b64(leader_key());
	char	   *body = psprintf("{\"compare\":[{\"key\":\"%s\",\"target\":\"CREATE\","
								"\"result\":\"EQUAL\",\"create_revision\":\"0\"}],"
								"\"success\":[{\"request_put\":{\"key\":\"%s\","
								"\"value\":\"%s\",\"lease\":\"%lld\"}}],"
								"\"failure\":[]}",
								kb, kb, b64(etcd_self_name),
								(long long) etcd_lease_id);

	return etcd_post("/v3/kv/txn", body, errdetail) != NULL;
}

/*
 * The TTL a keepalive reply grants.  The gateway wraps the streaming RPC's
 * reply in a "result" object; an unwrapped reply is accepted too.  Returns
 * 0 when the lease is gone or the reply is not understood.
 */
static long long
etcd_keepalive_ttl(const char *resp)
{
	Jsonb	   *jb = parse_json(resp);
	char	   *ttl;

	if (jb == NULL)
		return 0;

	ttl = jb_field(jb_container(&jb->root, "result"), "TTL");
	if (ttl == NULL)
		ttl = jb_field(&jb->root, "TTL");
	if (ttl == NULL)
		return 0;
	return strtoll(ttl, NULL, 10);
}

/* --- provider entry points -------------------------------------------- */

/*
 * Startup deliberately touches neither etcd nor a lease.
 *
 * Registration is owned by the single long-lived worker that calls
 * refresh(); an ordinary backend asking spock.quorum_status() must be able
 * to read the cluster's view without minting a lease of its own and
 * registering this node a second time.  So startup only resolves identity,
 * and everything with a side effect lives in refresh().
 */
static bool
etcd_startup(char **errdetail)
{
	SpockLocalNode *local;
	MemoryContext old;

	if (!curl_initialized)
	{
		curl_global_init(CURL_GLOBAL_DEFAULT);
		curl_initialized = true;
	}

	local = get_local_node(false, true);
	if (local == NULL)
	{
		*errdetail = pstrdup("no local spock node");
		return false;
	}

	if (etcd_self_name != NULL)
		pfree(etcd_self_name);
	old = MemoryContextSwitchTo(TopMemoryContext);
	etcd_self_name = pstrdup(local->node->name);
	MemoryContextSwitchTo(old);

	return true;
}

static void
etcd_shutdown(void)
{
	char	   *detail = NULL;

	/*
	 * Revoke rather than waiting for the TTL, so a clean shutdown is visible
	 * to peers immediately instead of looking like a node that died.
	 */
	if (etcd_lease_id != 0)
	{
		char	   *body = psprintf("{\"ID\":\"%lld\"}", (long long) etcd_lease_id);

		(void) etcd_post("/v3/lease/revoke", body, &detail);
		etcd_lease_id = 0;
	}
}

/*
 * Renew the lease, re-register, and campaign.  If the lease has expired, a
 * long stall or etcd unreachable for longer than the TTL, grant a fresh one
 * rather than silently continuing to look dead to every peer.
 */
static bool
etcd_refresh(char **errdetail)
{
	if (etcd_lease_id != 0)
	{
		char	   *body = psprintf("{\"ID\":\"%lld\"}", (long long) etcd_lease_id);
		char	   *resp = etcd_post("/v3/lease/keepalive", body, errdetail);

		if (resp == NULL)
			return false;
		if (etcd_keepalive_ttl(resp) <= 0)
			etcd_lease_id = 0;
	}

	if (etcd_lease_id == 0 && !etcd_grant_lease(errdetail))
		return false;

	/*
	 * Register on every refresh, not only on a fresh lease.  The put is
	 * idempotent, and a key removed by hand or by compaction while the lease
	 * lived on would otherwise stay gone, with peers reading this node as
	 * dead for as long as the lease kept being renewed.
	 */
	if (!etcd_put_self(errdetail))
		return false;

	return etcd_campaign(errdetail);
}

/*
 * One reading, from one transaction.
 *
 * A txn is linearizable: etcd only answers it from within a majority, so a
 * successful reply is itself the proof of quorum.  /v3/maintenance/status
 * is deliberately NOT used for that: the Status RPC is answered from the
 * queried member's own state, so a member isolated in a minority partition
 * happily reports the leader it last knew about.
 *
 * A minority member cannot complete the txn, so the call runs out its
 * deadline and the answer is UNKNOWN rather than NO.  Both are handled
 * identically by the caller; UNKNOWN is simply the truthful one, because
 * etcd never got far enough to say no.
 *
 * The txn reads the nodes prefix and the leader key together, so the
 * membership and the leader come from one revision.
 */
static bool
etcd_read(SpockQuorumReading *reading, char **errdetail)
{
	char	   *prefix = nodes_prefix();
	char	   *ops;
	char	   *body;
	char	   *resp;
	Jsonb	   *jb;
	JsonbContainer *responses;
	JsonbContainer *kvs;
	int			count;
	int			i;

	ops = psprintf("{\"request_range\":{\"key\":\"%s\",\"range_end\":\"%s\"}},"
				   "{\"request_range\":{\"key\":\"%s\"}}",
				   b64(prefix), b64(prefix_end(prefix)), b64(leader_key()));
	body = psprintf("{\"compare\":[{\"key\":\"%s\",\"target\":\"VERSION\","
					"\"result\":\"GREATER\",\"version\":\"0\"}],"
					"\"success\":[%s],\"failure\":[%s]}",
					b64(prefix), ops, ops);

	resp = etcd_post("/v3/kv/txn", body, errdetail);
	if (resp == NULL)
		return false;

	jb = parse_json(resp);
	responses = jb ? jb_container(&jb->root, "responses") : NULL;
	if (jb_count(responses) < 2)
	{
		*errdetail = pstrdup("etcd transaction reply has an unexpected shape");
		return false;
	}

	reading->quorum = SPOCK_QUORUM_YES;
	reading->members = NIL;

	/*
	 * Presence under the prefix is liveness: etcd drops the key when its
	 * owner's lease lapses, so anything still here renewed recently.  etcd
	 * does not say when, so last_seen stays 0.
	 */
	kvs = jb_container(jb_container(jb_element(responses, 0), "response_range"), "kvs");
	count = jb_count(kvs);
	for (i = 0; i < count; i++)
	{
		char	   *key = kv_field(kvs, i, "key");
		char	   *name;
		SpockQuorumMember *m;

		if (key == NULL)
			continue;

		/* The node name is the last path element of the key. */
		name = strrchr(key, '/');
		name = (name != NULL) ? name + 1 : key;
		if (*name == '\0')
			continue;

		m = palloc0(sizeof(SpockQuorumMember));
		m->name = pstrdup(name);
		m->live = true;
		m->voting = true;
		m->last_seen = 0;
		reading->members = lappend(reading->members, m);
	}

	kvs = jb_container(jb_container(jb_element(responses, 1), "response_range"), "kvs");
	reading->leader_name = jb_count(kvs) > 0 ? kv_field(kvs, 0, "value") : NULL;

	/*
	 * startup() leaves the identity unset when there is no local node, and
	 * without an identity there is no question to answer.
	 */
	if (etcd_self_name == NULL)
		reading->leader = SPOCK_QUORUM_UNKNOWN;
	else if (reading->leader_name != NULL &&
			 strcmp(reading->leader_name, etcd_self_name) == 0)
		reading->leader = SPOCK_QUORUM_YES;
	else
		reading->leader = SPOCK_QUORUM_NO;

	return true;
}

#else							/* !SPOCK_HAVE_LIBCURL */

/*
 * Built without an HTTP client.  The provider still exists so that selecting
 * it produces a clear explanation instead of a mysterious silence, and so
 * that it degrades to exactly the conservative behaviour of 'none'.
 */
static const char *
etcd_unavailable(void)
{
	return "this build of Spock has no HTTP client, so the etcd provider is unavailable";
}

static bool
etcd_startup(char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return false;
}

static void
etcd_shutdown(void)
{
}

static bool
etcd_refresh(char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return false;
}

static bool
etcd_read(SpockQuorumReading *reading, char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return false;
}

#endif							/* SPOCK_HAVE_LIBCURL */

const SpockQuorumProvider spock_quorum_provider_etcd = {
	.name = "etcd",
	.startup = etcd_startup,
	.shutdown = etcd_shutdown,
	.refresh = etcd_refresh,
	.read = etcd_read
};
