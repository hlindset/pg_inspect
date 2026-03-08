defmodule ExPgQuery do
  @moduledoc """
  Provides functionality for parsing and analyzing PostgreSQL SQL queries.

  Parses SQL queries and extracts information about tables, functions, CTEs,
  aliases, and filter columns. Supports all SQL statement types including SELECT,
  DDL, and DML operations.

  ## Examples

      iex> query = "SELECT id, name FROM users WHERE age > 21 AND users.id in (10, 20, 30)"
      iex> {:ok, result} = ExPgQuery.parse(query)
      iex> ExPgQuery.tables(result)
      ["users"]
      iex> ExPgQuery.filter_columns(result)
      [{"users", "id"}, {nil, "age"}]

      # DDL operations
      iex> {:ok, result} = ExPgQuery.parse("CREATE TABLE posts (id integer, title text)")
      iex> ExPgQuery.ddl_tables(result)
      ["posts"]

      iex> {:ok, result} = ExPgQuery.parse("SELECT * INTO films_recent FROM films")
      iex> ExPgQuery.ddl_tables(result)
      ["films_recent"]
      iex> ExPgQuery.select_tables(result)
      ["films"]

      # Function analysis
      iex> {:ok, result} = ExPgQuery.parse("SELECT count(*) FROM users")
      iex> ExPgQuery.functions(result)
      ["count"]

  """

  alias ExPgQuery.Analysis
  alias ExPgQuery.Truncator

  defmodule ParseResult do
    @moduledoc """
    Represents the result of parsing a SQL query.

    ## Fields

      * `tree` - Raw parse tree
      * `tables` - Referenced tables
      * `table_aliases` - Table aliases
      * `cte_names` - Common Table Expression names
      * `functions` - Referenced functions
      * `filter_columns` - Columns used to filter rows, e.g. (`WHERE`, `JOIN ... ON`)

    """

    defstruct tree: nil,
              tables: [],
              table_aliases: [],
              cte_names: [],
              functions: [],
              filter_columns: []
  end

  @doc """
  Parses a SQL query and returns detailed information about its structure.

  ## Parameters

    * `query` - SQL query string to parse

  ## Returns

    * `{:ok, ExPgQuery.ParseResult}` - Successfully parsed query with analysis
    * `{:error, reason}` - Error with reason

  ## Examples

      iex> query = "SELECT name FROM users u JOIN posts p ON u.id = p.user_id"
      iex> {:ok, result} = ExPgQuery.parse(query)
      iex> ExPgQuery.tables(result)
      ["posts", "users"]
      iex> ExPgQuery.table_aliases(result)
      [%{alias: "p", relation: "posts", location: 30, schema: nil}, %{alias: "u", relation: "users", location: 17, schema: nil}]

  """
  def parse(query) do
    with {:ok, tree} <- ExPgQuery.Protobuf.from_sql(query) do
      {:ok, Analysis.analyze(tree)}
    end
  end

  @doc """
  Returns all table names referenced in the query.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of table names

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT * FROM users JOIN posts ON users.id = posts.user_id")
      iex> ExPgQuery.tables(result)
      ["posts", "users"]

  """
  def tables(%ParseResult{tables: tables}),
    do: Enum.map(tables, & &1.name) |> Enum.uniq()

  @doc """
  Returns table names from SELECT operations.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of table names used in SELECT statements

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT * FROM users; CREATE TABLE posts (id int)")
      iex> ExPgQuery.select_tables(result)
      ["users"]

  """
  def select_tables(%ParseResult{tables: tables}),
    do:
      tables
      |> Enum.filter(&(&1.type == :select))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

  @doc """
  Returns table names from DDL operations.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of table names in DDL statements

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("CREATE TABLE users (id int); SELECT * FROM posts")
      iex> ExPgQuery.ddl_tables(result)
      ["users"]

  """
  def ddl_tables(%ParseResult{tables: tables}),
    do:
      tables
      |> Enum.filter(&(&1.type == :ddl))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

  @doc """
  Returns table names from DML operations.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of table names in DML statements

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("INSERT INTO users (name) VALUES ('John')")
      iex> ExPgQuery.dml_tables(result)
      ["users"]

  """
  def dml_tables(%ParseResult{tables: tables}),
    do:
      tables
      |> Enum.filter(&(&1.type == :dml))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

  @doc """
  Returns all function names referenced in the query.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of function names

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT count(*), max(age) FROM users")
      iex> ExPgQuery.functions(result)
      ["max", "count"]

  """
  def functions(%ParseResult{functions: functions}),
    do: Enum.map(functions, & &1.name) |> Enum.uniq()

  @doc """
  Returns function names that are called in the query.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of called function names

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT * FROM users WHERE age > my_func()")
      iex> ExPgQuery.call_functions(result)
      ["my_func"]

  """
  def call_functions(%ParseResult{functions: functions}),
    do:
      functions
      |> Enum.filter(&(&1.type == :call))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

  @doc """
  Returns function names from DDL operations.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of function names in DDL statements

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("CREATE FUNCTION add(a int, b int) RETURNS int")
      iex> ExPgQuery.ddl_functions(result)
      ["add"]

  """
  def ddl_functions(%ParseResult{functions: functions}),
    do:
      functions
      |> Enum.filter(&(&1.type == :ddl))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

  @doc """
  Returns column references used in filter conditions.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of `{table_name, column_name}` tuples
      * `table_name` can be nil if table isn't specified in query

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT * FROM users WHERE age > 21 AND users.active = true")
      iex> ExPgQuery.filter_columns(result)
      [{"users", "active"}, {nil, "age"}]

  """
  def filter_columns(%ParseResult{filter_columns: filter_columns}),
    do: filter_columns

  @doc """
  Returns table aliases defined in the query.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of alias maps containing:
      * `alias` - Alias name
      * `relation` - Original table name
      * `location` - Position in query
      * `schema` - Schema name (or nil)

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT u.name FROM users u JOIN posts p ON u.id = p.user_id")
      iex> ExPgQuery.table_aliases(result)
      [
        %{alias: "p", relation: "posts", location: 32, schema: nil},
        %{alias: "u", relation: "users", location: 19, schema: nil}
      ]

      iex> {:ok, result} = ExPgQuery.parse("SELECT * FROM public.users usr")
      iex> ExPgQuery.table_aliases(result)
      [%{alias: "usr", relation: "users", location: 14, schema: "public"}]

  """
  def table_aliases(%ParseResult{table_aliases: table_aliases}),
    do: table_aliases

  @doc """
  Returns types of statements in the query.

  ## Parameters

    * `result` - `ExPgQuery.ParseResult` struct

  ## Returns

    * List of statement type atoms

  ## Examples

      iex> {:ok, result} = ExPgQuery.parse("SELECT 1; INSERT INTO users (id) VALUES (1)")
      iex> ExPgQuery.statement_types(result)
      [:select_stmt, :insert_stmt]

  """
  def statement_types(%ParseResult{tree: %PgQuery.ParseResult{stmts: stmts}}) do
    Enum.map(stmts, fn %PgQuery.RawStmt{stmt: %PgQuery.Node{node: {stmt_type, _}}} ->
      stmt_type
    end)
  end

  @doc """
  Truncates query to be below the specified length.

  Attempts smart truncation of specific query parts before falling back to
  hard truncation.

  ## Parameters

    * `parse_result` - A `ExPgQuery.ParseResult` struct containing the parsed query
    * `max_length` - Maximum allowed length of the output string

  ## Returns

    * `{:ok, string}` - Successfully truncated query
    * `{:error, reason}` - Error during truncation

  ## Examples

      iex> query = "SELECT * FROM users WHERE name = 'very long name'"
      iex> {:ok, parse_result} = ExPgQuery.parse(query)
      iex> ExPgQuery.truncate(parse_result, 30)
      {:ok, "SELECT * FROM users WHERE ..."}

  """
  def truncate(%ParseResult{} = parse_result, max_length) do
    Truncator.truncate(parse_result.tree, max_length)
  end
end
