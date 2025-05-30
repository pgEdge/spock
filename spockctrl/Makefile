# Compiler
CC = gcc

# PostgreSQL include and library directories
PG_INCDIR = $(shell pg_config --includedir)
PG_LIBDIR = $(shell pg_config --libdir)

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
	$(CC) $(CFLAGS) -L$(PG_LIBDIR) -o $@ $^ $(PG_LIBS) $(JSON_LIBS)

# Compile source files to object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Clean up build files
clean:
	rm -f $(OBJS) $(EXEC)

# Clean up all build files and backups
clean-all: clean
	rm -f *~
