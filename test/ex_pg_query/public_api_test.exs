defmodule ExPgQuery.PublicApiTest do
  use ExUnit.Case

  describe "raw AST entry points" do
    test "parse/1 returns a raw parse result" do
      assert {:ok, %PgQuery.ParseResult{} = ast} = ExPgQuery.parse("SELECT * FROM users")
      assert {:ok, "SELECT * FROM users"} = ExPgQuery.deparse(ast)
    end

    test "analyze/1 supports raw AST input" do
      ast = ExPgQuery.parse!("SELECT * FROM users WHERE id = $1")

      assert {:ok, analyzed} = ExPgQuery.analyze(ast)
      assert ExPgQuery.tables(analyzed) == ["users"]
      assert ExPgQuery.parameter_references(analyzed) == [%{location: 31, length: 2}]
    end
  end

  describe "truncate/2" do
    test "truncates SQL text" do
      assert {:ok, "SELECT ... FROM users WHERE ..."} =
               ExPgQuery.truncate(
                 "SELECT id, name, email FROM users WHERE active = true",
                 32
               )
    end

    test "truncates analyzed queries" do
      analyzed =
        ExPgQuery.analyze!("SELECT id, name, email FROM users WHERE active = true")

      assert {:ok, "SELECT ... FROM users WHERE ..."} = ExPgQuery.truncate(analyzed, 32)
    end
  end

  describe "removed compatibility modules" do
    test "removed modules are not loaded" do
      refute Code.ensure_loaded?(ExPgQuery.NodeTraversal)
      refute Code.ensure_loaded?(ExPgQuery.TreeWalker)
      refute Code.ensure_loaded?(ExPgQuery.TreeUtils)
      refute Code.ensure_loaded?(ExPgQuery.ParamRefs)
    end
  end
end
