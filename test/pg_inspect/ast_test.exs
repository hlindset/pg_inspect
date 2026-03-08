defmodule PgInspect.Internal.ASTTest do
  use ExUnit.Case

  alias PgInspect.Internal.AST
  alias PgInspect.Internal.AST.Analysis
  alias PgInspect.Internal.AST.Visit
  alias PgInspect.Protobuf

  describe "reduce/4" do
    test "rejects non-AST roots" do
      bad_root = struct(URI)

      assert_raise FunctionClauseError, fn ->
        apply(AST, :reduce, [bad_root, [], fn %Visit{path: path}, acc -> [path | acc] end])
      end
    end

    test "reports oneof paths and breadth-first traversal order" do
      root =
        %PgQuery.Node{
          node:
            {:select_stmt,
             %PgQuery.SelectStmt{
               target_list: [
                 %PgQuery.Node{
                   node:
                     {:res_target,
                      %PgQuery.ResTarget{
                        val: %PgQuery.Node{
                          node: {:string, %PgQuery.String{sval: "value"}}
                        }
                      }}
                 }
               ]
             }}
        }

      paths =
        AST.reduce(root, [], fn %Visit{path: path}, acc -> [path | acc] end)
        |> Enum.reverse()

      assert paths == [
               [:select_stmt],
               [:select_stmt, :distinct_clause],
               [:select_stmt, :target_list],
               [:select_stmt, :from_clause],
               [:select_stmt, :group_clause],
               [:select_stmt, :window_clause],
               [:select_stmt, :values_lists],
               [:select_stmt, :sort_clause],
               [:select_stmt, :locking_clause],
               [:select_stmt, :target_list, 0],
               [:select_stmt, :target_list, 0, :res_target],
               [:select_stmt, :target_list, 0, :res_target, :indirection],
               [:select_stmt, :target_list, 0, :res_target, :val],
               [:select_stmt, :target_list, 0, :res_target, :val, :string]
             ]
    end

    test "propagates analysis through joins, conditions, and ctes" do
      {:ok, tree} =
        Protobuf.from_sql("""
        WITH x AS (SELECT * FROM source_table)
        SELECT *
        FROM public.users u
        JOIN x ON x.id = u.id
        WHERE u.active = true
        """)

      visits =
        AST.reduce(tree, [], fn %Visit{} = visit, acc -> [visit | acc] end)
        |> Enum.reverse()

      select_scope =
        Enum.find_value(visits, fn
          %Visit{node: %PgQuery.SelectStmt{}, analysis: %Analysis{} = analysis} -> analysis
          _ -> nil
        end)

      from_table_visit =
        Enum.find(visits, fn
          %Visit{
            node: %PgQuery.RangeVar{relname: "users"},
            analysis: %Analysis{in_from_clause?: true}
          } ->
            true

          _ ->
            false
        end)

      where_column_visit =
        Enum.find(visits, fn
          %Visit{
            node: %PgQuery.ColumnRef{},
            analysis: %Analysis{in_condition?: true}
          } ->
            true

          _ ->
            false
        end)

      assert %{alias: "u", relation: "users", schema: "public"} = select_scope.aliases["u"]
      assert is_integer(select_scope.aliases["u"].location)
      assert "x" in select_scope.cte_names
      assert %Visit{analysis: %Analysis{statement: :select}} = from_table_visit
      assert %Visit{} = where_column_visit
    end
  end

  describe "update/3" do
    test "updates PgQuery oneof nodes and returns typed errors" do
      tree = %PgQuery.Node{node: {:select_stmt, %PgQuery.SelectStmt{where_clause: nil}}}
      where_clause = %PgQuery.Node{node: {:column_ref, %PgQuery.ColumnRef{fields: []}}}

      assert {:ok,
              %PgQuery.Node{
                node: {:select_stmt, %PgQuery.SelectStmt{where_clause: ^where_clause}}
              }} =
               AST.update(tree, [:select_stmt, :where_clause], fn _ -> where_clause end)

      assert {:error, {:unexpected_node_type, :update_stmt, :select_stmt}} =
               AST.update(tree, [:update_stmt], fn _ -> nil end)

      assert {:error, {:non_traversable, 1, :a}} =
               AST.update(1, [:a], fn _ -> 2 end)
    end

    test "updates tuple, map, and struct paths and supports bang helpers" do
      assert {:ok, {:tag, %{value: 2}}} =
               AST.update({:tag, %{value: 1}}, [:value], &(&1 + 1))

      assert {:ok, %{outer: %{value: 2}}} =
               AST.update(%{outer: %{value: 1}}, [:outer, :value], &(&1 + 1))

      assert {:error, {:index_out_of_bounds, 2}} =
               AST.update([1], [2], fn value -> value end)

      assert {:error, {:missing_key, :missing}} =
               AST.update(%URI{}, [:missing], fn value -> value end)

      assert {:error, {:missing_key, :missing}} =
               AST.update(%{value: 1}, [:missing], fn value -> value end)

      assert AST.update!(%{outer: %{value: 1}}, [:outer, :value], &(&1 + 1)) ==
               %{outer: %{value: 2}}

      assert AST.put!(%{outer: %{value: 1}}, [:outer, :value], 3) == %{outer: %{value: 3}}
    end

    test "formats update errors for bang helpers" do
      assert AST.format_error({:index_out_of_bounds, 2}) == "index 2 out of bounds"
      assert AST.format_error({:missing_key, :field}) == "key field not found"

      assert AST.format_error({:unexpected_node_type, :select_stmt, :update_stmt}) ==
               "expected node type select_stmt but found update_stmt"

      assert_raise ArgumentError, "cannot traverse segment :a through 1", fn ->
        AST.update!(1, [:a], fn _ -> 2 end)
      end
    end
  end
end
