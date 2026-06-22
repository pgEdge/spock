# Makefile for spock_create_subscriber utility
PG_CONFIG ?= pg_config
PROGRAM = spock_create_subscriber

PG_CPPFLAGS = -I../../include -I$(shell $(PG_CONFIG) --includedir)
PG_LDFLAGS = -lpq -L$(shell $(PG_CONFIG) --libdir)

# create symlink to spock_fe.c here
spock_fe.c: ../../src/spock_fe.c
	ln -sf $< $@
OBJS = spock_create_subscriber.o spock_fe.o

# PGXS
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
