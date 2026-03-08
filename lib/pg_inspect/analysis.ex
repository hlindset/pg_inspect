defmodule PgInspect.Internal.Analysis do
  @moduledoc false

  alias PgInspect.AnalysisResult
  alias PgInspect.Internal.AST
  alias PgInspect.Internal.AST.Analysis, as: Scope
  alias PgInspect.Internal.AST.Visit

  @type collector :: (Visit.t(), AnalysisResult.t() -> AnalysisResult.t())

  @spec analyze(PgQuery.ParseResult.t(), [collector()]) :: AnalysisResult.t()
  def analyze(%PgQuery.ParseResult{} = tree, collectors \\ collectors()) do
    tree
    |> AST.reduce(%AnalysisResult{raw_ast: tree}, fn %Visit{} = visit,
                                                     %AnalysisResult{} = result ->
      Enum.reduce(collectors, result, fn collector, acc -> collector.(visit, acc) end)
    end)
    |> finalize_result()
  end

  @spec collectors() :: [collector()]
  def collectors do
    [
      &collect_statement_types/2,
      &collect_scope_metadata/2,
      &collect_drop_objects/2,
      &collect_filter_columns/2,
      &collect_tables/2,
      &collect_functions/2,
      &collect_parameter_references/2
    ]
  end

  defp collect_statement_types(
         %Visit{
           node: %PgQuery.RawStmt{stmt: %PgQuery.Node{node: {statement_type, _}}}
         },
         %AnalysisResult{} = result
       ) do
    %AnalysisResult{result | statement_types: result.statement_types ++ [statement_type]}
  end

  defp collect_statement_types(%Visit{}, %AnalysisResult{} = result), do: result

  defp collect_scope_metadata(
         %Visit{
           analysis: %Scope{} = scope,
           node: node
         },
         %AnalysisResult{} = result
       )
       when is_struct(node, PgQuery.SelectStmt) or
              is_struct(node, PgQuery.UpdateStmt) or
              is_struct(node, PgQuery.MergeStmt) do
    aliases =
      scope.aliases
      |> Map.reject(fn {_alias, %{relation: relation}} -> relation in scope.cte_names end)
      |> Map.values()

    %AnalysisResult{
      result
      | table_aliases: result.table_aliases ++ aliases,
        cte_names: result.cte_names ++ scope.cte_names
    }
  end

  defp collect_scope_metadata(%Visit{}, %AnalysisResult{} = result), do: result

  defp collect_drop_objects(
         %Visit{
           analysis: %Scope{statement: statement},
           node: %PgQuery.DropStmt{remove_type: remove_type} = node
         },
         %AnalysisResult{} = result
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

  defp collect_drop_objects(%Visit{}, %AnalysisResult{} = result), do: result

  defp collect_drop_object(%AnalysisResult{} = result, object, remove_type, statement)
       when remove_type in [:OBJECT_TABLE, :OBJECT_VIEW] do
    table = %{name: Enum.join(object, "."), type: statement}
    %AnalysisResult{result | tables: [table | result.tables]}
  end

  defp collect_drop_object(%AnalysisResult{} = result, object, remove_type, statement)
       when remove_type in [:OBJECT_RULE, :OBJECT_TRIGGER] do
    name =
      object
      |> Enum.drop(-1)
      |> Enum.join(".")

    table = %{name: name, type: statement}
    %AnalysisResult{result | tables: [table | result.tables]}
  end

  defp collect_drop_object(%AnalysisResult{} = result, object, :OBJECT_FUNCTION, statement) do
    function = %{name: Enum.join(object, "."), type: statement}
    %AnalysisResult{result | functions: [function | result.functions]}
  end

  defp collect_filter_columns(
         %Visit{
           analysis: %Scope{aliases: aliases, in_condition?: true},
           node: %PgQuery.ColumnRef{} = node
         },
         %AnalysisResult{} = result
       ) do
    case filter_column(node, aliases) do
      nil -> result
      field -> %AnalysisResult{result | filter_columns: [field | result.filter_columns]}
    end
  end

  defp collect_filter_columns(%Visit{}, %AnalysisResult{} = result), do: result

  defp collect_tables(
         %Visit{
           analysis: %Scope{
             statement: statement,
             cte_names: cte_names,
             current_cte: current_cte,
             recursive_cte?: recursive_cte?,
             in_from_clause?: true
           },
           node: %PgQuery.RangeVar{} = node
         },
         %AnalysisResult{} = result
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

        %AnalysisResult{result | tables: [table | result.tables]}
    end
  end

  defp collect_tables(%Visit{}, %AnalysisResult{} = result), do: result

  defp collect_functions(
         %Visit{
           analysis: %Scope{statement: statement},
           node: node
         },
         %AnalysisResult{} = result
       )
       when is_struct(node, PgQuery.FuncCall) or is_struct(node, PgQuery.CreateFunctionStmt) do
    function = %{name: function_name(node.funcname), type: statement}
    %AnalysisResult{result | functions: [function | result.functions]}
  end

  defp collect_functions(
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
         },
         %AnalysisResult{} = result
       ) do
    original_name = function_name(objname)
    functions = [%{name: original_name, type: statement}, %{name: newname, type: statement}]
    %AnalysisResult{result | functions: functions ++ result.functions}
  end

  defp collect_functions(%Visit{}, %AnalysisResult{} = result), do: result

  defp collect_parameter_references(
         %Visit{
           node: %PgQuery.ParamRef{} = node,
           path: path
         },
         %AnalysisResult{} = result
       ) do
    case Enum.take(path, -3) do
      [:type_cast, :arg, :param_ref] ->
        result

      _ ->
        ref = %{location: node.location, length: param_ref_length(node)}
        %AnalysisResult{result | parameter_references: [ref | result.parameter_references]}
    end
  end

  defp collect_parameter_references(
         %Visit{
           node: %PgQuery.TypeCast{
             arg: %PgQuery.Node{
               node: {:param_ref, param_ref_node}
             },
             type_name: %PgQuery.TypeName{} = type_name_node
           }
         },
         %AnalysisResult{} = result
       ) do
    length = param_ref_length(param_ref_node)
    param_loc = param_ref_node.location
    type_loc = type_name_node.location

    {length, location} =
      cond do
        param_loc == -1 ->
          {length, type_name_node.location}

        type_loc < param_loc ->
          {length + param_loc - type_loc, type_name_node.location}

        true ->
          {length, param_loc}
      end

    ref = %{
      location: location,
      length: length,
      typename: Enum.map(type_name_node.names, &string_value/1)
    }

    %AnalysisResult{result | parameter_references: [ref | result.parameter_references]}
  end

  defp collect_parameter_references(%Visit{}, %AnalysisResult{} = result), do: result

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

  defp param_ref_length(%PgQuery.ParamRef{number: 0}), do: 1
  defp param_ref_length(%PgQuery.ParamRef{number: number}), do: String.length("$#{number}")

  defp finalize_result(%AnalysisResult{} = result) do
    %AnalysisResult{
      result
      | tables: Enum.uniq(result.tables),
        cte_names: Enum.uniq(result.cte_names),
        functions: Enum.uniq(result.functions),
        table_aliases: Enum.uniq(result.table_aliases),
        filter_columns: Enum.uniq(result.filter_columns),
        parameter_references:
          result.parameter_references
          |> Enum.uniq()
          |> Enum.sort_by(& &1.location)
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
