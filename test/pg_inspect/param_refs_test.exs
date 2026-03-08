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
  end
end
