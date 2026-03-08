defmodule PgInspect.PublicApiTest do
  use ExUnit.Case

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
