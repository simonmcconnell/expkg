defmodule Expkg do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias Expkg.Commands
  alias Expkg.Help
  alias Expkg.Helpers

  require EEx
  require Logger

  defstruct [
    :executable_name,
    :release,
    commands: [],
    no_args_command: :help,
    hide: [],
    help: %{}
  ]

  @type mode :: :permanent | :transient | :temporary | :load | :none
  @type application :: atom()
  @type t :: %__MODULE__{
          commands: [Expkg.Commands.t()],
          executable_name: String.t(),
          hide: [String.t()],
          no_args_command: :help | :start,
          release: Mix.Release.t(),
          help: map()
        }

  # TODO: other targets
  # @supported_targets [:win64, :darwin, :linux, :linux_musl]
  @supported_targets [:win64]
  @supported_target_strings Enum.map(@supported_targets, &Atom.to_string/1)
  @success_banner "\n\n📦 expkg delivered! 📦"

  EEx.function_from_file(:def, :build_zig, "build.zig.eex", [:assigns])
  EEx.function_from_file(:def, :main_zig, "src/main.zig.eex", [:assigns])

  def assemble(%Mix.Release{} = release) do
    options = release.options[:expkg] || []
    # commands = Keyword.get(options, :commands, Commands.defaults())
    targets = Keyword.get(options, :targets, [:native])
    debug? = Keyword.get(options, :debug, false)
    no_clean? = Keyword.get(options, :no_clean, false)

    override_targets = maybe_get_override_targets()

    targets =
      if override_targets != [] do
        Logger.info("Override targets: #{inspect(override_targets)}")
        override_targets
      else
        targets
      end

    plugin = Keyword.get(options, :plugin, nil)

    current_system = get_current_os()

    {:ok, _} = Application.ensure_all_started(:req)

    Enum.each(targets, fn target ->
      if target in @supported_targets do
        # if we're building for the current host system, use a :native target
        if current_system == target do
          do_assemble(release, :native, plugin, no_clean?, debug?)
        else
          do_assemble(release, target, plugin, no_clean?, debug?)
        end
      else
        raise_unsupported_target(target)
      end
    end)

    release
  end

  defp maybe_get_override_targets do
    System.get_env("EXPKG_TARGET", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn target ->
      if target in @supported_target_strings do
        String.to_existing_atom(target)
      else
        raise_unsupported_target(target)
      end
    end)
  end

  defp raise_unsupported_target(target) do
    Logger.error(
      "The target #{target} is not supported. Supported targets are: " <>
        Enum.join(@supported_target_strings, ", ")
    )

    exit(1)
  end

  defp do_assemble(%Mix.Release{} = release, build_target, _plugin, no_clean?, debug_build?) do
    # Pre-flight checks
    Helpers.Precheck.run()

    Logger.info("expkg build target is: #{inspect(build_target)}")

    # TODO: plugin(s)
    # Build potential plugin
    # plugin_result = Burrito.Helpers.ZigPlugins.run(plugin)

    random_build_dir_id = :crypto.strong_rand_bytes(8) |> Base.encode16()

    release_working_path = System.tmp_dir!() |> Path.join(["expkg_build_#{random_build_dir_id}"])

    # always overwrite files
    File.cp_r(release.path, release_working_path, fn _, _ -> true end)

    Logger.info("Build working dir: #{release_working_path}")

    erts_path =
      if build_target != :native do
        {:ok, opt_verson} =
          :file.read_file(
            :filename.join([
              :code.root_dir(),
              "releases",
              :erlang.system_info(:otp_release),
              "OTP_VERSION"
            ])
          )

        opt_verson = String.trim(opt_verson)

        Burrito.OTPFetcher.download_and_replace_erts_release(
          release.erts_version,
          opt_verson,
          release_working_path,
          build_target
        )
      end

    app_path = File.cwd!()

    # this resolves to the path in where expkg is installed
    self_path =
      __ENV__.file
      |> Path.dirname()
      |> Path.split()
      |> List.delete_at(-1)
      |> Path.join()

    commands =
      (release.options[:expkg] || [])
      |> Keyword.get(:commands, Commands.default_commands())
      |> Commands.parse(release.name, get_current_os())

    expkg =
      %__MODULE__{
        executable_name: Application.get_env(:expkg, :executable_name, release.name),
        no_args_command: :start,
        release: release,
        commands: commands,
        hide: []
      }
      |> Help.generate()

    # build our zig templates
    assigns = expkg |> Map.from_struct()

    Path.join(self_path, "build.zig") |> File.write!(build_zig(assigns))
    Path.join(self_path, ["src", "main.zig"]) |> File.write!(main_zig(assigns))

    zig_build_args = []

    possible_cross_target =
      case build_target do
        :win64 -> "x86_64-windows-gnu"
        :darwin -> "x86_64-macos"
        :linux -> "x86_64-linux-gnu"
        :linux_musl -> "x86_64-linux-musl"
        _ -> ""
      end

    if possible_cross_target != "" do
      # find NIFs we probably need to recompile
      Burrito.Helpers.NIFSniffer.find_nifs()
      |> Enum.each(fn dep ->
        maybe_recompile_nif(dep, release_working_path, erts_path, possible_cross_target)
      end)
    end

    # Compose final zig build args

    zig_build_args =
      if possible_cross_target != "" do
        ["-Dtarget=#{possible_cross_target}" | zig_build_args]
      else
        zig_build_args
      end

    zig_build_args =
      if debug_build? do
        zig_build_args
      else
        ["-Drelease-small=true" | zig_build_args]
      end

    release_name = Atom.to_string(release.name)

    Burrito.Helpers.Metadata.run(self_path, zig_build_args, release)

    # TODO: Why do we need to do this???
    # This is to bypass a VERY strange bug inside Linux containers...
    # If we don't do this, the archiver will fail to see all the files inside the lib directory
    # This is still under investigation, but touching a file inside the directory seems to force the
    # File system to suddenly "wake up" to all the files inside it.
    Path.join(release_working_path, ["/lib", "/.expkg"]) |> File.touch!()

    build_result =
      System.cmd("zig", ["build"] ++ zig_build_args,
        cd: self_path,
        into: IO.stream()
      )

    orig_bin_name =
      if build_target == :win64 do
        "#{release_name}.exe"
      else
        release_name
      end

    bin_name =
      if build_target == :win64 do
        "#{release_name}_#{Atom.to_string(build_target)}.exe"
      else
        "#{release_name}_#{Atom.to_string(build_target)}"
      end

    # copy the resulting bin into the calling project's output directory
    case build_result do
      {_, 0} ->
        bin_path = Path.join(self_path, ["zig-out", "/bin", "/#{orig_bin_name}"])
        bin_out_path = Path.join(app_path, ["expkg_out"])

        File.mkdir_p!(bin_out_path)

        output_bin_path = Path.join(bin_out_path, [bin_name])

        File.copy!(bin_path, output_bin_path)
        File.rm!(bin_path)

        # Mark resulting bin as executable
        File.chmod!(output_bin_path, 0o744)

        IO.puts(@success_banner <> "\tOutput Path: #{output_bin_path}")

      _ ->
        Logger.error("expkg failed to wrap up your app! Check the logs for more information.")
        exit(1)
    end

    # clean up everything unless asked not to
    unless no_clean? do
      Helpers.Clean.run(self_path)
      File.rm_rf!(release_working_path)
    end

    release
  end

  defp maybe_recompile_nif({_, _, false}, _, _, _), do: :no_nif

  defp maybe_recompile_nif({dep, path, true}, release_working_path, erts_path, cross_target) do
    dep = Atom.to_string(dep)

    Logger.info("Going to recompile NIF for cross-build: #{dep} -> #{cross_target}")

    _ = System.cmd("make", ["clean"], cd: path, stderr_to_stdout: true, into: IO.stream())

    erts_include = Path.join(erts_path, ["erts*", "/include"]) |> Path.wildcard() |> List.first()

    build_result =
      System.cmd("make", ["--always-make"],
        cd: path,
        stderr_to_stdout: true,
        env: [
          {"RANLIB", "zig ranlib"},
          {"AR", "zig ar"},
          {"CC", "zig cc -target #{cross_target} -v -shared"},
          {"CXX", "zig c++ -target #{cross_target} -v -shared"},
          {"CXXFLAGS", "-I#{erts_include}"},
          {"CFLAGS", "-I#{erts_include}"}
        ],
        into: IO.stream()
      )

    case build_result do
      {_, 0} ->
        Logger.info("Successfully re-built #{dep} for #{cross_target}!")

        src_priv_files = Path.join(path, ["priv/*"]) |> Path.wildcard()

        output_priv_dir =
          Path.join(release_working_path, ["lib/#{dep}*/priv"]) |> Path.wildcard() |> List.first()

        Enum.each(src_priv_files, fn file ->
          file_name = Path.basename(file)
          dst_fullpath = Path.join(output_priv_dir, file_name)

          Logger.info("#{file} -> #{output_priv_dir}")

          File.copy!(file, dst_fullpath)
        end)

      {output, _} ->
        Logger.error("Failed to rebuild #{dep} for #{cross_target}!")
        Logger.error(output)
        exit(1)
    end
  end

  defp get_current_os do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> get_libc_type()
    end
  end

  defp get_libc_type do
    {result, _} = System.cmd("ldd", ["--version"])

    cond do
      String.contains?(result, "musl") -> :linux_musl
      true -> :linux
    end
  end
end
