defmodule PgInspect do
  @moduledoc """
  High-level PostgreSQL query parsing, analysis, and truncation helpers.

  `PgInspect` exposes two public layers:

  - raw AST I/O with `parse/1` and `deparse/1`
  - analyzed-query helpers with `analyze/1` and accessor functions over
    `PgInspect.AnalysisResult`

  ## Examples

      iex> {:ok, ast} = PgInspect.parse("SELECT * FROM users WHERE id = $1")
      iex> match?(%PgQuery.ParseResult{}, ast)
      true

      iex> {:ok, analyzed} = PgInspect.analyze("SELECT count(*) FROM users WHERE id = $1")
      iex> PgInspect.tables(analyzed)
      ["users"]
      iex> PgInspect.functions(analyzed)
      ["count"]
      iex> PgInspect.parameter_references(analyzed)
      [%{location: 38, length: 2}]

      iex> {:ok, analyzed} = PgInspect.analyze("SELECT * INTO recent_films FROM films")
      iex> PgInspect.ddl_tables(analyzed)
      ["recent_films"]
      iex> PgInspect.select_tables(analyzed)
      ["films"]

      iex> PgInspect.truncate("SELECT id, name, email FROM users WHERE active = true", 32)
      {:ok, "SELECT ... FROM users WHERE ..."}
  """

  alias PgInspect.AnalysisResult
  alias PgInspect.Internal.Analysis
  alias PgInspect.Internal.Truncator
  alias PgInspect.Protobuf

  @type sql :: String.t()
  @type raw_ast :: PgQuery.ParseResult.t()
  @type analyze_input :: sql() | raw_ast()
  @type truncate_input :: sql() | AnalysisResult.t()

  @doc """
  Parses SQL into a raw `PgQuery.ParseResult`.

  ## Examples

      iex> {:ok, ast} = PgInspect.parse("SELECT * FROM users")
      iex> match?(%PgQuery.ParseResult{}, ast)
      true
  """
  @spec parse(sql()) :: {:ok, raw_ast()} | {:error, term()}
  def parse(query) when is_binary(query), do: Protobuf.from_sql(query)

  @doc """
  Same as `parse/1` but raises on error.
  """
  @spec parse!(sql()) :: raw_ast()
  def parse!(query) when is_binary(query), do: Protobuf.from_sql!(query)

  @doc """
  Deparses a raw `PgQuery.ParseResult` back into SQL.

  ## Examples

      iex> ast = PgInspect.parse!("SELECT * FROM users")
      iex> PgInspect.deparse(ast)
      {:ok, "SELECT * FROM users"}
  """
  @spec deparse(raw_ast()) :: {:ok, sql()} | {:error, term()}
  def deparse(%PgQuery.ParseResult{} = ast), do: Protobuf.to_sql(ast)

  @doc """
  Same as `deparse/1` but raises on error.
  """
  @spec deparse!(raw_ast()) :: sql()
  def deparse!(%PgQuery.ParseResult{} = ast), do: Protobuf.to_sql!(ast)

  @doc """
  Builds an `PgInspect.AnalysisResult` from SQL text or a raw AST.

  ## Examples

      iex> {:ok, analyzed} = PgInspect.analyze("SELECT u.name FROM users u WHERE u.id = $1")
      iex> PgInspect.table_aliases(analyzed)
      [%{alias: "u", location: 19, relation: "users", schema: nil}]
      iex> PgInspect.filter_columns(analyzed)
      [{"users", "id"}]

      iex> ast = PgInspect.parse!("SELECT * FROM posts")
      iex> {:ok, analyzed} = PgInspect.analyze(ast)
      iex> PgInspect.statement_types(analyzed)
      [:select_stmt]
  """
  @spec analyze(analyze_input()) :: {:ok, AnalysisResult.t()} | {:error, term()}
  def analyze(query) when is_binary(query) do
    case parse(query) do
      {:ok, ast} -> {:ok, Analysis.analyze(ast)}
      {:error, error} -> {:error, error}
    end
  end

  def analyze(%PgQuery.ParseResult{} = ast), do: {:ok, Analysis.analyze(ast)}

  @doc """
  Same as `analyze/1` but raises on error.
  """
  @spec analyze!(analyze_input()) :: AnalysisResult.t()
  def analyze!(input) do
    case analyze(input) do
      {:ok, analyzed} -> analyzed
      {:error, error} -> raise "Analysis error: #{inspect(error)}"
    end
  end

  @doc """
  Returns all referenced table names.
  """
  @spec tables(AnalysisResult.t()) :: [String.t()]
  def tables(%AnalysisResult{tables: tables}) do
    tables
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns table names referenced by `SELECT` statements.
  """
  @spec select_tables(AnalysisResult.t()) :: [String.t()]
  def select_tables(%AnalysisResult{tables: tables}) do
    tables
    |> Enum.filter(&(&1.type == :select))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns table names referenced by DDL statements.
  """
  @spec ddl_tables(AnalysisResult.t()) :: [String.t()]
  def ddl_tables(%AnalysisResult{tables: tables}) do
    tables
    |> Enum.filter(&(&1.type == :ddl))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns table names referenced by DML statements.
  """
  @spec dml_tables(AnalysisResult.t()) :: [String.t()]
  def dml_tables(%AnalysisResult{tables: tables}) do
    tables
    |> Enum.filter(&(&1.type == :dml))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns all referenced function names.
  """
  @spec functions(AnalysisResult.t()) :: [String.t()]
  def functions(%AnalysisResult{functions: functions}) do
    functions
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns function names referenced from callable statements.
  """
  @spec call_functions(AnalysisResult.t()) :: [String.t()]
  def call_functions(%AnalysisResult{functions: functions}) do
    functions
    |> Enum.filter(&(&1.type == :call))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns function names referenced by DDL statements.
  """
  @spec ddl_functions(AnalysisResult.t()) :: [String.t()]
  def ddl_functions(%AnalysisResult{functions: functions}) do
    functions
    |> Enum.filter(&(&1.type == :ddl))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @doc """
  Returns columns referenced from filter conditions such as `WHERE` and `JOIN ... ON`.
  """
  @spec filter_columns(AnalysisResult.t()) :: [{String.t() | nil, String.t()}]
  def filter_columns(%AnalysisResult{filter_columns: filter_columns}), do: filter_columns

  @doc """
  Returns table alias metadata.
  """
  @spec table_aliases(AnalysisResult.t()) :: [map()]
  def table_aliases(%AnalysisResult{table_aliases: table_aliases}), do: table_aliases

  @doc """
  Returns CTE names referenced in the analyzed query.
  """
  @spec cte_names(AnalysisResult.t()) :: [String.t()]
  def cte_names(%AnalysisResult{cte_names: cte_names}), do: cte_names

  @doc """
  Returns parameter reference metadata for `$n` placeholders.
  """
  @spec parameter_references(AnalysisResult.t()) :: [map()]
  def parameter_references(%AnalysisResult{parameter_references: refs}), do: refs

  @doc """
  Returns the raw statement node types in query order.
  """
  @spec statement_types(AnalysisResult.t()) :: [atom()]
  def statement_types(%AnalysisResult{statement_types: statement_types}), do: statement_types

  @doc """
  Truncates SQL text or an analyzed query to fit within `max_length`.

  ## Examples

      iex> {:ok, analyzed} = PgInspect.analyze("SELECT * FROM users WHERE name = 'very long name'")
      iex> PgInspect.truncate(analyzed, 30)
      {:ok, "SELECT * FROM users WHERE ..."}
  """
  @spec truncate(truncate_input(), integer()) :: {:ok, sql()} | {:error, term()}
  def truncate(query, max_length) when is_binary(query) and is_integer(max_length) do
    with {:ok, ast} <- parse(query) do
      Truncator.truncate(ast, max_length)
    end
  end

  def truncate(%AnalysisResult{raw_ast: %PgQuery.ParseResult{} = ast}, max_length)
      when is_integer(max_length) do
    Truncator.truncate(ast, max_length)
  end

  def truncate(%AnalysisResult{raw_ast: nil}, _max_length), do: {:error, :missing_raw_ast}

  @doc """
  Same as `truncate/2` but raises on error.
  """
  @spec truncate!(truncate_input(), integer()) :: sql()
  def truncate!(input, max_length) do
    case truncate(input, max_length) do
      {:ok, sql} -> sql
      {:error, error} -> raise "Truncation error: #{inspect(error)}"
    end
  end
end
