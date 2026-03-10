defmodule Mix.Tasks.Precompile.Build do
  use Mix.Task

  alias PgInspect.Native.Precompiled
  alias Zig.Builder

  @shortdoc "Builds the supported precompiled Zigler artifacts"
  @timeout :timer.minutes(5)

  @moduledoc """
  Builds the `PgInspect.Native.Binding` precompiled artifacts for the targets
  supported by this repository.

  Unlike `mix zig.precompile`, this task only builds the targets that are known
  to work for pg_inspect's vendored `libpg_query` setup.

  Examples:

      mix precompile.build
      MIX_ENV=prod mix precompile.build
      MIX_ENV=prod mix precompile.build lib/pg_inspect/native/binding.ex
  """

  @impl Mix.Task
  def run(args) do
    file =
      case args do
        [] -> Precompiled.binding_file_relative()
        [file] -> file
        _ -> Mix.raise("expected zero or one file argument")
      end

    clean_versioned_artifacts!()

    results =
      Enum.map(Precompiled.supported_targets(), fn {arch, os, platform} ->
        compile(file, arch, os, platform)
      end)

    Mix.shell().info("""
    Built #{length(results)} precompiled artifacts:
    #{Enum.map_join(results, "\n", &"  * #{&1}")}
    """)
  end

  defp compile(file, arch, os, platform) do
    parent = self()
    callback = fn artifact -> send(parent, {:result, artifact}) end

    Application.put_env(:zigler, :precompiling, {arch, os, platform, callback})
    [{module, _}] = Code.compile_file(file)

    try do
      receive do
        {:result, artifact} ->
          artifact
      after
        @timeout ->
          Mix.raise("timed out building #{arch}-#{os}-#{platform}")
      end
    after
      Application.delete_env(:zigler, :precompiling)
      module |> Builder.staging_directory() |> File.rm_rf!()
      Process.sleep(100)
    end
  end

  defp clean_versioned_artifacts! do
    version = Mix.Project.config()[:version] |> to_string()

    Precompiled.artifact_dir()
    |> Path.join("#{Precompiled.artifact_prefix(version)}*")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end
end
