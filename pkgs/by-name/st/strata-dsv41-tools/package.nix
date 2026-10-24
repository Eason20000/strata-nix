# The DeepSeek-V4.1 packing tool, pinned to its own revision, apart from the Flash-Next tools tree.
#
# Same reason as strata-tools, different files: Nix is input-addressed, so a pack derivation that read the
# engine's source tree would re-run over ~138 GB of GGUF on every engine release even when the script is
# byte-identical. This pin holds only what the DeepSeek packs need, so it moves when `pack_gguf.py` or a
# hot-expert profile changes and leaves the six Flash-Next packs alone - and the reverse, since
# `tools/dsv41/` never appears in strata-tools.
#
# The tree keeps the source's layout: `tools/dsv41/pack_gguf.py` beside the profiles it and setup.py copy
# out of `data/dsv41/`. The tool is stdlib-only (it reads GGUF metadata itself), so nothing here needs
# llama.cpp's gguf-py or numpy.

{
  lib,
  runCommand,
  fetchFromGitHub,
}:
let
  # The tag these files are taken from: dsv41/ arrived with v0.2.4, so the pin is at that release. The
  # engine tag moving does not move this - setup.py's dsv41_pack_cmd has not changed since.
  version = "0.2.4";
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-lfFu7nDXolARbJVhEnOfJGmlRgIdNLHDIpXdL4jDOyI=";
  };

  # The profiles setup.py copies into the pack folder: which experts are used most, so the engine's RAM
  # store starts with them. 1.75 and 2.00 bpw share profile-2.00.bin; 2.25 bpw has its own.
  profiles = [
    "profile-2.00.bin"
    "profile-2.25.bin"
  ];
in
runCommand "strata-dsv41-tools-${version}"
  {
    meta = {
      description = "Strata's DeepSeek-V4.1 pack tool and hot-expert profiles at ${version}";
      homepage = "https://github.com/Niko1221/Strata";
      license = lib.licenses.mit;
      platforms = [ "x86_64-linux" ];
    };
    # the tag these files came from, for a consumer that wants to say which release made a pack
    passthru.toolsVersion = version;
  }
  ''
    mkdir -p $out/tools/dsv41 $out/data/dsv41
    cp ${src}/tools/dsv41/pack_gguf.py $out/tools/dsv41/pack_gguf.py
    ${lib.concatMapStringsSep "\n" (f: "cp ${src}/data/dsv41/${f} $out/data/dsv41/${f}") profiles}
  ''
