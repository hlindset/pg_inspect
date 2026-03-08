defmodule ExPgQuery.Analysis do
  @moduledoc false

  alias ExPgQuery.AST
  alias ExPgQuery.AST.Analysis, as: Scope
  alias ExPgQuery.AST.Visit
  alias ExPgQuery.ParseResult

  @spec analyze(PgQuery.ParseResult.t()) :: ParseResult.t()
  def analyze(%PgQuery.ParseResult{} = tree) do
    tree
    |> AST.reduce(%ParseResult{tree: tree}, &collect_visit/2)
    |> uniq_result()
  end

  defp collect_visit(%Visit{} = visit, %ParseResult{} = result) do
    result
    |> collect_scope_metadata(visit)
    |> collect_drop_objects(visit)
    |> collect_filter_columns(visit)
    |> collect_tables(visit)
    |> collect_functions(visit)
  end

  defp collect_scope_metadata(
         %ParseResult{} = result,
         %Visit{
           analysis: %Scope{} = scope,
           node: node
         }
       )
       when is_struct(node, PgQuery.SelectStmt) or
              is_struct(node, PgQuery.UpdateStmt) or
              is_struct(node, PgQuery.MergeStmt) do
    aliases =
      scope.aliases
      |> Map.reject(fn {_alias, %{relation: relation}} -> relation in scope.cte_names end)
      |> Map.values()

    %ParseResult{
      result
      | table_aliases: result.table_aliases ++ aliases,
        cte_names: result.cte_names ++ scope.cte_names
    }
  end

  defp collect_scope_metadata(%ParseResult{} = result, _visit), do: result

  defp collect_drop_objects(
         %ParseResult{} = result,
         %Visit{
           analysis: %Scope{statement: statement},
           node: %PgQuery.DropStmt{remove_type: remove_type} = node
         }
       )
       when remove_type in [
              :OBJECT_TABLE,
              :OBJECT_VIEW,
              :OBJECT_FUNCTION,
              :OBJECT_RULE,
              :OBJECT_TRIGGER
            ] do
    node.objects
    |> Enum.map(&object_name_segments/1)
    |> Enum.reduce(result, fn object, acc ->
      collect_drop_object(acc, object, remove_type, statement)
    end)
  end

  defp collect_drop_objects(%ParseResult{} = result, _visit), do: result

  defp collect_drop_object(%ParseResult{} = result, object, remove_type, statement)
       when remove_type in [:OBJECT_TABLE, :OBJECT_VIEW] do
    table = %{name: Enum.join(object, "."), type: statement}
    %ParseResult{result | tables: [table | result.tables]}
  end

  defp collect_drop_object(%ParseResult{} = result, object, remove_type, statement)
       when remove_type in [:OBJECT_RULE, :OBJECT_TRIGGER] do
    name =
      object
      |> Enum.drop(-1)
      |> Enum.join(".")

    table = %{name: name, type: statement}
    %ParseResult{result | tables: [table | result.tables]}
  end

  defp collect_drop_object(%ParseResult{} = result, object, :OBJECT_FUNCTION, statement) do
    function = %{name: Enum.join(object, "."), type: statement}
    %ParseResult{result | functions: [function | result.functions]}
  end

  defp collect_filter_columns(
         %ParseResult{} = result,
         %Visit{
           analysis: %Scope{aliases: aliases, in_condition?: true},
           node: %PgQuery.ColumnRef{} = node
         }
       ) do
    case filter_column(node, aliases) do
      nil -> result
      field -> %ParseResult{result | filter_columns: [field | result.filter_columns]}
    end
  end

  defp collect_filter_columns(%ParseResult{} = result, _visit), do: result

  defp collect_tables(
         %ParseResult{} = result,
         %Visit{
           analysis: %Scope{
             statement: statement,
             cte_names: cte_names,
             current_cte: current_cte,
             recursive_cte?: recursive_cte?,
             in_from_clause?: true
           },
           node: %PgQuery.RangeVar{} = node
         }
       ) do
    table_name = table_name(node)
    cte_reference? = table_name in cte_names or current_cte == table_name

    cond do
      cte_reference? and is_nil(current_cte) ->
        result

      cte_reference? and current_cte == table_name and recursive_cte? ->
        result

      true ->
        table = %{
          name: table_name,
          type: statement,
          location: node.location,
          schemaname: blank_to_nil(node.schemaname),
          relname: node.relname,
          inh: node.inh,
          relpersistence: node.relpersistence
        }

        %ParseResult{result | tables: [table | result.tables]}
    end
  end

  defp collect_tables(%ParseResult{} = result, _visit), do: result

  defp collect_functions(
         %ParseResult{} = result,
         %Visit{
           analysis: %Scope{statement: statement},
           node: node
         }
       )
       when is_struct(node, PgQuery.FuncCall) or is_struct(node, PgQuery.CreateFunctionStmt) do
    function = %{name: function_name(node.funcname), type: statement}
    %ParseResult{result | functions: [function | result.functions]}
  end

  defp collect_functions(
         %ParseResult{} = result,
         %Visit{
           analysis: %Scope{statement: statement},
           node: %PgQuery.RenameStmt{
             rename_type: :OBJECT_FUNCTION,
             newname: newname,
             object: %PgQuery.Node{
               node:
                 {:object_with_args,
                  %PgQuery.ObjectWithArgs{
                    objname: objname
                  }}
             }
           }
         }
       ) do
    original_name = function_name(objname)
    functions = [%{name: original_name, type: statement}, %{name: newname, type: statement}]
    %ParseResult{result | functions: functions ++ result.functions}
  end

  defp collect_functions(%ParseResult{} = result, _visit), do: result

  defp filter_column(%PgQuery.ColumnRef{fields: fields}, aliases) do
    names =
      fields
      |> Enum.filter(fn
        %PgQuery.Node{node: {:string, _}} -> true
        _ -> false
      end)
      |> Enum.map(fn %PgQuery.Node{node: {:string, %PgQuery.String{sval: sval}}} -> sval end)

    case names do
      [table_alias, field] ->
        case Map.get(aliases, table_alias) do
          nil -> {table_alias, field}
          alias_info -> {alias_to_name(alias_info), field}
        end

      [field] ->
        {nil, field}

      _ ->
        nil
    end
  end

  defp object_name_segments(%PgQuery.Node{node: {:list, %PgQuery.List{items: items}}}) do
    Enum.map(items, &string_value/1)
  end

  defp object_name_segments(%PgQuery.Node{
         node: {:object_with_args, %PgQuery.ObjectWithArgs{objname: objname}}
       }) do
    Enum.map(objname, &string_value/1)
  end

  defp object_name_segments(%PgQuery.Node{node: {:string, %PgQuery.String{sval: sval}}}),
    do: [sval]

  defp function_name(parts) do
    Enum.map_join(parts, ".", &string_value/1)
  end

  defp string_value(%PgQuery.Node{node: {:string, %PgQuery.String{sval: sval}}}), do: sval
  defp string_value(_node), do: nil

  defp table_name(%PgQuery.RangeVar{schemaname: "", relname: relname}), do: relname

  defp table_name(%PgQuery.RangeVar{schemaname: schemaname, relname: relname}),
    do: "#{schemaname}.#{relname}"

  defp alias_to_name(%{relation: relation, schema: nil}), do: relation
  defp alias_to_name(%{relation: relation, schema: schema}), do: "#{schema}.#{relation}"

  defp uniq_result(%ParseResult{} = result) do
    %ParseResult{
      result
      | tables: Enum.uniq(result.tables),
        cte_names: Enum.uniq(result.cte_names),
        functions: Enum.uniq(result.functions),
        table_aliases: Enum.uniq(result.table_aliases),
        filter_columns: Enum.uniq(result.filter_columns)
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
