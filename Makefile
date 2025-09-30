# contrib/spock/Makefile


export PG_CONFIG ?= pg_config
PGVER := $(shell $(PG_CONFIG) --version | sed 's/[^0-9]//g' | cut -c 1-2)

MODULE_big = spock
EXTENSION = spock
PGFILEDESC = "spock - multi-master replication"

MODULES = spock_output

# Lookup source directory
vpath % src src/compat/$(PGVER)

DATA = $(wildcard sql/$(EXTENSION)*--*.sql)
SRCS := $(wildcard src/*.c) \
        $(wildcard src/compat/$(PGVER)/*.c)
OBJS = $(filter-out src/spock_output.o, $(SRCS:.c=.o)) \
       src/compat/$(PGVER)/spock_compat.o

PG_CPPFLAGS += -I$(libpq_srcdir) \
			   -I$(realpath include) \
			   -I$(realpath src/compat/$(PGVER)) \
			   -Werror=implicit-function-declaration
SHLIB_LINK += $(libpq) $(filter -lintl, $(LIBS))
ifdef NO_LOG_OLD_VALUE
PG_CPPFLAGS += -DNO_LOG_OLD_VALUE
endif

REGRESS := __placeholder__
EXTRA_CLEAN += $(control_path) spock_compat.bc

# -----------------------------------------------------------------------------
# PGXS
# -----------------------------------------------------------------------------
PGXS = $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Tell make where the module source is
spock_output.o: src/spock_output.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

spock_version=$(shell grep "^\#define \<SPOCK_VERSION\>" $(realpath include/spock.h) | cut -d'"' -f2)
requires =
control_path = $(abspath $(srcdir))/spock.control
spock.control: spock.control.in include/spock.h
	sed 's/__SPOCK_VERSION__/$(spock_version)/;s/__REQUIRES__/$(requires)/' $(realpath $(srcdir)/spock.control.in) > $(control_path)


all: spock.control spockctrl

# -----------------------------------------------------------------------------
# Regression tests
# -----------------------------------------------------------------------------
REGRESS = preseed infofuncs init_fail init preseed_check basic conflict_secondary_unique \
		  toasted replication_set matview bidirectional primary_key \
		  interfaces foreign_key copy sequence triggers parallel functions row_filter \
		  row_filter_sampling att_list column_filter apply_delay \
		  extended node_origin_cascade multiple_upstreams tuple_origin autoddl \
		  drop

# The following test cases are disabled while developing.
#
# Ideally, we should run all test cases listed in $(REGRESS),
# but occassionaly it is helpful to disable one or more
# cases while developing.
REGRESS := $(filter-out add_table, $(REGRESS))

# For regression checks
# this makes "make check" give a useful error
abs_top_builddir = .
NO_TEMP_INSTALL = yes

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
_regress=$(patsubst %/,%,$(srcdir))/tests/regress
REGRESS_OPTS += --dbname=regression \
				--bindir=$(shell $(PG_CONFIG) --bindir) \
				--inputdir=$(abspath $(_regress))
pg_regress_clean_files = $(_regress)/results $(_regress)/regression_output \
			$(_regress)/regression.diffs $(_regress)/regression.out $(_regress)/tmp_check/ \
			$(_regress)/tmp_check_iso/ $(_regress)/log/ $(_regress)/output_iso/
regresscheck:
	$(MKDIR_P) $(_regress)/regression_output
	$(pg_regress_check) $(REGRESS_OPTS) \
	    --temp-config $(_regress)/regress-postgresql.conf \
	    --temp-instance=$(_regress)/tmp_check \
	    --outputdir=$(_regress)/regression_output \
	    --create-role=logical \
	    $(REGRESS)

check: install regresscheck

# runs TAP tests

# PGXS doesn't support TAP tests yet.
# Copy perl modules in postgresql_srcdir/src/test/perl
# to postgresql_installdir/lib/pgxs/src/test/perl


define prove_check
rm -rf $(CURDIR)/tmp_check/log
cd $(srcdir)/tests/tap && TESTDIR='$(CURDIR)' $(with_temp_install) PGPORT='6$(DEF_PGPORT)' PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' $(PROVE) -I t --verbose $(PG_PROVE_FLAGS) $(PROVE_FLAGS) $(or $(PROVE_TESTS),t/*.pl)
endef

check_prove:
	$(prove_check)

# -----------------------------------------------------------------------------
# SpockCtrl
# -----------------------------------------------------------------------------
spockctrl:
	$(MAKE) -C $(srcdir)/utils/spockctrl

clean: clean-spockctrl

clean-spockctrl:
	$(MAKE) -C $(srcdir)/utils/spockctrl clean

install: install-spockctrl

install-spockctrl:
	$(MAKE) -C $(srcdir)/utils/spockctrl install

# -----------------------------------------------------------------------------
# Dist packaging
# -----------------------------------------------------------------------------
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


# -----------------------------------------------------------------------------
# PHONY targets
# -----------------------------------------------------------------------------
.PHONY: all check regresscheck spock.control spockctrl clean clean-spockctrl \
        dist git-dist check_prove valgrind-check

define _spk_create_recursive_target
.PHONY: $(1)-$(2)-recurse
$(1): $(1)-$(2)-recurse
$(1)-$(2)-recurse: $(if $(filter check, $(3)), temp-install)
	$(MKDIR_P) $(2)
	$$(MAKE) -C $(2) -f $(abspath $(srcdir))/$(2)/Makefile VPATH=$(abspath $(srcdir))/$(2) $(3)
endef

$(foreach target,$(if $1,$1,$(standard_targets)),$(foreach subdir,$(if $2,$2,$(SUBDIRS)),$(eval $(call _spk_create_recursive_target,$(target),$(subdir),$(if $3,$3,$(target))))))

# -----------------------------------------------------------------------------
# Valgrind wrapper
# -----------------------------------------------------------------------------
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
