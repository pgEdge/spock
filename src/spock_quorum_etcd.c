/*-------------------------------------------------------------------------
 *
 * spock_quorum_etcd.c
 *		Quorum provider backed by an external etcd daemon.
 *
 * etcd runs as its own daemon, so this provider is a client: it speaks the
 * v3 HTTP/JSON gateway, which keeps the dependency to an HTTP library rather
 * than a gRPC stack.  The whole file is guarded by HAVE_LIBCURL; a build
 * without it still compiles and still offers the provider, which then
 * reports why it cannot be used.  Selecting a provider you did not build is
 * a configuration mistake, not a reason to fail to start.
 *
 * Liveness model.  etcd's own member list describes etcd, not Spock, so it
 * cannot answer "is node n3 up".  Instead each Spock node registers itself
 * under a prefix with a lease and renews that lease every tick:
 *
 *		<cluster_id>/nodes/<node_name>  ->  <node_name>   (lease TTL)
 *
 * A node that stops renewing has its key expired by etcd, so presence under
 * the prefix *is* liveness, judged by the cluster rather than by whichever
 * node happens to be asking.  That is the property Spock cannot get locally
 * and the reason for the whole layer.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "common/base64.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "parser/scansup.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_quorum.h"

#ifdef HAVE_LIBCURL
#include <curl/curl.h>
#endif

/*
 * Lease TTL, in seconds.  Must comfortably exceed the worker interval or a
 * slow tick would expire our own registration and make this node look dead
 * to its peers.  Six times the default 5s tick leaves room for a stalled
 * tick or two before anyone draws conclusions.
 */
#define ETCD_LEASE_TTL_SECONDS	30

#define ETCD_NODES_INFIX		"/nodes/"
#define ETCD_LEADER_SUFFIX		"/leader"

#ifdef HAVE_LIBCURL

static bool curl_initialized = false;
static int64 etcd_lease_id = 0;
static char *etcd_self_name = NULL;

static char *etcd_leader_name(char **errdetail);

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
		tail = item + strlen(item);
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
 * POST a JSON body to one etcd endpoint and return the response body, or
 * NULL with *errdetail set.
 *
 * Only the first endpoint in spock.quorum_etcd_endpoints is tried per call,
 * rotating on failure, so a dead etcd member costs one tick rather than
 * making every tick pay for the retry.
 */
static char *
etcd_post(const char *path, const char *body, char **errdetail)
{
	static int	endpoint_cursor = 0;
	CURL	   *curl;
	CURLcode	res;
	StringInfoData resp;
	StringInfoData url;
	struct curl_slist *headers = NULL;
	long		http_code = 0;
	List	   *endpoints;
	ListCell   *lc;
	int			n = 0;
	char	   *chosen = NULL;

	if (spock_quorum_etcd_endpoints == NULL ||
		spock_quorum_etcd_endpoints[0] == '\0')
	{
		*errdetail = pstrdup("spock.quorum_etcd_endpoints is not set");
		return NULL;
	}

	endpoints = split_endpoints(spock_quorum_etcd_endpoints);
	if (endpoints == NIL)
	{
		*errdetail = pstrdup("spock.quorum_etcd_endpoints is malformed");
		return NULL;
	}

	foreach(lc, endpoints)
	{
		if (n == (endpoint_cursor % list_length(endpoints)))
			chosen = (char *) lfirst(lc);
		n++;
	}
	if (chosen == NULL)
		chosen = (char *) linitial(endpoints);

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
	/* The deadline is the contract; without it a hung etcd hangs the tick. */
	curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long) spock_quorum_timeout);
	curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, (long) spock_quorum_timeout);
	curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

	res = curl_easy_perform(curl);
	if (res == CURLE_OK)
		curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

	curl_slist_free_all(headers);
	curl_easy_cleanup(curl);

	if (res != CURLE_OK)
	{
		endpoint_cursor++;
		*errdetail = psprintf("etcd %s: %s", chosen, curl_easy_strerror(res));
		return NULL;
	}
	if (http_code != 200)
	{
		endpoint_cursor++;
		*errdetail = psprintf("etcd %s returned HTTP %ld", chosen, http_code);
		return NULL;
	}

	return resp.data;
}

/* Base64, as the v3 gateway requires for every key and value. */
static char *
b64(const char *src)
{
	int			srclen = (int) strlen(src);
	int			maxlen = pg_b64_enc_len(srclen) + 1;
	char	   *dst = palloc(maxlen);
	int			len = pg_b64_encode((const uint8 *) src, srclen, dst, maxlen - 1);

	if (len < 0)
		return pstrdup("");
	dst[len] = '\0';
	return dst;
}

