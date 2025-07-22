# contrib/spock/Makefile

MODULE_big = spock
EXTENSION = spock
PGFILEDESC = "spock - multi-master replication"

MODULES = spock_output

DATA = spock--5.0.0--5.0.1.sql \
	   spock--5.0.0.sql \
	   spock--4.0.0--4.0.1.sql \
	   spock--4.0.1--4.0.2.sql \
	   spock--4.0.2--4.0.3.sql \
	   spock--4.0.3--4.0.4.sql \
	   spock--4.0.4--4.0.5.sql \
	   spock--4.0.5--4.0.6.sql \
	   spock--4.0.6--4.0.7.sql \
	   spock--4.0.7--4.0.8.sql \
	   spock--4.0.8--4.0.9.sql \
	   spock--4.0.9--4.0.10.sql \
	   spock--4.0.10--5.0.0.sql

OBJS = 	spock_jsonb_utils.o spock_exception_handler.o spock_apply.o \
		spock_conflict.o spock_manager.o \
		spock.o spock_node.o spock_relcache.o \
		spock_repset.o spock_rpc.o spock_functions.o \
		spock_queue.o spock_fe.o spock_worker.o \
		spock_sync.o spock_sequences.o spock_executor.o \
		spock_dependency.o spock_apply_heap.o spock_apply_spi.o \
		spock_output_config.o spock_output_plugin.o \
		spock_output_proto.o spock_proto_json.o \
		spock_proto_native.o spock_monitoring.o spock_failover_slots.o \
		spock_readonly.o spock_common.o

SCRIPTS_built = spock_create_subscriber

# FIXME: triggers
REGRESS = preseed infofuncs init_fail init preseed_check basic conflict_secondary_unique \
		  toasted replication_set matview bidirectional primary_key \
		  interfaces foreign_key copy sequence parallel functions row_filter \
		  row_filter_sampling att_list column_filter apply_delay \
		  extended node_origin_cascade multiple_upstreams drop

# Disabled following tests:
#	add_table functions

# The following test cases are disabled while developing.
#
# Ideally, we should run all test cases listed in $(REGRESS),
# but occassionaly it is helpful to disable one or more
# cases while developing.

#REGRESS := $(filter-out apply_delay, $(REGRESS))

EXTRA_CLEAN += compat17/spock_compat.o compat17/spock_compat.bc \
				compat16/spock_compat.o compat16/spock_compat.bc \
				compat15/spock_compat.o compat15/spock_compat.bc \
				spock_create_subscriber.o

spock_version=$(shell grep "^\#define \<SPOCK_VERSION\>" $(realpath $(srcdir)/spock.h) | cut -d'"' -f2)

# For regression checks
# this makes "make check" give a useful error
abs_top_builddir = .
NO_TEMP_INSTALL = yes

PG_CONFIG ?= pg_config

PGVER := $(shell $(PG_CONFIG) --version | sed 's/[^0-9]//g' | cut -c 1-2)

PG_CPPFLAGS += -I$(libpq_srcdir) -I$(realpath $(srcdir)/compat$(PGVER)) -Werror=implicit-function-declaration
ifdef NO_LOG_OLD_VALUE
PG_CPPFLAGS += -DNO_LOG_OLD_VALUE
endif
SHLIB_LINK += $(libpq) $(filter -lintl, $(LIBS))

OBJS += $(srcdir)/compat$(PGVER)/spock_compat.o

requires =
control_path = $(abspath $(srcdir))/spock.control

EXTRA_CLEAN += $(control_path)

PGXS = $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# We can't do a normal 'make check' because PGXS doesn't support
# creating a temp install. We don't want to use a normal PGXS
# 'installcheck' though, because it's a pain to set up a temp install
# manually, with the config overrides needed.
#
# We compromise by using the install we're building against, installing
# glogical into it, then making a temp instance. This means that 'check'
# affects the target DB install. Nobody with any sense runs 'make check'
# under a user with write permissions to their production PostgreSQL
# install (right?)
# But this is still not ideal.
regresscheck:
	$(MKDIR_P) regression_output
	$(pg_regress_check) \
	    --temp-config ./regress-postgresql.conf \
	    --temp-instance=./tmp_check \
	    --outputdir=./regression_output \
	    --create-role=logical \
	    $(REGRESS)

check: install regresscheck

spock_create_subscriber: spock_create_subscriber.o spock_fe.o
	$(CC) $(CFLAGS) $^ $(LDFLAGS) $(LDFLAGS_EX) $(libpq_pgport) $(filter-out -lreadline, $(LIBS)) -o $@$(X)


spock.control: spock.control.in spock.h
	sed 's/__SPOCK_VERSION__/$(spock_version)/;s/__REQUIRES__/$(requires)/' $(realpath $(srcdir)/spock.control.in) > $(control_path)

spockctrl:
	$(MAKE) -C spockctrl

all: spock.control spockctrl

GITHASH=$(shell if [ -e .distgitrev ]; then cat .distgitrev; else git rev-parse --short HEAD; fi)

