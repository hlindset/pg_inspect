defmodule PgInspect.Internal.ASTTest do
  use ExUnit.Case

  alias PgInspect.Internal.AST
  alias PgInspect.Internal.AST.Analysis
  alias PgInspect.Internal.AST.Visit
  alias PgInspect.Protobuf

  describe "reduce/4" do
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
  end
end
