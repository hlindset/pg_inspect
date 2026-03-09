defmodule Mix.Tasks.Precompile.Checksum do
  use Mix.Task

  alias PgInspect.Native.Precompiled

  @shortdoc "Writes checksum.exs for Zigler precompiled artifacts"

  @moduledoc """
  Writes the SHA256 sums for `PgInspect.Native.Binding` precompiled artifacts to
  `checksum.exs`.

  By default the task rebuilds the local Zigler precompile matrix and hashes the
  artifacts written to `lib/pg_inspect/native/lib/`.

  Examples:

      mix precompile.checksum
      mix precompile.checksum --skip-precompile
      mix precompile.checksum --from-release
      mix precompile.checksum --from-release --tag v0.1.0
      GITHUB_TOKEN=... mix precompile.checksum --from-release --tag precompile-test
      mix precompile.checksum --from-release --repo some-org/some-fork --tag v0.1.0

  Use `--skip-precompile` to rewrite `checksum.exs` from the existing artifact
  files in `lib/pg_inspect/native/lib/` without rebuilding them. Use
  `--from-release` to download the tagged GitHub release assets for the current
  version before hashing them.

  Options:

  - `--skip-precompile` reuses local artifacts already present in
    `lib/pg_inspect/native/lib/`.
  - `--from-release` downloads release assets from GitHub instead of building
    them locally.
  - `--tag TAG` overrides the default release tag. When omitted, the task uses
    `v#{Mix.Project.config()[:version]}`.
  - `--repo OWNER/REPO` overrides the default GitHub repository
    (`#{Precompiled.release_repo()}`).

  For draft GitHub releases, set `GITHUB_TOKEN` or `GH_TOKEN` so the task can
  list and download the assets through the GitHub API.

  `--from-release` uses [`Req`](https://hex.pm/packages/req).
  """

  @switches [from_release: :boolean, repo: :string, skip_precompile: :boolean, tag: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    case invalid do
      [] -> :ok
      _ -> Mix.raise("invalid options: #{format_invalid_options(invalid)}")
    end

    run_with(opts, task_config())
  end

  @doc false
  def run_with(opts, config) do
    maybe_precompile_or_download!(opts, config)

    checksums = artifact_checksums(config)
    File.write!(config.checksum_file, render_checksums(checksums))

    config.shell.info("Wrote #{length(checksums)} checksums to #{config.checksum_file}")
  end

  defp maybe_precompile_or_download!(opts, config) do
    cond do
      opts[:from_release] ->
        download_release_artifacts!(opts, config)

      opts[:skip_precompile] ->
        :ok

      true ->
        Mix.Task.reenable("zig.precompile")
        Mix.Task.run("zig.precompile", [config.binding_file])
    end
  end

  defp task_config do
    version = Mix.Project.config()[:version] |> to_string()

    %{
      artifact_dir: Precompiled.artifact_dir(),
      binding_file: Precompiled.binding_file_relative(),
      checksum_file: Precompiled.checksum_file(),
      http_get: &http_get!/2,
      module_prefix: Precompiled.module_prefix(),
      release_repo: Precompiled.release_repo(),
      shell: Mix.shell(),
      version: version
    }
  end

  defp artifact_checksums(config) do
    prefix = Precompiled.artifact_prefix(config.version)

    config.artifact_dir
    |> Path.join("#{prefix}*")
    |> Path.wildcard()
    |> Enum.map(fn path -> {artifact_triple(path, prefix), artifact_sha(path)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> case do
      [] -> Mix.raise("no precompiled artifacts found in #{config.artifact_dir}")
      entries -> entries
    end
  end

  defp download_release_artifacts!(opts, config) do
    tag = opts[:tag] || Precompiled.release_tag(config.version)
    repo = opts[:repo] || config.release_repo
    token = github_token()

    release =
      repo
      |> release_metadata_url(tag)
      |> config.http_get.(github_json_headers(token))
      |> JSON.decode!()

    assets = release_assets(release, config.version)

    case assets do
      [] ->
        Mix.raise(
          "no release artifacts found for #{repo}@#{tag} matching #{config.module_prefix}.#{config.version}.*"
        )

      _ ->
        clean_versioned_artifacts(config)
        File.mkdir_p!(config.artifact_dir)

        Enum.each(assets, fn asset ->
          download_release_asset!(asset, config, token)
        end)

        config.shell.info(
          "Downloaded #{length(assets)} release artifacts from #{repo}@#{tag} to #{config.artifact_dir}"
        )
    end
  end

  defp release_assets(%{"assets" => assets}, version) when is_list(assets) do
    assets
    |> Enum.filter(fn
      %{"name" => name} -> Precompiled.release_asset?(name, version)
      _ -> false
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp release_assets(_release, _version), do: []

  defp download_release_asset!(asset, config, token) do
    name = asset["name"] || Mix.raise("release asset is missing a name")
    path = Path.join(config.artifact_dir, name)

    body =
      cond do
        is_binary(token) and token != "" and is_binary(asset["url"]) ->
          config.http_get.(asset["url"], github_binary_headers(token))

        is_binary(asset["browser_download_url"]) ->
          config.http_get.(asset["browser_download_url"], default_headers())

        true ->
          Mix.raise("release asset #{name} is missing a downloadable URL")
      end

    File.write!(path, body)
  end

  defp clean_versioned_artifacts(config) do
    config.artifact_dir
    |> Path.join("#{Precompiled.artifact_prefix(config.version)}*")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp artifact_triple(path, prefix) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.replace_prefix(prefix, "")
  end

  defp artifact_sha(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp render_checksums([]), do: "[]\n"

  defp render_checksums(entries) do
    body =
      Enum.map_join(entries, ",\n", fn {triple, sha} ->
        ~s(  {:"#{triple}", "#{sha}"})
      end)

    "# Generated by `mix precompile.checksum`.\n[\n#{body}\n]\n"
  end

  defp format_invalid_options(invalid) do
    invalid
    |> Enum.map(fn {option, _value} -> "--#{option}" end)
    |> Enum.join(", ")
  end

  defp github_token do
    System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
  end

  defp release_metadata_url(repo, tag),
    do: "https://api.github.com/repos/#{repo}/releases/tags/#{tag}"

  defp github_json_headers(token),
    do:
      [{"accept", "application/vnd.github+json"} | maybe_auth_header(token)] ++ default_headers()

  defp github_binary_headers(token),
    do: [{"accept", "application/octet-stream"} | maybe_auth_header(token)] ++ default_headers()

  defp maybe_auth_header(token) when is_binary(token) and token != "",
    do: [{"authorization", "Bearer #{token}"}]

  defp maybe_auth_header(_token), do: []

  defp default_headers, do: [{"user-agent", "pg_inspect-precompile-checksum"}]

  defp http_get!(url, headers) do
    Req.get!(url, headers: headers, raw: true).body
  end
end
