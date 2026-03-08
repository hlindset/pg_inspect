defmodule PgInspect.PublicApiTest do
  use ExUnit.Case

  alias PgInspect.AnalysisResult

  describe "raw AST entry points" do
    test "parse/1 returns a raw parse result" do
      assert {:ok, %PgQuery.ParseResult{} = ast} = PgInspect.parse("SELECT * FROM users")
      assert {:ok, "SELECT * FROM users"} = PgInspect.deparse(ast)
    end

    test "analyze/1 supports raw AST input" do
      ast = PgInspect.parse!("SELECT * FROM users WHERE id = $1")

      assert {:ok, analyzed} = PgInspect.analyze(ast)
      assert PgInspect.tables(analyzed) == ["users"]
      assert PgInspect.parameter_references(analyzed) == [%{location: 31, length: 2}]
    end

    test "bang wrappers succeed for valid inputs" do
      ast = PgInspect.parse!("WITH active_users AS (SELECT * FROM users) SELECT * FROM active_users")

      assert "WITH active_users AS (SELECT * FROM users) SELECT * FROM active_users" ==
               PgInspect.deparse!(ast)

      analyzed = PgInspect.analyze!(ast)

      assert PgInspect.cte_names(analyzed) == ["active_users"]
      assert PgInspect.statement_types(analyzed) == [:select_stmt]
    end

    test "analyze!/1 raises on invalid SQL" do
      assert_raise RuntimeError, ~r/Analysis error:/, fn ->
        PgInspect.analyze!("SELECT FROM")
      end
    end
  end

  describe "truncate/2" do
    test "truncates SQL text" do
      assert {:ok, "SELECT ... FROM users WHERE ..."} =
               PgInspect.truncate(
                 "SELECT id, name, email FROM users WHERE active = true",
                 32
               )
    end

    test "truncates analyzed queries" do
      analyzed =
        PgInspect.analyze!("SELECT id, name, email FROM users WHERE active = true")

      assert {:ok, "SELECT ... FROM users WHERE ..."} = PgInspect.truncate(analyzed, 32)
      assert PgInspect.truncate!(analyzed, 32) == "SELECT ... FROM users WHERE ..."
    end

    test "truncate!/2 raises when an analyzed result has no raw ast" do
      assert_raise RuntimeError, ~r/Truncation error: :missing_raw_ast/, fn ->
        PgInspect.truncate!(%AnalysisResult{}, 20)
      end
    end
  end

  describe "removed compatibility modules" do
    test "removed modules are not loaded" do
      refute Code.ensure_loaded?(PgInspect.NodeTraversal)
      refute Code.ensure_loaded?(PgInspect.TreeWalker)
      refute Code.ensure_loaded?(PgInspect.TreeUtils)
      refute Code.ensure_loaded?(PgInspect.ParamRefs)
    end
  end
end
