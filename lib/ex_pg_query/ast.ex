defmodule ExPgQuery.AST do
  @moduledoc false

  @type path_segment :: atom() | non_neg_integer()
  @type path :: [path_segment()]

  @type update_error ::
          {:index_out_of_bounds, integer()}
          | {:missing_key, atom()}
          | {:non_traversable, term(), path_segment()}
          | {:unexpected_node_type, atom(), atom()}

  defmodule Analysis do
    @moduledoc false

    @type statement :: :none | :select | :dml | :ddl | :call

    @default_statement %{
      PgQuery.SelectStmt => :select,
      PgQuery.CopyStmt => :dml,
      PgQuery.DeleteStmt => :dml,
      PgQuery.InsertStmt => :dml,
      PgQuery.MergeStmt => :dml,
      PgQuery.UpdateStmt => :dml,
      PgQuery.AlterDatabaseRefreshCollStmt => :ddl,
      PgQuery.AlterDatabaseSetStmt => :ddl,
      PgQuery.AlterDatabaseStmt => :ddl,
      PgQuery.AlterEnumStmt => :ddl,
      PgQuery.AlterEventTrigStmt => :ddl,
      PgQuery.AlterExtensionContentsStmt => :ddl,
      PgQuery.AlterExtensionStmt => :ddl,
      PgQuery.AlterFdwStmt => :ddl,
      PgQuery.AlterForeignServerStmt => :ddl,
      PgQuery.AlterFunctionStmt => :ddl,
      PgQuery.AlterObjectDependsStmt => :ddl,
      PgQuery.AlterObjectSchemaStmt => :ddl,
      PgQuery.AlterOperatorStmt => :ddl,
      PgQuery.AlterOpFamilyStmt => :ddl,
      PgQuery.AlterOwnerStmt => :ddl,
      PgQuery.AlterPolicyStmt => :ddl,
      PgQuery.AlterPublicationStmt => :ddl,
      PgQuery.AlterRoleSetStmt => :ddl,
      PgQuery.AlterRoleStmt => :ddl,
      PgQuery.AlterSeqStmt => :ddl,
      PgQuery.AlterStatsStmt => :ddl,
      PgQuery.AlterSubscriptionStmt => :ddl,
      PgQuery.AlterSystemStmt => :ddl,
      PgQuery.AlterTableMoveAllStmt => :ddl,
      PgQuery.AlterTableSpaceOptionsStmt => :ddl,
      PgQuery.AlterTableStmt => :ddl,
      PgQuery.AlterTSConfigurationStmt => :ddl,
      PgQuery.AlterTSDictionaryStmt => :ddl,
      PgQuery.AlterTypeStmt => :ddl,
      PgQuery.AlterUserMappingStmt => :ddl,
      PgQuery.ClusterStmt => :ddl,
      PgQuery.CompositeTypeStmt => :ddl,
      PgQuery.CreateAmStmt => :ddl,
      PgQuery.CreateCastStmt => :ddl,
      PgQuery.CreateConversionStmt => :ddl,
      PgQuery.CreatedbStmt => :ddl,
      PgQuery.CreateDomainStmt => :ddl,
      PgQuery.CreateEnumStmt => :ddl,
      PgQuery.CreateEventTrigStmt => :ddl,
      PgQuery.CreateExtensionStmt => :ddl,
      PgQuery.CreateFdwStmt => :ddl,
      PgQuery.CreateForeignServerStmt => :ddl,
      PgQuery.CreateForeignTableStmt => :ddl,
      PgQuery.CreateFunctionStmt => :ddl,
      PgQuery.CreateOpClassStmt => :ddl,
      PgQuery.CreateOpFamilyStmt => :ddl,
      PgQuery.CreatePLangStmt => :ddl,
      PgQuery.CreatePolicyStmt => :ddl,
      PgQuery.CreatePublicationStmt => :ddl,
      PgQuery.CreateRangeStmt => :ddl,
      PgQuery.CreateRoleStmt => :ddl,
      PgQuery.CreateSchemaStmt => :ddl,
      PgQuery.CreateSeqStmt => :ddl,
      PgQuery.CreateStatsStmt => :ddl,
      PgQuery.CreateStmt => :ddl,
      PgQuery.CreateSubscriptionStmt => :ddl,
      PgQuery.CreateTableAsStmt => :ddl,
      PgQuery.CreateTableSpaceStmt => :ddl,
      PgQuery.CreateTransformStmt => :ddl,
      PgQuery.CreateTrigStmt => :ddl,
      PgQuery.CreateUserMappingStmt => :ddl,
      PgQuery.DefineStmt => :ddl,
      PgQuery.DropdbStmt => :ddl,
      PgQuery.DropRoleStmt => :ddl,
      PgQuery.DropStmt => :ddl,
      PgQuery.DropSubscriptionStmt => :ddl,
      PgQuery.DropTableSpaceStmt => :ddl,
      PgQuery.DropUserMappingStmt => :ddl,
      PgQuery.GrantStmt => :ddl,
      PgQuery.ImportForeignSchemaStmt => :ddl,
      PgQuery.IndexStmt => :ddl,
      PgQuery.RefreshMatViewStmt => :ddl,
      PgQuery.ReindexStmt => :ddl,
      PgQuery.RenameStmt => :ddl,
      PgQuery.RuleStmt => :ddl,
      PgQuery.TruncateStmt => :ddl,
      PgQuery.VacuumStmt => :ddl,
      PgQuery.ViewStmt => :ddl,
      PgQuery.CallStmt => :call,
      PgQuery.DoStmt => :call,
      PgQuery.ExecuteStmt => :call,
      PgQuery.AlterDefaultPrivilegesStmt => :none,
      PgQuery.CheckPointStmt => :none,
      PgQuery.ClosePortalStmt => :none,
      PgQuery.CommentStmt => :none,
      PgQuery.ConstraintsSetStmt => :none,
      PgQuery.DeallocateStmt => :none,
      PgQuery.DeclareCursorStmt => :none,
      PgQuery.DiscardStmt => :none,
      PgQuery.DropOwnedStmt => :none,
      PgQuery.ExplainStmt => :none,
      PgQuery.FetchStmt => :none,
      PgQuery.GrantRoleStmt => :none,
      PgQuery.ListenStmt => :none,
      PgQuery.LoadStmt => :none,
      PgQuery.LockStmt => :none,
      PgQuery.NotifyStmt => :none,
      PgQuery.PrepareStmt => :none,
      PgQuery.ReassignOwnedStmt => :none,
      PgQuery.SecLabelStmt => :none,
      PgQuery.TransactionStmt => :none,
      PgQuery.UnlistenStmt => :none,
      PgQuery.VariableSetStmt => :none,
      PgQuery.VariableShowStmt => :none
    }

    defstruct statement: :none,
              current_cte: nil,
              recursive_cte?: false,
              in_subquery?: false,
              in_from_clause?: false,
              in_condition?: false,
              aliases: %{},
              cte_names: []

    @type t :: %__MODULE__{
            statement: statement(),
            current_cte: String.t() | nil,
            recursive_cte?: boolean(),
            in_subquery?: boolean(),
            in_from_clause?: boolean(),
            in_condition?: boolean(),
            aliases: %{optional(String.t()) => map()},
            cte_names: [String.t()]
          }

    @spec enter_node(term(), t()) :: t()
    def enter_node(node, analysis)

    def enter_node(node, %__MODULE__{} = analysis) when is_struct(node) do
      case node do
        %PgQuery.SelectStmt{} = select_stmt ->
          aliases =
            if analysis.in_subquery? do
              collect_select_aliases(analysis.aliases, select_stmt)
            else
              collect_select_aliases(%{}, select_stmt)
            end

          cte_names = collect_cte_names(select_stmt.with_clause)
          %__MODULE__{analysis | aliases: aliases, cte_names: analysis.cte_names ++ cte_names}

        %PgQuery.InsertStmt{} = insert_stmt ->
          cte_names = collect_cte_names(insert_stmt.with_clause)
          %__MODULE__{analysis | cte_names: analysis.cte_names ++ cte_names}

        %PgQuery.UpdateStmt{} = update_stmt ->
          aliases = collect_update_aliases(update_stmt)
          cte_names = collect_cte_names(update_stmt.with_clause)
          %__MODULE__{analysis | aliases: aliases, cte_names: analysis.cte_names ++ cte_names}

        %PgQuery.DeleteStmt{} = delete_stmt ->
          cte_names = collect_cte_names(delete_stmt.with_clause)
          %__MODULE__{analysis | cte_names: analysis.cte_names ++ cte_names}

        %PgQuery.MergeStmt{} = merge_stmt ->
          aliases = collect_merge_aliases(merge_stmt)
          cte_names = collect_cte_names(merge_stmt.with_clause)
          %__MODULE__{analysis | aliases: aliases, cte_names: analysis.cte_names ++ cte_names}

        %PgQuery.FuncCall{} ->
          %__MODULE__{analysis | statement: :call}

        %PgQuery.WithClause{recursive: recursive?} ->
          %__MODULE__{analysis | recursive_cte?: recursive?}

        %PgQuery.CommonTableExpr{ctename: ctename} ->
          %__MODULE__{analysis | current_cte: ctename}

        _ ->
          case Map.get(@default_statement, node.__struct__) do
            nil -> analysis
            statement -> %__MODULE__{analysis | statement: statement}
          end
      end
    end

    def enter_node(_node, %__MODULE__{} = analysis), do: analysis

    @spec enter_field(term(), atom() | non_neg_integer(), t()) :: t()
    def enter_field(parent, field, analysis)

    def enter_field(%PgQuery.SelectStmt{}, :where_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | in_condition?: true}

    def enter_field(%PgQuery.SelectStmt{}, :into_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.SelectStmt{}, :from_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_from_clause?: true}

    def enter_field(%PgQuery.DeleteStmt{}, :where_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_condition?: true}

    def enter_field(%PgQuery.DeleteStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :dml, in_from_clause?: true}

    def enter_field(%PgQuery.DeleteStmt{}, :using_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_from_clause?: true}

    def enter_field(%PgQuery.UpdateStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :dml, in_from_clause?: true}

    def enter_field(%PgQuery.UpdateStmt{}, :where_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_condition?: true}

    def enter_field(%PgQuery.UpdateStmt{}, :from_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_from_clause?: true}

    def enter_field(%PgQuery.MergeStmt{}, :join_condition, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | in_condition?: true}

    def enter_field(%PgQuery.MergeStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :dml, in_from_clause?: true}

    def enter_field(%PgQuery.MergeStmt{}, :source_relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_from_clause?: true}

    def enter_field(%PgQuery.MergeWhenClause{}, :condition, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | in_condition?: true}

    def enter_field(%PgQuery.IndexStmt{}, :where_clause, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_condition?: true}

    def enter_field(%PgQuery.IndexStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.InsertStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :dml, in_from_clause?: true}

    def enter_field(%PgQuery.CreateStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.CreateTableAsStmt{}, :into, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.AlterTableStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.CopyStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_from_clause?: true}

    def enter_field(%PgQuery.RuleStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(
          %PgQuery.GrantStmt{objtype: :OBJECT_TABLE},
          :objects,
          %__MODULE__{} = analysis
        ),
        do: %__MODULE__{analysis | in_from_clause?: true}

    def enter_field(%PgQuery.TruncateStmt{}, :relations, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.VacuumStmt{}, :rels, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.ViewStmt{}, :view, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.RefreshMatViewStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.CreateTrigStmt{}, :relation, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :ddl, in_from_clause?: true}

    def enter_field(%PgQuery.LockStmt{}, :relations, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | statement: :select, in_from_clause?: true}

    def enter_field(%PgQuery.JoinExpr{}, :quals, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | in_condition?: true}

    def enter_field(%PgQuery.SubLink{}, _field, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | in_subquery?: true}

    def enter_field(%PgQuery.RangeSubselect{lateral: true}, _field, %__MODULE__{} = analysis),
      do: %__MODULE__{analysis | in_subquery?: true}

    def enter_field(_parent, _field, %__MODULE__{} = analysis), do: analysis

    defp collect_cte_names(%PgQuery.WithClause{ctes: ctes}) when is_list(ctes) do
      Enum.reduce(ctes, [], fn
        %PgQuery.Node{node: {:common_table_expr, %PgQuery.CommonTableExpr{ctename: ctename}}},
        cte_names ->
          [ctename | cte_names]

        _, cte_names ->
          cte_names
      end)
    end

    defp collect_cte_names(_with_clause), do: []

    defp collect_select_aliases(aliases, %PgQuery.SelectStmt{from_clause: from_clause}) do
      collect_from_clause_aliases(aliases, from_clause)
    end

    defp collect_update_aliases(%PgQuery.UpdateStmt{relation: relation, from_clause: from_clause}) do
      %{}
      |> collect_rvar_aliases(relation)
      |> collect_from_clause_aliases(from_clause)
    end

    defp collect_merge_aliases(%PgQuery.MergeStmt{
           relation: relation,
           source_relation: source_relation
         }) do
      %{}
      |> collect_rvar_aliases(relation)
      |> collect_rvar_aliases(source_relation)
    end

    defp collect_from_clause_aliases(aliases, from_clause) when is_list(from_clause) do
      Enum.reduce(from_clause, aliases, fn
        %PgQuery.Node{node: {:range_var, rvar}}, aliases_acc ->
          collect_rvar_aliases(aliases_acc, rvar)

        %PgQuery.Node{node: {:join_expr, join}}, aliases_acc ->
          collect_join_aliases(aliases_acc, join)

        _other, aliases_acc ->
          aliases_acc
      end)
    end

    defp collect_from_clause_aliases(aliases, _from_clause), do: aliases

    defp collect_rvar_aliases(
           aliases,
           %PgQuery.RangeVar{
             schemaname: schemaname,
             relname: relname,
             alias: %PgQuery.Alias{aliasname: aliasname},
             location: location
           }
         ) do
      Map.put(aliases, aliasname, %{
        schema: blank_to_nil(schemaname),
        relation: relname,
        alias: aliasname,
        location: location
      })
    end

    defp collect_rvar_aliases(aliases, %PgQuery.Node{node: {:range_var, rvar}}),
      do: collect_rvar_aliases(aliases, rvar)

    defp collect_rvar_aliases(aliases, _rvar), do: aliases

    defp collect_join_aliases(aliases, %PgQuery.JoinExpr{} = join) do
      aliases
      |> collect_from_node(join.larg)
      |> collect_from_node(join.rarg)
    end

    defp collect_from_node(aliases, %PgQuery.Node{node: {:range_var, rvar}}) do
      collect_rvar_aliases(aliases, rvar)
    end

    defp collect_from_node(aliases, %PgQuery.Node{node: {:join_expr, join}}) do
      collect_join_aliases(aliases, join)
    end

    defp collect_from_node(aliases, _node), do: aliases

    defp blank_to_nil(""), do: nil
    defp blank_to_nil(value), do: value
  end

  defmodule Visit do
    @moduledoc false

    @enforce_keys [:analysis, :field, :node, :parent, :path]
    defstruct [:analysis, :field, :node, :parent, :path]

    @type t :: %__MODULE__{
            analysis: ExPgQuery.AST.Analysis.t(),
            field: atom() | non_neg_integer(),
            node: term(),
            parent: term(),
            path: [atom() | non_neg_integer()]
          }
  end

  @spec reduce(term(), acc, (Visit.t(), acc -> acc), Analysis.t()) :: acc when acc: term()
  def reduce(tree, acc, fun, analysis \\ %Analysis{}) when is_function(fun, 2) do
    root_analysis = Analysis.enter_node(tree, analysis)
    tree |> push_children([], root_analysis, :queue.new()) |> do_reduce(acc, fun)
  end

  @spec update(term(), path(), (term() -> term())) :: {:ok, term()} | {:error, update_error()}
  def update(tree, [], update_fn) when is_function(update_fn, 1) do
    {:ok, update_fn.(tree)}
  end

  def update(tree, [index | rest], update_fn) when is_list(tree) and is_integer(index) do
    case Enum.fetch(tree, index) do
      {:ok, value} ->
        with {:ok, updated_value} <- update(value, rest, update_fn) do
          {:ok, List.replace_at(tree, index, updated_value)}
        end

      :error ->
        {:error, {:index_out_of_bounds, index}}
    end
  end

  def update(%PgQuery.Node{node: {node_type, value}}, [expected_type | rest], update_fn)
      when is_atom(expected_type) do
    if node_type == expected_type do
      with {:ok, updated_value} <- update(value, rest, update_fn) do
        {:ok, %PgQuery.Node{node: {node_type, updated_value}}}
      end
    else
      {:error, {:unexpected_node_type, expected_type, node_type}}
    end
  end

  def update({oneof_type, value}, path, update_fn) when is_atom(oneof_type) do
    with {:ok, updated_value} <- update(value, path, update_fn) do
      {:ok, {oneof_type, updated_value}}
    end
  end

  def update(%{__struct__: _} = tree, [key | rest], update_fn) when is_atom(key) do
    case fetch_key(tree, key) do
      {:ok, value} ->
        with {:ok, updated_value} <- update(value, rest, update_fn) do
          {:ok, Map.put(tree, key, updated_value)}
        end

      :error ->
        {:error, {:missing_key, key}}
    end
  end

  def update(tree, [key | rest], update_fn) when is_map(tree) and is_atom(key) do
    case Map.fetch(tree, key) do
      {:ok, value} ->
        with {:ok, updated_value} <- update(value, rest, update_fn) do
          {:ok, Map.put(tree, key, updated_value)}
        end

      :error ->
        {:error, {:missing_key, key}}
    end
  end

  def update(tree, [segment | _rest], _update_fn) do
    {:error, {:non_traversable, tree, segment}}
  end

  @spec update!(term(), path(), (term() -> term())) :: term()
  def update!(tree, path, update_fn) do
    case update(tree, path, update_fn) do
      {:ok, updated_tree} -> updated_tree
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @spec put(term(), path(), term()) :: {:ok, term()} | {:error, update_error()}
  def put(tree, path, value) do
    update(tree, path, fn _old -> value end)
  end

  @spec put!(term(), path(), term()) :: term()
  def put!(tree, path, value) do
    update!(tree, path, fn _old -> value end)
  end

  @spec format_error(update_error()) :: String.t()
  def format_error({:index_out_of_bounds, index}), do: "index #{index} out of bounds"
  def format_error({:missing_key, key}), do: "key #{key} not found"

  def format_error({:non_traversable, value, segment}) do
    "cannot traverse segment #{inspect(segment)} through #{inspect(value)}"
  end

  def format_error({:unexpected_node_type, expected, actual}) do
    "expected node type #{expected} but found #{actual}"
  end

  defp do_reduce(queue, acc, fun) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        acc

      {{:value, {parent, field, node, rev_path, analysis_before}}, queue} ->
        analysis = Analysis.enter_node(node, analysis_before)

        visit = %Visit{
          analysis: analysis,
          field: field,
          node: node,
          parent: parent,
          path: Enum.reverse(rev_path)
        }

        acc = fun.(visit, acc)
        queue = push_children(node, rev_path, analysis, queue)
        do_reduce(queue, acc, fun)
    end
  end

  defp push_children(parent, rev_path, analysis, queue) do
    parent
    |> children()
    |> Enum.reduce(queue, fn {field, child}, acc ->
      child_analysis = Analysis.enter_field(parent, field, analysis)
      :queue.in({parent, field, child, [field | rev_path], child_analysis}, acc)
    end)
  end

  defp children(list) when is_list(list) do
    Enum.with_index(list)
    |> Enum.map(fn {child, index} -> {index, child} end)
  end

  defp children(%PgQuery.Node{node: {field, child}}), do: [{field, child}]
  defp children(%PgQuery.Node{node: nil}), do: []

  defp children(%{__struct__: module} = struct) do
    module
    |> field_defs()
    |> Enum.reduce([], fn field_def, acc ->
      case extract_field_value(struct, field_def) do
        nil -> acc
        value -> [{field_def.name, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp children(_node), do: []

  defp field_defs(module) do
    if function_exported?(module, :schema, 0) do
      module.schema().fields
      |> Map.values()
      |> Enum.sort_by(& &1.tag)
      |> Enum.filter(fn
        %Protox.Field{type: {:message, _}} -> true
        _ -> false
      end)
    else
      []
    end
  end

  defp extract_field_value(struct, %Protox.Field{kind: {:oneof, oneof_field}, name: name}) do
    case Map.get(struct, oneof_field) do
      {^name, value} -> value
      _ -> nil
    end
  end

  defp extract_field_value(struct, %Protox.Field{name: name}) do
    Map.get(struct, name)
  end

  defp fetch_key(%{__struct__: _} = tree, key) do
    if Map.has_key?(tree, key) do
      {:ok, Map.get(tree, key)}
    else
      :error
    end
  end
end
