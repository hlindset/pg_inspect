# PgInspect

Elixir library with a Zigler-backed NIF for parsing PostgreSQL queries. It uses
[pganalyze/libpg_query](https://github.com/pganalyze/libpg_query) for parsing,
deparsing, fingerprinting, and normalization.

## Features

- Raw PostgreSQL AST parse/deparse
- High-level query analysis
- Query truncation
- Query normalization
- Query fingerprinting

## Installation

Not published to Hex yet.

Tagged releases publish precompiled Zigler artifacts for the supported
`mix zig.precompile` target matrix on Zigler 0.15.2 (Linux, macOS, and
FreeBSD variants). A normal git checkout, like this repository, compiles from
source so local development still works before a release is cut.

Windows precompilation is not wired into this repository yet because Zigler's
`windows-msvc` targets require MSVC and Windows SDK environment variables in
CI.

## Usage

### Raw AST I/O

```elixir
iex> {:ok, ast} = PgInspect.parse("SELECT * FROM users WHERE id = $1")
iex> match?(%PgQuery.ParseResult{}, ast)
true

iex> PgInspect.deparse(ast)
{:ok, "SELECT * FROM users WHERE id = $1"}
```

### Query Analysis

```elixir
iex> {:ok, analyzed} =
...>   PgInspect.analyze("""
...>   WITH recent_posts AS (SELECT * FROM posts WHERE author_id = $1)
...>   SELECT count(*) FROM recent_posts rp WHERE rp.inserted_at > $2::timestamptz
...>   """)

iex> PgInspect.tables(analyzed)
["posts"]

iex> PgInspect.cte_names(analyzed)
["recent_posts"]

iex> PgInspect.functions(analyzed)
["count"]

iex> PgInspect.filter_columns(analyzed)
[{"posts", "author_id"}, {"recent_posts", "inserted_at"}]

iex> PgInspect.parameter_references(analyzed)
[
  %{location: 56, length: 2},
  %{location: 111, length: 2, typename: ["timestamptz"]}
]
```

### Truncation

```elixir
iex> PgInspect.truncate("SELECT id, name, email FROM users WHERE active = true", 32)
{:ok, "SELECT ... FROM users WHERE ..."}
```

### Normalization

```elixir
iex> PgInspect.Normalize.normalize("SELECT * FROM users WHERE id = 123")
{:ok, "SELECT * FROM users WHERE id = $1"}
```

### Fingerprinting

```elixir
iex> PgInspect.Fingerprint.fingerprint("SELECT * FROM users WHERE id = 123")
{:ok, "a0ead580058af585"}

iex> PgInspect.Fingerprint.fingerprint("SELECT * FROM users WHERE id = 456")
{:ok, "a0ead580058af585"}
```

## Benchmarking

To benchmark the public API surface in the `dev` environment:

```sh
mix benchmark.public_api
```

You can shorten the run for quick checks:

```sh
mix benchmark.public_api --warmup 0.5 --time 2 --memory-time 0
```

The benchmark covers:

- SQL entry points such as `PgInspect.parse/1`, `PgInspect.analyze/1`,
  `PgInspect.truncate/2`, normalization, and fingerprinting
- AST entry points such as `PgInspect.deparse/1` and `PgInspect.Protobuf.to_sql/1`
- analysis result accessors such as `PgInspect.tables/1`

## License

This library is distributed under the terms of the [MIT license](LICENSE).

The libpg_query snapshot is distributed under the BSD 3-Clause license. See
[libpg_query/LICENSE](libpg_query/LICENSE).

## Contributing

Bug reports and pull requests are welcome.