dist-common: clean
	@if test "$(wanttag)" -eq 1 -a "`git name-rev --tags --name-only $(GITHASH)`" = "undefined"; then echo "cannot 'make dist' on untagged tree; tag it or use make git-dist"; exit 1; fi
	@rm -f .distgitrev .distgittag
	@if ! git diff-index --quiet HEAD; then echo >&2 "WARNING: git working tree has uncommitted changes to tracked files which were INCLUDED"; fi
	@if [ -n "`git ls-files --exclude-standard --others`" ]; then echo >&2 "WARNING: git working tree has unstaged files which were IGNORED!"; fi
	@echo $(GITHASH) > .distgitrev
	@git name-rev --tags --name-only `cat .distgitrev` > .distgittag
	@(git ls-tree -r -t --full-tree HEAD --name-only \
	  && cd spock_dump\
	  && git ls-tree -r -t --full-tree HEAD --name-only | sed 's/^/spock_dump\//'\
	 ) |\
	  tar cjf "${distdir}.tar.bz2" --transform="s|^|${distdir}/|" --no-recursion \
	    -T - .distgitrev .distgittag
	@echo >&2 "Prepared ${distdir}.tar.bz2 for rev=`cat .distgitrev`, tag=`cat .distgittag`"
	@rm -f .distgitrev .distgittag
	@md5sum "${distdir}.tar.bz2" > "${distdir}.tar.bz2.md5"
	@if test -n "$(GPGSIGNKEYS)"; then gpg -q -a -b $(shell for x in $(GPGSIGNKEYS); do echo -u $$x; done) "${distdir}.tar.bz2"; else echo "No GPGSIGNKEYS passed, not signing tarball. Pass space separated keyid list as make var to sign."; fi

dist: distdir=spock-$(spock_version)
dist: wanttag=1
dist: dist-common

git-dist: distdir=spock-$(spock_version)_git$(GITHASH)
git-dist: wanttag=0
git-dist: dist-common


# runs TAP tests

# PGXS doesn't support TAP tests yet.
# Copy perl modules in postgresql_srcdir/src/test/perl
# to postgresql_installdir/lib/pgxs/src/test/perl


define prove_check
rm -rf $(CURDIR)/tmp_check/log
cd $(srcdir) && TESTDIR='$(CURDIR)' $(with_temp_install) PGPORT='6$(DEF_PGPORT)' PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' $(PROVE) --verbose $(PG_PROVE_FLAGS) $(PROVE_FLAGS) $(or $(PROVE_TESTS),t/*.pl)
endef

check_prove:
	$(prove_check)

clean: clean-spockctrl

clean-spockctrl:
	$(MAKE) -C spockctrl clean

install: install-spockctrl

install-spockctrl:
	$(MAKE) -C spockctrl install

.PHONY: all check regresscheck spock.control spockctrl

define _spk_create_recursive_target
.PHONY: $(1)-$(2)-recurse
$(1): $(1)-$(2)-recurse
$(1)-$(2)-recurse: $(if $(filter check, $(3)), temp-install)
	$(MKDIR_P) $(2)
	$$(MAKE) -C $(2) -f $(abspath $(srcdir))/$(2)/Makefile VPATH=$(abspath $(srcdir))/$(2) $(3)
endef

$(foreach target,$(if $1,$1,$(standard_targets)),$(foreach subdir,$(if $2,$2,$(SUBDIRS)),$(eval $(call _spk_create_recursive_target,$(target),$(subdir),$(if $3,$3,$(target))))))


define VALGRIND_WRAPPER
#!/bin/bash

set -e -u -x

# May also want --expensive-definedness-checks=yes
#
# Quicker runs without --track-origins=yes --read-var-info=yes
#
# If you don't want leak checking, use --leak-check=no
#
# When just doing leak checking and not looking for detailed memory error reports you don't need:
# 	--track-origins=yes --read-var-info=yes --malloc-fill=8f --free-fill=9f 
#
SUPP=$(POSTGRES_SRC)/src/tools/valgrind.supp

# Pop top two elements from path; the first is added by pg_regress
# and the next is us.
function join_by { local IFS="$$1"; shift; echo "$$*"; }
IFS=':' read -r -a PATHA <<< "$$PATH"
export PATH=$$(join_by ":" "$${PATHA[@]:2}")

NEXT_POSTGRES=$$(which postgres)
if [ "$${NEXT_POSTGRES}" -ef "./valgrind/postgres" ]; then
    echo "ERROR: attempt to execute self"
    exit 1
fi

echo "Running $${NEXT_POSTGRES} under Valgrind"

valgrind --leak-check=full --show-leak-kinds=definite,possible,reachable --gen-suppressions=all \
	--suppressions="$${SUPP}" --suppressions=`pwd`/spock.supp --verbose \
	--time-stamp=yes  --log-file=valgrind-$$$$-%p.log --trace-children=yes \
	--track-origins=yes --read-var-info=yes --malloc-fill=8f --free-fill=9f \
	--num-callers=30 \
	postgres "$$@"

endef

export VALGRIND_WRAPPER

valgrind-check:
	$(if $(POSTGRES_SRC),,$(error set Make variable POSTGRES_SRC to postgres source dir to find valgrind.supp))
	$(if $(wildcard $(POSTGRES_SRC)/src/tools/valgrind.supp),,$(error missing valgrind suppressions at $(POSTGRES_SRC)/src/tools/valgrind.supp))
	mkdir -p valgrind/
	echo "$$VALGRIND_WRAPPER" > valgrind/postgres
	chmod a+x valgrind/postgres
	PATH=./valgrind/:$(PATH) $(MAKE) check
	rm valgrind/postgres
