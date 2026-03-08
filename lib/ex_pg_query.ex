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
      {:ok, ast} ->
        {:ok, Analysis.analyze(ast)}

      {:error, error} ->
        maybe_analyze_question_mark_query(query, error)
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
  Returns parameter reference metadata for `$n` and `?` placeholders.
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

  defp maybe_analyze_question_mark_query(query, original_error) do
    with true <- String.contains?(query, "?"),
         {:ok, rewritten_query, insertions} <- rewrite_question_mark_placeholders(query),
         {:ok, ast} <- parse(rewritten_query) do
      analyzed =
        ast
        |> Analysis.analyze()
        |> remap_rewritten_locations(insertions)

      {:ok, analyzed}
    else
      _ -> {:error, original_error}
    end
  end

  defp remap_rewritten_locations(%AnalysisResult{} = analyzed, []), do: analyzed

  defp remap_rewritten_locations(%AnalysisResult{} = analyzed, insertions) do
    %AnalysisResult{
      analyzed
      | raw_ast: nil,
        tables: Enum.map(analyzed.tables, &remap_location_field(&1, insertions)),
        table_aliases: Enum.map(analyzed.table_aliases, &remap_location_field(&1, insertions)),
        parameter_references:
          Enum.map(analyzed.parameter_references, &remap_location_field(&1, insertions))
    }
  end

  defp remap_location_field(%{location: location} = item, insertions) when is_integer(location) do
    %{item | location: rewritten_to_original_location(location, insertions)}
  end

  defp remap_location_field(item, _insertions), do: item

  defp rewritten_to_original_location(location, insertions) do
    location -
      Enum.count(insertions, fn rewritten_location ->
        rewritten_location < location
      end)
  end

  defp rewrite_question_mark_placeholders(query) do
    {rewritten, insertions} = do_rewrite_question_mark_placeholders(query, 0, :normal, [], [], 0)

    case insertions do
      [] -> :error
      _ -> {:ok, IO.iodata_to_binary(Enum.reverse(rewritten)), Enum.reverse(insertions)}
    end
  end

  defp do_rewrite_question_mark_placeholders(
         <<>>,
         _offset,
         _state,
         rewritten,
         insertions,
         _length
       ) do
    {rewritten, insertions}
  end

  defp do_rewrite_question_mark_placeholders(
         <<"--", rest::binary>>,
         offset,
         :normal,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 2,
      :line_comment,
      ["--" | rewritten],
      insertions,
      length + 2
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"/*", rest::binary>>,
         offset,
         :normal,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 2,
      {:block_comment, 1},
      ["/*" | rewritten],
      insertions,
      length + 2
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"'", rest::binary>>,
         offset,
         :normal,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 1,
      :single_quote,
      ["'" | rewritten],
      insertions,
      length + 1
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"\"", rest::binary>>,
         offset,
         :normal,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 1,
      :double_quote,
      ["\"" | rewritten],
      insertions,
      length + 1
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"$", rest::binary>> = binary,
         offset,
         :normal,
         rewritten,
         insertions,
         length
       ) do
    case dollar_quote_delimiter(binary) do
      {delimiter, size} ->
        do_rewrite_question_mark_placeholders(
          binary_part(binary, size, byte_size(binary) - size),
          offset + size,
          {:dollar_quote, delimiter},
          [delimiter | rewritten],
          insertions,
          length + size
        )

      nil ->
        do_rewrite_question_mark_placeholders(
          rest,
          offset + 1,
          :normal,
          ["$" | rewritten],
          insertions,
          length + 1
        )
    end
  end

  defp do_rewrite_question_mark_placeholders(
         <<"?", rest::binary>>,
         offset,
         :normal,
         rewritten,
         insertions,
         length
       ) do
    next_char = next_char(rest)
    prev_char = prev_char(rewritten)

    if question_mark_placeholder?(prev_char, next_char) do
      do_rewrite_question_mark_placeholders(
        rest,
        offset + 1,
        :normal,
        ["$0" | rewritten],
        [length | insertions],
        length + 2
      )
    else
      do_rewrite_question_mark_placeholders(
        rest,
        offset + 1,
        :normal,
        ["?" | rewritten],
        insertions,
        length + 1
      )
    end
  end

  defp do_rewrite_question_mark_placeholders(
         <<"\n", rest::binary>>,
         offset,
         :line_comment,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 1,
      :normal,
      ["\n" | rewritten],
      insertions,
      length + 1
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"/*", rest::binary>>,
         offset,
         {:block_comment, depth},
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 2,
      {:block_comment, depth + 1},
      ["/*" | rewritten],
      insertions,
      length + 2
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"*/", rest::binary>>,
         offset,
         {:block_comment, 1},
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 2,
      :normal,
      ["*/" | rewritten],
      insertions,
      length + 2
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"*/", rest::binary>>,
         offset,
         {:block_comment, depth},
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 2,
      {:block_comment, depth - 1},
      ["*/" | rewritten],
      insertions,
      length + 2
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"''", rest::binary>>,
         offset,
         :single_quote,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 2,
      :single_quote,
      ["''" | rewritten],
      insertions,
      length + 2
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"'", rest::binary>>,
         offset,
         :single_quote,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 1,
      :normal,
      ["'" | rewritten],
      insertions,
      length + 1
    )
  end

  defp do_rewrite_question_mark_placeholders(
         <<"\"", rest::binary>>,
         offset,
         :double_quote,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 1,
      :normal,
      ["\"" | rewritten],
      insertions,
      length + 1
    )
  end

  defp do_rewrite_question_mark_placeholders(
         binary,
         offset,
         {:dollar_quote, delimiter},
         rewritten,
         insertions,
         length
       ) do
    delimiter_size = byte_size(delimiter)

    if byte_size(binary) >= delimiter_size and binary_part(binary, 0, delimiter_size) == delimiter do
      do_rewrite_question_mark_placeholders(
        binary_part(binary, delimiter_size, byte_size(binary) - delimiter_size),
        offset + delimiter_size,
        :normal,
        [delimiter | rewritten],
        insertions,
        length + delimiter_size
      )
    else
      <<char::binary-size(1), rest::binary>> = binary

      do_rewrite_question_mark_placeholders(
        rest,
        offset + 1,
        {:dollar_quote, delimiter},
        [char | rewritten],
        insertions,
        length + 1
      )
    end
  end

  defp do_rewrite_question_mark_placeholders(
         <<char::binary-size(1), rest::binary>>,
         offset,
         state,
         rewritten,
         insertions,
         length
       ) do
    do_rewrite_question_mark_placeholders(
      rest,
      offset + 1,
      state,
      [char | rewritten],
      insertions,
      length + 1
    )
  end

  defp dollar_quote_delimiter(<<"$", rest::binary>>) do
    case :binary.match(rest, "$") do
      {match_index, 1} ->
        delimiter_size = match_index + 2
        delimiter = binary_part(<<"$", rest::binary>>, 0, delimiter_size)

        if delimiter =~ ~r/^\$[A-Za-z0-9_]*\$$/ do
          {delimiter, delimiter_size}
        else
          nil
        end

      :nomatch ->
        nil
    end
  end

  defp next_char(<<>>), do: nil
  defp next_char(<<char::binary-size(1), _rest::binary>>), do: char

  defp prev_char([]), do: nil
  defp prev_char([head | _tail]), do: iodata_last_char(head)

  defp iodata_last_char(binary) when is_binary(binary) do
    binary_part(binary, byte_size(binary) - 1, 1)
  end

  defp question_mark_placeholder?(prev_char, next_char) do
    safe_prev? =
      is_nil(prev_char) or
        prev_char in [
          " ",
          "\n",
          "\t",
          "\r",
          "(",
          ",",
          "[",
          "{",
          "=",
          "<",
          ">",
          "+",
          "-",
          "*",
          "/",
          "%",
          "!"
        ]

    safe_next? =
      is_nil(next_char) or
        next_char in [
          " ",
          "\n",
          "\t",
          "\r",
          ")",
          ",",
          "]",
          "}",
          ";",
          ":",
          "+",
          "-",
          "*",
          "/",
          "%",
          "!"
        ]

    safe_prev? and safe_next?
  end
end
