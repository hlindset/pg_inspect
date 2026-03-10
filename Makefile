MIX = mix
CFLAGS = -O3 -Wall
ERLANG_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS += -I$(ERLANG_PATH)
CFLAGS += -I./libpg_query/vendor
LIBPG_QUERY_PATH = libpg_query

CFLAGS += -I$(LIBPG_QUERY_PATH) -fPIC

ifdef ZIG_TARGET
CC ?= zig cc -target $(ZIG_TARGET)
endif

CC ?= cc
LIBPG_QUERY_AR = $(if $(filter zig,$(firstword $(CC))),zig ar rs,ar rs)

LDFLAGS = -lpthread -shared
ifeq ($(shell uname -s),Darwin)
    LDFLAGS += -undefined dynamic_lookup
endif

.PHONY: all pg_inspect clean precompile_clean libpg_query_build

all: priv/pg_inspect.so

priv:
	mkdir -p priv

libpg_query_build:
	$(MAKE) -C $(LIBPG_QUERY_PATH) CC="$(CC)" AR="$(LIBPG_QUERY_AR)" libpg_query.a

priv/pg_inspect.so: priv libpg_query_build src/pg_inspect.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/pg_inspect.c $(LIBPG_QUERY_PATH)/libpg_query.a

clean:
	$(MIX) clean
	$(MAKE) -C $(LIBPG_QUERY_PATH) clean
	$(RM) priv/pg_inspect.so

precompile_clean:
	$(MAKE) -C $(LIBPG_QUERY_PATH) clean
	$(RM) priv/pg_inspect.so
