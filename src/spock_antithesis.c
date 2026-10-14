/*-------------------------------------------------------------------------
 *
 * spock_antithesis.c
 * 		Antithesis assertion writer and coverage hooks
 *
 * See include/spock_antithesis.h.  This file is empty unless Spock is built
 * with "make ANTITHESIS=1".
 *
 * Writes go straight to the SDK capture file with open/write/close, no
 * palloc and no elog, so an assertion is safe to evaluate in an error path
 * or a critical section.  Many backends append to the same file at once:
 * each message is a single write() on an O_APPEND descriptor, which Linux
 * keeps whole.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#ifdef USE_ANTITHESIS

#include <fcntl.h>
#include <unistd.h>

#include "spock_antithesis.h"

/*
 * Coverage hooks.  Must live in a file compiled without
 * -fsanitize-coverage; the Makefile leaves this one out.
 */
#ifdef USE_ANTITHESIS_COVERAGE
#include "antithesis_instrumentation.h"
#endif

#define SPOCK_ANT_MSG_MAX 4096

typedef struct SpockAntEntry
{
	SpockAntKind kind;
	const char *message;
	const char *file;
	const char *function;
} SpockAntEntry;

static const SpockAntEntry spock_ant_catalog[SPOCK_ANT_NUM_ASSERTIONS] = {
#define SPOCK_ANT_ASSERTION(id, kind, message, file, function) \
	[id] = {SPOCK_ANT_KIND_##kind, message, file, function},
	SPOCK_ANT_CATALOG
#undef SPOCK_ANT_ASSERTION
};

/*
 * Per-process record of what was already sent.  Antithesis needs only the
 * first true and the first false evaluation of each assertion; later ones
 * add nothing.  Backends inherit the postmaster's (empty) copy at fork.
 */
static bool spock_ant_sent_true[SPOCK_ANT_NUM_ASSERTIONS];
static bool spock_ant_sent_false[SPOCK_ANT_NUM_ASSERTIONS];

/* Append src to buf at *pos as a JSON string body, escaping as needed. */
static void
ant_append_escaped(char *buf, size_t *pos, size_t cap, const char *src)
{
	for (; *src && *pos + 7 < cap; src++)
	{
		unsigned char c = (unsigned char) *src;

		if (c == '"' || c == '\\')
		{
			buf[(*pos)++] = '\\';
			buf[(*pos)++] = c;
		}
		else if (c < 0x20)
			*pos += snprintf(buf + *pos, cap - *pos, "\\u%04x", c);
		else
			buf[(*pos)++] = c;
	}
}

static void
ant_append(char *buf, size_t *pos, size_t cap, const char *src)
{
	size_t		len = strlen(src);

	if (*pos + len >= cap)
		len = cap - *pos - 1;
	memcpy(buf + *pos, src, len);
	*pos += len;
}

static void
ant_write(SpockAntId id, bool hit, bool condition, const char *details_json)
{
	const SpockAntEntry *e = &spock_ant_catalog[id];
	const char *dir = getenv("ANTITHESIS_OUTPUT_DIR");
	const char *assert_type;
	const char *display_type;
	bool		must_hit;
	char		path[MAXPGPATH];
	char		buf[SPOCK_ANT_MSG_MAX];
	size_t		pos = 0;
	char		num[32];
	int			fd;

	if (dir == NULL || dir[0] == '\0')
		return;

	switch (e->kind)
	{
		case SPOCK_ANT_KIND_REACHABLE:
			assert_type = "reachability";
			display_type = "Reachable";
			must_hit = true;
			break;
		case SPOCK_ANT_KIND_UNREACHABLE:
			assert_type = "reachability";
			display_type = "Unreachable";
			must_hit = false;
			break;
		case SPOCK_ANT_KIND_ALWAYS:
			assert_type = "always";
			display_type = "Always";
			must_hit = true;
			break;
		case SPOCK_ANT_KIND_ALWAYS_OR_UNREACHABLE:
			assert_type = "always";
			display_type = "AlwaysOrUnreachable";
			must_hit = false;
			break;
		case SPOCK_ANT_KIND_SOMETIMES:
		default:
			assert_type = "sometimes";
			display_type = "Sometimes";
			must_hit = true;
			break;
	}

	ant_append(buf, &pos, sizeof(buf), "{\"antithesis_assert\":{\"id\":\"");
	ant_append_escaped(buf, &pos, sizeof(buf), e->message);
	ant_append(buf, &pos, sizeof(buf), "\",\"message\":\"");
	ant_append_escaped(buf, &pos, sizeof(buf), e->message);
	ant_append(buf, &pos, sizeof(buf), "\",\"condition\":");
	ant_append(buf, &pos, sizeof(buf), condition ? "true" : "false");
	ant_append(buf, &pos, sizeof(buf), ",\"display_type\":\"");
	ant_append(buf, &pos, sizeof(buf), display_type);
	ant_append(buf, &pos, sizeof(buf), "\",\"hit\":");
	ant_append(buf, &pos, sizeof(buf), hit ? "true" : "false");
	ant_append(buf, &pos, sizeof(buf), ",\"must_hit\":");
	ant_append(buf, &pos, sizeof(buf), must_hit ? "true" : "false");
	ant_append(buf, &pos, sizeof(buf), ",\"assert_type\":\"");
	ant_append(buf, &pos, sizeof(buf), assert_type);
	ant_append(buf, &pos, sizeof(buf), "\",\"location\":{\"file\":\"");
	ant_append_escaped(buf, &pos, sizeof(buf), e->file);
	ant_append(buf, &pos, sizeof(buf), "\",\"function\":\"");
	ant_append_escaped(buf, &pos, sizeof(buf), e->function);
	ant_append(buf, &pos, sizeof(buf),
			   "\",\"class\":\"spock\",\"begin_line\":0,\"begin_column\":0}");
	if (hit)
	{
		snprintf(num, sizeof(num), "%d", (int) getpid());
		ant_append(buf, &pos, sizeof(buf), ",\"details\":{\"pid\":");
		ant_append(buf, &pos, sizeof(buf), num);
		if (details_json != NULL)
		{
			ant_append(buf, &pos, sizeof(buf), ",\"info\":");
			ant_append(buf, &pos, sizeof(buf), details_json);
		}
		ant_append(buf, &pos, sizeof(buf), "}");
	}
	ant_append(buf, &pos, sizeof(buf), "}}\n");

	/* A truncated line is not valid JSON; make sure it still ends the line. */
	buf[pos - 1] = '\n';

	snprintf(path, sizeof(path), "%s/sdk.jsonl", dir);
	fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
	if (fd < 0)
		return;
	(void) write(fd, buf, pos);
	close(fd);
}

/*
 * Declare every assertion.  Called from _PG_init, which runs once in the
 * postmaster, so a Sometimes or Reachable that never fires still appears in
 * the report and fails there.
 */
void
spock_antithesis_init(void)
{
	int			i;

	for (i = 0; i < SPOCK_ANT_NUM_ASSERTIONS; i++)
		ant_write((SpockAntId) i, false, false, NULL);
}

void
spock_antithesis_eval(SpockAntId id, bool condition, const char *details_json)
{
	bool	   *sent;

	if (id < 0 || id >= SPOCK_ANT_NUM_ASSERTIONS)
		return;

	sent = condition ? spock_ant_sent_true : spock_ant_sent_false;
	if (sent[id])
		return;
	sent[id] = true;

	ant_write(id, true, condition, details_json);
}

#endif							/* USE_ANTITHESIS */
