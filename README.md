# PgInspect

Elixir library with a C NIF for parsing PostgreSQL queries. It uses
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

## License

This library is distributed under the terms of the [MIT license](LICENSE).

The libpg_query snapshot is distributed under the BSD 3-Clause license. See
[libpg_query/LICENSE](libpg_query/LICENSE).

## Contributing

Bug reports and pull requests are welcome.