static char *
unb64(const char *src)
{
	int			srclen = (int) strlen(src);
	int			maxlen = pg_b64_dec_len(srclen) + 1;
	char	   *dst = palloc(maxlen);
	int			len = pg_b64_decode(src, srclen, (uint8 *) dst, maxlen - 1);

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
 * forbidden from throwing.  `ok` is volatile because it is written in the
 * handler and read after PG_END_TRY.
 */
static Jsonb *
parse_json(const char *json)
{
	volatile bool ok = true;
	Jsonb	   *result = NULL;

	if (json == NULL)
		return NULL;

	PG_TRY();
	{
		result = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
													CStringGetDatum(json)));
	}
	PG_CATCH();
	{
		FlushErrorState();
		ok = false;
	}
	PG_END_TRY();

	return ok ? result : NULL;
}

/*
 * One top-level field, as text, or NULL when absent.
 *
 * The container API is used in preference to jsonb_object_field_text
 * because DirectFunctionCall raises "function returned NULL" whenever the
 * field is missing -- which for an optional field is the normal case, not
 * an error.
 */
static char *
jb_field(Jsonb *jb, const char *field)
{
	JsonbValue *v;

	if (jb == NULL)
		return NULL;

	v = getKeyJsonValueFromContainer(&jb->root, field, (int) strlen(field),
									 NULL);
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

/* Convenience for the common "parse, then take one field" shape. */
static char *
json_field(const char *json, const char *field)
{
	return jb_field(parse_json(json), field);
}

/* The prefix under which this cluster's nodes register. */
static char *
nodes_prefix(void)
{
	return psprintf("%s%s", spock_quorum_cluster_id, ETCD_NODES_INFIX);
}

/*
 * range_end for a prefix scan is the prefix with its last byte incremented,
 * which is how etcd expresses "everything under this prefix".
 */
static char *
prefix_end(const char *prefix)
{
	char	   *end = pstrdup(prefix);
	int			len = (int) strlen(end);

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
	return etcd_lease_id != 0;
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
 * Renew the lease.  If it has already expired -- a long stall, or etcd was
 * unreachable for longer than the TTL -- grant a fresh one and re-register,
 * rather than silently continuing to look dead to every peer.
 */
static bool
etcd_refresh(char **errdetail)
{
	char	   *body;
	char	   *resp;
	char	   *ttl;

	if (etcd_lease_id == 0)
		return etcd_grant_lease(errdetail) && etcd_put_self(errdetail);

	body = psprintf("{\"ID\":\"%lld\"}", (long long) etcd_lease_id);
	resp = etcd_post("/v3/lease/keepalive", body, errdetail);
	if (resp == NULL)
		return false;

	ttl = json_field(resp, "TTL");
	if (ttl == NULL || strtoll(ttl, NULL, 10) <= 0)
	{
		etcd_lease_id = 0;
		return etcd_grant_lease(errdetail) && etcd_put_self(errdetail);
	}
	return true;
}

/*
 * etcd only answers a linearizable read when it has quorum, so a successful
 * status call that names a leader is itself the proof.  There is no separate
 * question to ask.
 */
static SpockQuorumAnswer
etcd_have_quorum(char **errdetail)
{
	char	   *resp = etcd_post("/v3/maintenance/status", "{}", errdetail);
	char	   *leader;

	if (resp == NULL)
		return SPOCK_QUORUM_UNKNOWN;

	leader = json_field(resp, "leader");
	if (leader == NULL)
		return SPOCK_QUORUM_UNKNOWN;

	/* etcd reports leader "0" precisely when it has none. */
	return strcmp(leader, "0") == 0 ? SPOCK_QUORUM_NO : SPOCK_QUORUM_YES;
}

/*
 * Pull the "kvs" array out of a range response.  Returns the container and
 * its length, or NULL when the key is absent -- which etcd uses to mean "no
 * matches", not an error.
 */
static JsonbContainer *
kvs_array(const char *resp, int *count, char **errdetail)
{
	Jsonb	   *jb = parse_json(resp);
	JsonbValue *kvs;

	*count = 0;
	if (jb == NULL)
	{
		*errdetail = pstrdup("etcd returned unparseable JSON");
		return NULL;
	}

	kvs = getKeyJsonValueFromContainer(&jb->root, "kvs", 3, NULL);
	if (kvs == NULL || kvs->type != jbvBinary)
		return NULL;			/* no key matched */

	*count = (int) JsonContainerSize(kvs->val.binary.data);
	return kvs->val.binary.data;
}

/* One string field of the i'th array element, base64-decoded. */
static char *
kv_field(JsonbContainer *arr, int i, const char *field)
{
	JsonbValue *elem = getIthJsonbValueFromContainer(arr, (uint32) i);
	JsonbValue *v;

	if (elem == NULL || elem->type != jbvBinary)
		return NULL;

	v = getKeyJsonValueFromContainer(elem->val.binary.data, field,
									 (int) strlen(field), NULL);
	if (v == NULL || v->type != jbvString)
		return NULL;

	return unb64(pnstrdup(v->val.string.val, v->val.string.len));
}

static List *
etcd_members(char **errdetail)
{
	char	   *prefix = nodes_prefix();
	char	   *body = psprintf("{\"key\":\"%s\",\"range_end\":\"%s\"}",
								b64(prefix), b64(prefix_end(prefix)));
	char	   *resp = etcd_post("/v3/kv/range", body, errdetail);
	JsonbContainer *arr;
	List	   *result = NIL;
	int			count;
	int			i;

	if (resp == NULL)
		return NIL;

	arr = kvs_array(resp, &count, errdetail);
	if (arr == NULL)
		return NIL;				/* nobody registered yet */

	for (i = 0; i < count; i++)
	{
		char	   *key = kv_field(arr, i, "key");
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

		/*
		 * Presence under the prefix is liveness: etcd drops the key when its
		 * owner's lease lapses, so anything still here renewed recently.
		 */
		m->live = true;
		m->voting = true;
		m->last_seen = GetCurrentTimestamp();
		result = lappend(result, m);
	}

	return result;
}

/*
 * Leadership by create-if-absent on a leased key.  The txn compares the
 * key's create_revision against 0, which is etcd's idiom for "does not
 * exist", so exactly one node can win.  The lease means a leader that dies
 * releases the key without anyone having to notice and intervene.
 */
static SpockQuorumAnswer
etcd_is_leader(char **errdetail)
{
	char	   *key = psprintf("%s%s", spock_quorum_cluster_id, ETCD_LEADER_SUFFIX);
	char	   *kb = b64(key);
	char	   *body;
	char	   *resp;
	char	   *succeeded;
	char	   *holder;

	/*
	 * Only the lease-owning worker campaigns.  A read-only backend answers by
	 * comparing the recorded holder, so asking the question can never change
	 * who leads.
	 */
	if (etcd_lease_id == 0)
	{
		char	   *who = etcd_leader_name(errdetail);

		if (who == NULL)
			return SPOCK_QUORUM_UNKNOWN;
		return strcmp(who, etcd_self_name) == 0
			? SPOCK_QUORUM_YES : SPOCK_QUORUM_NO;
	}

	body = psprintf("{\"compare\":[{\"key\":\"%s\",\"target\":\"CREATE\","
					"\"result\":\"EQUAL\",\"create_revision\":\"0\"}],"
					"\"success\":[{\"requestPut\":{\"key\":\"%s\","
					"\"value\":\"%s\",\"lease\":\"%lld\"}}],"
					"\"failure\":[{\"requestRange\":{\"key\":\"%s\"}}]}",
					kb, kb, b64(etcd_self_name), (long long) etcd_lease_id, kb);

	resp = etcd_post("/v3/kv/txn", body, errdetail);
	if (resp == NULL)
		return SPOCK_QUORUM_UNKNOWN;

	succeeded = json_field(resp, "succeeded");
	if (succeeded != NULL && strcmp(succeeded, "true") == 0)
		return SPOCK_QUORUM_YES;	/* we took it */

	/*
	 * Someone holds it.  It may still be us from an earlier tick, which is
	 * the common case, so compare rather than assuming we lost.
	 */
	holder = etcd_leader_name(errdetail);
	if (holder == NULL)
		return SPOCK_QUORUM_UNKNOWN;
	return strcmp(holder, etcd_self_name) == 0 ? SPOCK_QUORUM_YES : SPOCK_QUORUM_NO;
}

static char *
etcd_leader_name(char **errdetail)
{
	char	   *key = psprintf("%s%s", spock_quorum_cluster_id, ETCD_LEADER_SUFFIX);
	char	   *body = psprintf("{\"key\":\"%s\"}", b64(key));
	char	   *resp = etcd_post("/v3/kv/range", body, errdetail);
	JsonbContainer *arr;
	int			count;

	if (resp == NULL)
		return NULL;

	arr = kvs_array(resp, &count, errdetail);
	if (arr == NULL || count < 1)
		return NULL;			/* nobody holds it */

	return kv_field(arr, 0, "value");
}

#else							/* !HAVE_LIBCURL */

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

static SpockQuorumAnswer
etcd_have_quorum(char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return SPOCK_QUORUM_UNKNOWN;
}

static List *
etcd_members(char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return NIL;
}

static SpockQuorumAnswer
etcd_is_leader(char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return SPOCK_QUORUM_UNKNOWN;
}

static char *
etcd_leader_name(char **errdetail)
{
	*errdetail = pstrdup(etcd_unavailable());
	return NULL;
}

#endif							/* HAVE_LIBCURL */

const SpockQuorumProvider spock_quorum_provider_etcd = {
	.name = "etcd",
	.startup = etcd_startup,
	.shutdown = etcd_shutdown,
	.refresh = etcd_refresh,
	.have_quorum = etcd_have_quorum,
	.members = etcd_members,
	.is_leader = etcd_is_leader,
	.leader = etcd_leader_name
};
