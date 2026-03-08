defmodule ExPgQuery.NodeTraversal do
  @moduledoc """
  Legacy compatibility wrapper around the unified AST traversal engine.

  Returns each AST node together with the analysis context active at that node.
  """

  alias ExPgQuery.AST
  alias ExPgQuery.AST.Analysis
  alias ExPgQuery.AST.Visit

  defmodule Ctx do
    @moduledoc """
    Compatibility context returned by `nodes/1`.
    """

    @type stmt_type :: :none | :select | :dml | :ddl | :call

    defstruct type: :none,
              current_cte: nil,
              is_recursive_cte: false,
              subselect_item: false,
              from_clause_item: false,
              condition_item: false,
              table_aliases: %{},
              cte_names: []
  end

  @doc """
  Traverses a `PgQuery.ParseResult` tree and returns a list of nodes with
  their context.
  """
  def nodes(%PgQuery.ParseResult{} = parse_result) do
    parse_result
    |> AST.reduce([], &collect_node/2)
    |> Enum.reverse()
  end

  defp collect_node(
         %Visit{
           analysis: %Analysis{} = analysis,
           node: node
         },
         acc
       )
       when is_struct(node) and
              node.__struct__ not in [PgQuery.ParseResult, PgQuery.RawStmt, PgQuery.Node] do
    [{node, to_ctx(analysis)} | acc]
  end

  defp collect_node(%Visit{}, acc), do: acc

  defp to_ctx(%Analysis{} = analysis) do
    %Ctx{
      type: analysis.statement,
      current_cte: analysis.current_cte,
      is_recursive_cte: analysis.recursive_cte?,
      subselect_item: analysis.in_subquery?,
      from_clause_item: analysis.in_from_clause?,
      condition_item: analysis.in_condition?,
      table_aliases: analysis.aliases,
      cte_names: analysis.cte_names
    }
  end
end
