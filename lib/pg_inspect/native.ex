defmodule PgInspect.Native do
  @moduledoc """
  Provides native bindings to `libpg_query` C library functionality via NIFs.

  This module contains the core SQL parsing and manipulation functions implemented
  in native code for performance. The functions are loaded as NIFs (Native
  Implemented Functions) when the module is initialized.
  """

  @doc """
  Parses a SQL query into a Protocol Buffer representation.

  Returns a serialized protobuf that can be decoded as a `PgQuery.ParseResult`.

  ## Parameters

    * `query` - SQL query string to parse

  ## Returns

    * `{:ok, binary}` - Successfully parsed query as serialized protobuf
    * `{:error, reason}` - Error with reason

  ## Examples

      iex> {:ok, bytes} = PgInspect.Native.parse_protobuf("SELECT * FROM users")
      iex> is_binary(bytes)
      true
      iex> {:ok, _result} = Protox.decode(bytes, PgQuery.ParseResult)

  """
  defdelegate parse_protobuf(query), to: PgInspect.Native.Binding

  @doc """
  Converts a Protocol Buffer AST back into a SQL query string.

  ## Parameters

    * `protobuf` - Serialized Protocol Buffer AST binary

  ## Returns

    * `{:ok, string}` - Successfully deparsed query
    * `{:error, reason}` - Error with reason

  ## Examples

      iex> {:ok, bytes} = PgInspect.Native.parse_protobuf("SELECT * FROM users")
      iex> PgInspect.Native.deparse_protobuf(bytes)
      {:ok, "SELECT * FROM users"}

  """
  defdelegate deparse_protobuf(protobuf), to: PgInspect.Native.Binding

  @doc """
  Generates a fingerprint string that identifies structurally similar queries.

  Creates a hash that can be used to group similar queries that differ only in
  their literal values.

  ## Parameters

    * `query` - SQL query string to fingerprint

  ## Returns

    * `{:ok, map}` - Successfully generated fingerprint containing:
      * `:fingerprint` - Integer fingerprint value
      * `:fingerprint_str` - String representation of fingerprint
    * `{:error, reason}` - Error with reason

  ## Examples

      iex> PgInspect.Native.fingerprint("SELECT * FROM users WHERE id = 1")
      {:ok, %{fingerprint: 11595314936444286341, fingerprint_str: "a0ead580058af585"}}
      iex> PgInspect.Native.fingerprint("SELECT * FROM users WHERE id = 2")
      {:ok, %{fingerprint: 11595314936444286341, fingerprint_str: "a0ead580058af585"}}

  """
  defdelegate fingerprint(query), to: PgInspect.Native.Binding

  @doc """
  Performs lexical scanning of a SQL query into tokens.

  Returns a serialized protobuf that can be decoded as a `PgQuery.ScanResult`.

  ## Parameters

    * `query` - SQL query string to scan

  ## Returns

    * `{:ok, binary}` - Successfully scanned query as serialized protobuf
    * `{:error, reason}` - Error with reason

  ## Examples

      iex> {:ok, bytes} = PgInspect.Native.scan("SELECT * FROM users")
      iex> is_binary(bytes)
      true
      iex> {:ok, _result} = Protox.decode(bytes, PgQuery.ScanResult)

  """
  defdelegate scan(query), to: PgInspect.Native.Binding

  @doc """
  Normalizes a SQL query by replacing literal values with placeholders.

  Converts literal values in the query to positional parameters (`$1`, `$2`, etc.)
  while preserving the query structure.

  ## Parameters

    * `sql` - SQL query string to normalize

  ## Returns

    * `{:ok, string}` - Successfully normalized query
    * `{:error, reason}` - Error with reason

  ## Examples

      iex> PgInspect.Native.normalize("SELECT * FROM users WHERE id = 123")
      {:ok, "SELECT * FROM users WHERE id = $1"}

      iex> PgInspect.Native.normalize("SELECT a, SUM(b) FROM tbl WHERE c = 'foo' GROUP BY 1, 'bar'")
      {:ok, "SELECT a, SUM(b) FROM tbl WHERE c = $1 GROUP BY 1, $2"}

      iex> PgInspect.Native.normalize("SELECT * FROM users WHERE name = 'John' AND age > 25")
      {:ok, "SELECT * FROM users WHERE name = $1 AND age > $2"}

      iex> PgInspect.Native.normalize("CREATE ROLE postgres PASSWORD 'xyz'")
      {:ok, "CREATE ROLE postgres PASSWORD $1"}

  """
  defdelegate normalize(query), to: PgInspect.Native.Binding
end
