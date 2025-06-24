# Compiler
CC = gcc

# PostgreSQL include and library directories
PG_INCDIR = $(shell pg_config --includedir)
PG_LIBDIR = $(shell pg_config --libdir)
PG_BINDIR = $(shell pg_config --bindir)

PG_SHAREDIR = $(shell pg_config --sharedir)
SPOCK_DIR = $(PG_SHAREDIR)/spock

RPATH = -Wl,--enable-new-dtags,-rpath,$(PG_LIBDIR)

# PostgreSQL library
PG_LIBS = -lpq

# JSON library using pkg-config
JSON_CFLAGS = $(shell pkg-config --cflags jansson)
JSON_LIBS = $(shell pkg-config --libs jansson)

# Compiler flags
CFLAGS = -Wall -g3 -O0 -pthread -I./include -I$(PG_INCDIR) $(JSON_CFLAGS)

# Source files
SRCS = src/spockctrl.c src/util.c src/sql.c src/slot.c src/logger.c src/workflow.c src/node.c src/repset.c src/sub.c src/dbconn.c src/conf.c

# Object files
OBJS = $(SRCS:.c=.o)

# Executable name
EXEC = spockctrl

# Default target
all: $(EXEC)

# Link object files to create executable
$(EXEC): $(OBJS)
	$(CC) $(CFLAGS) -L$(PG_LIBDIR) -o $@ $^ $(PG_LIBS) $(JSON_LIBS) $(RPATH)

# Compile source files to object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Clean up build files
clean:
	rm -f $(OBJS) $(EXEC)

# Clean up all build files and backups
clean-all: clean
	find . \( -name '*~' -o -name '*.o' -o -name 'spockctrl' -o -name '*.log' -o -name '*.tmp' \) -exec rm -f {} +

install:
	install -d $(PG_BINDIR)
	install -m 0755 $(EXEC) $(PG_BINDIR)/
	install -d $(DESTDIR)$(SPOCK_DIR)
	install -d $(DESTDIR)$(SPOCK_DIR)/workflows/
	find . -type f -name '*.json' ! -name 'spockctrl.json' -exec install -m 644 {} $(DESTDIR)$(SPOCK_DIR)/workflows/ \;
	find . -type f -name 'spockctrl.json' -exec install -m 644 {} $(DESTDIR)$(SPOCK_DIR)/ \;

