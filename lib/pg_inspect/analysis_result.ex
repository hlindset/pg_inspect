defmodule PgInspect.AnalysisResult do
  @moduledoc """
  Result returned by `PgInspect.analyze/1`.

  The supported analysis fields are:

  - `raw_ast`
  - `tables`
  - `table_aliases`
  - `cte_names`
  - `functions`
  - `filter_columns`
  - `parameter_references`
  - `statement_types`
  """

  @derive {Inspect, except: [:raw_ast]}

  @typedoc """
  High-level query analysis result. `raw_ast` preserves the original parse tree
  for operations such as `PgInspect.truncate/2`.
  """
  @type t :: %__MODULE__{
          raw_ast: PgQuery.ParseResult.t() | nil,
          tables: [map()],
          table_aliases: [map()],
          cte_names: [String.t()],
          functions: [map()],
          filter_columns: [{String.t() | nil, String.t()}],
          parameter_references: [map()],
          statement_types: [atom()]
        }

  defstruct raw_ast: nil,
            tables: [],
            table_aliases: [],
            cte_names: [],
            functions: [],
            filter_columns: [],
            parameter_references: [],
            statement_types: []
end
