defmodule Expkg.Steps.Build.CopyRelease do
  alias Burrito.Builder.Context
  alias Burrito.Builder.Step

  @behaviour Step

  @success_banner """
  \n\n
  📦 expkg delivered!
  """

  @impl Step
  def execute(%Context{} = context) do
    app_path = File.cwd!()
    release_name = Atom.to_string(context.mix_release.name)
    target_name = Atom.to_string(context.target.alias)

    orig_bin_name =
      if context.target.os == :windows do
        "#{release_name}.exe"
      else
        release_name
      end

    bin_name =
      if context.target.os == :windows do
        "#{release_name}_#{target_name}.exe"
      else
        "#{release_name}_#{target_name}"
      end

    bin_path = Path.join(context.self_dir, ["zig-out", "/bin", "/#{orig_bin_name}"])
    bin_out_path = Path.join(app_path, ["expkg_out"])
    File.mkdir_p!(bin_out_path)

    output_bin_path = Path.join(bin_out_path, [bin_name])

    File.copy!(bin_path, output_bin_path)
    File.rm!(bin_path)

    # Mark resulting bin as executable
    File.chmod!(output_bin_path, 0o744)

    IO.puts(@success_banner <> "\tOutput Path: #{output_bin_path}\n\n")

    context
  end
end
