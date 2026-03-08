defmodule Mix.Tasks.Benchmark.PublicApi do
  use Mix.Task

  @shortdoc "Benchmarks the public PgInspect API"

  @moduledoc """
  Benchmarks the public `PgInspect` API with representative SQL fixtures.

      mix benchmark.public_api
      mix benchmark.public_api --warmup 0.5 --time 2 --memory-time 0

  The benchmark is grouped into:

  - SQL entry points such as `PgInspect.parse/1`, `PgInspect.analyze/1`,
    `PgInspect.truncate/2`, normalization, and fingerprinting
  - AST entry points such as `PgInspect.deparse/1` and `PgInspect.Protobuf.to_sql/1`
  - analysis result accessors such as `PgInspect.tables/1`
  """

  @switches [time: :float, warmup: :float, memory_time: :float]
  @aliases [t: :time, w: :warmup]
  @defaults [time: 3.0, warmup: 1.0, memory_time: 1.0]

  @impl Mix.Task
  def run(args) do
    ensure_benchee!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    case invalid do
      [] -> :ok
      _ -> Mix.raise("invalid options: #{format_invalid_options(invalid)}")
    end

    Mix.Task.run("app.start")

    fixtures = fixtures()
    benchee_options = benchee_options(Keyword.merge(@defaults, opts))

    Mix.shell().info("== SQL entry points ==")
    run_benchee(sql_jobs(), Keyword.merge(benchee_options, inputs: fixtures))

    Mix.shell().info("\n== AST entry points ==")
    run_benchee(ast_jobs(), Keyword.merge(benchee_options, inputs: fixtures))

    Mix.shell().info("\n== Analysis accessors ==")
    run_benchee(analysis_jobs(), Keyword.merge(benchee_options, inputs: fixtures))
  end

  defp ensure_benchee! do
    if Code.ensure_loaded?(Benchee) do
      :ok
    else
      Mix.raise("Benchee is not available. Run `mix deps.get` in the `dev` environment first.")
    end
  end

  defp benchee_options(options) do
    [
      time: options[:time],
      warmup: options[:warmup],
      memory_time: options[:memory_time],
      print: [fast_warning: false]
    ]
  end

  defp run_benchee(jobs, options) do
    apply(Benchee, :run, [jobs, options])
  end

  defp fixtures do
    for fixture <- raw_fixtures(), into: %{} do
      ast = PgInspect.parse!(fixture.sql)
      analyzed = PgInspect.analyze!(ast)

      {fixture.name,
       %{
         sql: fixture.sql,
         ast: ast,
         analyzed: analyzed,
         truncate_length: fixture.truncate_length
       }}
    end
  end

  defp raw_fixtures do
    [
      %{
        name: "simple_select",
        sql: "SELECT * FROM users WHERE id = $1",
        truncate_length: 24
      },
      %{
        name: "cte_aggregate",
        sql: """
        WITH recent_posts AS (
          SELECT *
          FROM posts
          WHERE author_id = $1
        )
        SELECT count(*)
        FROM recent_posts rp
        WHERE rp.inserted_at > $2::timestamptz
        """,
        truncate_length: 56
      },
      %{
        name: "multi_statement",
        sql: """
        BEGIN;
        UPDATE users SET status = 'active' WHERE id = 1;
        INSERT INTO audit_log (user_id, action) VALUES (1, 'status_update');
        COMMIT;
        """,
        truncate_length: 80
      }
    ]
  end

  defp sql_jobs do
    %{
      "PgInspect.parse/1" => fn fixture -> PgInspect.parse(fixture.sql) end,
      "PgInspect.analyze/1 (sql)" => fn fixture -> PgInspect.analyze(fixture.sql) end,
      "PgInspect.truncate/2 (sql)" => fn fixture ->
        PgInspect.truncate(fixture.sql, fixture.truncate_length)
      end,
      "PgInspect.Protobuf.from_sql/1" => fn fixture ->
        PgInspect.Protobuf.from_sql(fixture.sql)
      end,
      "PgInspect.Normalize.normalize/1" => fn fixture ->
        PgInspect.Normalize.normalize(fixture.sql)
      end,
      "PgInspect.Fingerprint.fingerprint/1" => fn fixture ->
        PgInspect.Fingerprint.fingerprint(fixture.sql)
      end
    }
  end

  defp ast_jobs do
    %{
      "PgInspect.deparse/1" => fn fixture -> PgInspect.deparse(fixture.ast) end,
      "PgInspect.analyze/1 (ast)" => fn fixture -> PgInspect.analyze(fixture.ast) end,
      "PgInspect.Protobuf.to_sql/1" => fn fixture -> PgInspect.Protobuf.to_sql(fixture.ast) end
    }
  end

  defp analysis_jobs do
    %{
      "PgInspect.tables/1" => fn fixture -> PgInspect.tables(fixture.analyzed) end,
      "PgInspect.cte_names/1" => fn fixture -> PgInspect.cte_names(fixture.analyzed) end,
      "PgInspect.functions/1" => fn fixture -> PgInspect.functions(fixture.analyzed) end,
      "PgInspect.filter_columns/1" => fn fixture -> PgInspect.filter_columns(fixture.analyzed) end,
      "PgInspect.parameter_references/1" => fn fixture ->
        PgInspect.parameter_references(fixture.analyzed)
      end,
      "PgInspect.statement_types/1" => fn fixture ->
        PgInspect.statement_types(fixture.analyzed)
      end,
      "PgInspect.truncate/2 (analysis)" => fn fixture ->
        PgInspect.truncate(fixture.analyzed, fixture.truncate_length)
      end
    }
  end

  defp format_invalid_options(invalid) do
    invalid
    |> Enum.map(fn {option, _value} -> "--#{option}" end)
    |> Enum.join(", ")
  end
end
