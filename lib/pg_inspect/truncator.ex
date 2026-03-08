defmodule PgInspect.Internal.Truncator do
  @moduledoc false

  alias PgInspect.Internal.AST
  alias PgInspect.Internal.AST.Visit
  alias PgInspect.Protobuf

  defmodule PossibleTruncation do
    @moduledoc false

    defstruct [:parent_node, :location, :node_type, :length]
  end

  @short_ellipsis "..."
  @placeholder "__pg_inspect_truncation_sentinel__"
  @short_ellipsis_length String.length(@short_ellipsis)

  @dummy_column_ref %PgQuery.Node{
    node:
      {:column_ref,
       %PgQuery.ColumnRef{
         fields: [%PgQuery.Node{node: {:string, %PgQuery.String{sval: @placeholder}}}]
       }}
  }
  @dummy_column_ref_list [@dummy_column_ref]
  @dummy_ctequery_node %PgQuery.Node{
    node: {:select_stmt, %PgQuery.SelectStmt{where_clause: @dummy_column_ref, op: :SETOP_NONE}}
  }
  @dummy_cols_list [%PgQuery.Node{node: {:res_target, %PgQuery.ResTarget{name: @placeholder}}}]
  @dummy_values_list [%PgQuery.Node{node: {:list, %PgQuery.List{items: [@dummy_column_ref]}}}]
  @dummy_named_target_list [
    %PgQuery.Node{
      node: {:res_target, %PgQuery.ResTarget{name: @placeholder, val: @dummy_column_ref}}
    }
  ]
  @dummy_unnamed_target_list [
    %PgQuery.Node{
      node: {:res_target, %PgQuery.ResTarget{name: "", val: @dummy_column_ref}}
    }
  ]

  def truncate(%PgQuery.ParseResult{} = tree, max_length) when is_integer(max_length) do
    with {:ok, {length, output}} <- query_length(tree) do
      if length <= max_length do
        {:ok, output}
      else
        do_truncate(tree, max_length)
      end
    end
  end

  def truncate!(tree, max_length) do
    case truncate(tree, max_length) do
      {:ok, output} -> output
      {:error, error} -> raise "Truncation error: #{inspect(error)}"
    end
  end

  defp do_truncate(tree, max_length) do
    truncations =
      tree
      |> find_possible_truncations()
      |> Enum.reject(&(&1.length < @short_ellipsis_length))
      |> Enum.sort_by(&{length(&1.location) * -1, &1.length * -1})

    case try_smart_truncation(tree, truncations, max_length) do
      {:ok, {length, output}} when length <= max_length ->
        {:ok, output}

      {:ok, {_length, output}} ->
        {:ok, hard_truncate(output, max_length)}

      {:error, _} = error ->
        error
    end
  end

  defp try_smart_truncation(tree, truncations, max_length) do
    final_tree =
      Enum.reduce_while(truncations, {:ok, tree}, fn truncation, {:ok, tree_acc} ->
        with {:ok, updated_tree} <- update_tree(tree_acc, truncation),
             {:ok, {length, _output}} <- query_length(updated_tree) do
          if length > max_length do
            {:cont, {:ok, updated_tree}}
          else
            {:halt, {:ok, updated_tree}}
          end
        end
      end)

    with {:ok, final_tree} <- final_tree do
      query_length(final_tree)
    end
  end

  defp update_tree(tree, %PossibleTruncation{} = truncation) do
    case replacement_for(truncation) do
      nil ->
        {:error, {:unhandled_truncation, truncation}}

      replacement ->
        AST.put(tree, truncation.location, replacement)
    end
  end

  defp replacement_for(%PossibleTruncation{node_type: :target_list, parent_node: parent_node})
       when is_struct(parent_node, PgQuery.UpdateStmt) or
              is_struct(parent_node, PgQuery.OnConflictClause) do
    @dummy_named_target_list
  end

  defp replacement_for(%PossibleTruncation{node_type: :target_list}),
    do: @dummy_unnamed_target_list

  defp replacement_for(%PossibleTruncation{node_type: :group_clause}), do: @dummy_column_ref_list
  defp replacement_for(%PossibleTruncation{node_type: :where_clause}), do: @dummy_column_ref
  defp replacement_for(%PossibleTruncation{node_type: :values_lists}), do: @dummy_values_list
  defp replacement_for(%PossibleTruncation{node_type: :ctequery}), do: @dummy_ctequery_node
  defp replacement_for(%PossibleTruncation{node_type: :cols}), do: @dummy_cols_list
  defp replacement_for(_truncation), do: nil

  defp find_possible_truncations(tree) do
    AST.reduce(tree, [], fn %Visit{} = visit, acc ->
      case candidate_for_visit(visit) do
        nil -> acc
        candidate -> [candidate | acc]
      end
    end)
  end

  defp candidate_for_visit(%Visit{} = visit) do
    Enum.find_value(candidate_specs(), fn spec ->
      if spec.field == visit.field and spec.match?.(visit) do
        case spec.length.(visit) do
          {:ok, length} ->
            %PossibleTruncation{
              parent_node: visit.parent,
              location: visit.path,
              node_type: spec.node_type,
              length: length
            }

          {:error, _reason} ->
            nil
        end
      end
    end)
  end

  defp candidate_specs do
    [
      %{
        field: :target_list,
        node_type: :target_list,
        match?: fn %Visit{parent: parent} ->
          is_struct(parent, PgQuery.SelectStmt) or
            is_struct(parent, PgQuery.UpdateStmt) or
            is_struct(parent, PgQuery.OnConflictClause)
        end,
        length: fn %Visit{parent: parent, node: node} ->
          case parent do
            %PgQuery.SelectStmt{} -> select_target_list_length(node)
            _ -> update_target_list_length(node)
          end
        end
      },
      %{
        field: :group_clause,
        node_type: :group_clause,
        match?: fn _visit -> true end,
        length: fn %Visit{node: node} -> group_clause_length(node) end
      },
      %{
        field: :where_clause,
        node_type: :where_clause,
        match?: fn %Visit{parent: parent} ->
          is_struct(parent, PgQuery.SelectStmt) or
            is_struct(parent, PgQuery.UpdateStmt) or
            is_struct(parent, PgQuery.DeleteStmt) or
            is_struct(parent, PgQuery.CopyStmt) or
            is_struct(parent, PgQuery.IndexStmt) or
            is_struct(parent, PgQuery.RuleStmt) or
            is_struct(parent, PgQuery.InferClause) or
            is_struct(parent, PgQuery.OnConflictClause)
        end,
        length: fn %Visit{node: node} -> where_clause_length(node) end
      },
      %{
        field: :values_lists,
        node_type: :values_lists,
        match?: fn %Visit{node: node} -> match?([_ | _], node) end,
        length: fn %Visit{node: node} -> select_values_lists_length(node) end
      },
      %{
        field: :ctequery,
        node_type: :ctequery,
        match?: fn %Visit{parent: parent, node: node} ->
          is_struct(parent, PgQuery.CommonTableExpr) and
            match?(%PgQuery.Node{node: {:select_stmt, _}}, node)
        end,
        length: fn
          %Visit{node: %PgQuery.Node{node: {:select_stmt, cte_select}}} ->
            cte_query_length(cte_select)

          _visit ->
            {:error, :unsupported_ctequery}
        end
      },
      %{
        field: :cols,
        node_type: :cols,
        match?: fn %Visit{parent: parent} -> is_struct(parent, PgQuery.InsertStmt) end,
        length: fn %Visit{node: node} -> cols_length(node) end
      }
    ]
  end

  defp query_length(tree) do
    with {:ok, output} <- Protobuf.to_sql(tree) do
      fixed_output = fix_output(output)
      {:ok, {String.length(fixed_output), fixed_output}}
    end
  end

  defp fix_output(output) do
    output
    |> String.replace("SELECT WHERE #{@placeholder}", @short_ellipsis)
    |> String.replace(~s|SELECT WHERE "#{@placeholder}"|, @short_ellipsis)
    |> String.replace(~s|"#{@placeholder}"|, @short_ellipsis)
    |> String.replace(@placeholder, @short_ellipsis)
  end

  defp hard_truncate(_output, max_length) when max_length <= 0, do: ""

  defp hard_truncate(_output, max_length) when max_length <= @short_ellipsis_length do
    String.slice(@short_ellipsis, 0, max_length)
  end

  defp hard_truncate(output, max_length) do
    keep_length = max(max_length - @short_ellipsis_length, 0)
    String.slice(output, 0, keep_length) <> @short_ellipsis
  end

  defp select_target_list_length(node) do
    with {:ok, query} <-
           Protobuf.stmt_to_sql(%PgQuery.SelectStmt{
             target_list: node,
             op: :SETOP_NONE
           }) do
      {:ok,
       query
       |> String.replace_leading("SELECT", "")
       |> String.trim_leading()
       |> String.length()}
    end
  end

  defp update_target_list_length(node) do
    with {:ok, query} <-
           Protobuf.stmt_to_sql(%PgQuery.UpdateStmt{
             target_list: node,
             relation: %PgQuery.RangeVar{relname: "x", inh: true}
           }) do
      {:ok,
       query
       |> String.replace_leading("UPDATE x SET", "")
       |> String.trim_leading()
       |> String.length()}
    end
  end

  defp group_clause_length(node) do
    with {:ok, query} <-
           Protobuf.stmt_to_sql(%PgQuery.SelectStmt{
             group_clause: node,
             op: :SETOP_NONE
           }) do
      {:ok,
       query
       |> String.replace_leading("SELECT GROUP BY", "")
       |> String.trim_leading()
       |> String.length()}
    end
  end

  defp where_clause_length(node) do
    case Protobuf.expr_to_sql(node) do
      {:ok, expr} -> {:ok, String.length(expr)}
      {:error, _} = error -> error
    end
  end

  defp select_values_lists_length(node) do
    with {:ok, query} <-
           Protobuf.stmt_to_sql(%PgQuery.SelectStmt{
             values_lists: node,
             op: :SETOP_NONE
           }) do
      {:ok,
       query
       |> String.replace_leading("VALUES (", "")
       |> String.replace_trailing(")", "")
       |> String.length()}
    end
  end

  defp cte_query_length(node) do
    case Protobuf.stmt_to_sql(node) do
      {:ok, expr} -> {:ok, String.length(expr)}
      {:error, _} = error -> error
    end
  end

  defp cols_length(node) do
    with {:ok, query} <-
           Protobuf.stmt_to_sql(%PgQuery.InsertStmt{
             relation: %PgQuery.RangeVar{relname: "x", inh: true},
             cols: node
           }) do
      {:ok,
       query
       |> String.replace_leading("INSERT INTO x (", "")
       |> String.replace_trailing(") DEFAULT VALUES", "")
       |> String.length()}
    end
  end
end
