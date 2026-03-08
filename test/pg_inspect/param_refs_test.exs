defmodule PgInspect.ParameterReferencesTest do
  use ExUnit.Case

  describe "parameter_references/1" do
    test "collects plain numbered parameters" do
      {:ok, analyzed} = PgInspect.analyze("SELECT * FROM x WHERE y = $1 AND z = $2")

      assert PgInspect.parameter_references(analyzed) == [
               %{location: 26, length: 2},
               %{location: 37, length: 2}
             ]
    end

    test "collects question-mark placeholders" do
      {:ok, analyzed} = PgInspect.analyze("SELECT * FROM x WHERE y = ? AND z = ?")

      assert PgInspect.parameter_references(analyzed) == [
               %{location: 26, length: 1},
               %{location: 36, length: 1}
             ]
    end

    test "collects explicit casts" do
      {:ok, analyzed} =
        PgInspect.analyze("SELECT * FROM x WHERE y = $1::text AND z = $2::timestamptz")

      assert PgInspect.parameter_references(analyzed) == [
               %{location: 26, length: 2, typename: ["text"]},
               %{location: 43, length: 2, typename: ["timestamptz"]}
             ]
    end

    test "uses type-name location for interval casts" do
      {:ok, analyzed} =
        PgInspect.analyze("SELECT * FROM x WHERE y = $1::text AND z < now() - INTERVAL $2")

      assert PgInspect.parameter_references(analyzed) == [
               %{location: 26, length: 2, typename: ["text"]},
               %{location: 51, length: 11, typename: ["pg_catalog", "interval"]}
             ]
    end

    test "rewrites only placeholder question marks and remaps locations to the original SQL" do
      query = """
      SELECT '?', "?", $tag$?$tag$, ?, ? -- comment ?
      FROM users
      WHERE note = 'still ?'
      """

      {:ok, analyzed} = PgInspect.analyze(query)
      refs = PgInspect.parameter_references(analyzed)

      assert analyzed.raw_ast == nil
      assert Enum.map(refs, &Map.take(&1, [:length])) == [%{length: 1}, %{length: 1}]
      assert Enum.map(refs, fn %{location: location, length: length} ->
               binary_part(query, location, length)
             end) == ["?", "?"]
    end

    test "does not rewrite question marks inside nested block comments" do
      query = """
      SELECT ?
      /* outer ? /* inner ? */ still comment ? */
      FROM users
      WHERE id = ?
      """

      {:ok, analyzed} = PgInspect.analyze(query)

      assert Enum.map(PgInspect.parameter_references(analyzed), fn %{location: location, length: length} ->
               binary_part(query, location, length)
             end) == ["?", "?"]
    end

    test "returns the original parse error when question marks appear only inside invalid quotes" do
      assert {:error, %{message: message}} = PgInspect.analyze("SELECT '?")
      assert message =~ "unterminated quoted string"
    end
  end
end
