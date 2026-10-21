# The Strata tools the model layer runs at build time, pinned to their own revision.
#
# This pin is why the model packages survive a Strata release. Nix is input-addressed: a derivation that
# reads the engine's own source tree re-runs whenever the engine tag moves, even when the file it runs is
# byte-identical. So the pack and the MTP extract run this store path instead, and it moves only when one of
# the files listed below changes - which is the expensive thing to disturb (the pack reads ~68 GB of GGUF).
#
# The tree keeps the source's tools/ and data/ layout: tools/_paths.py finds llama.cpp's gguf-py through
# $STRATA_GGUF_PY, iq_pack.py runs strata_tokenizer.py as a subprocess from beside itself, and the MTP
# output carries data/draft_vocab.bin, which the engine reads with the draft layer.

{
  lib,
  runCommand,
  fetchFromGitHub,
}:
let
  # The tag these tools are taken from: the last release that changed the packing tools. It is not the
  # engine's version and does not move with it - v0.2.2 left every file below byte-identical, so this pin
  # stays where v0.2.1.4 put it and the two fetches are two store paths.
  version = "0.2.1.4";
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-lLfTVwKrgJ+2/tH29G6XwR2MwMbOxS7UBgOIthZI7PU=";
  };

  # The transitive closure of what the build runs: iq_pack.py (which runs strata_tokenizer.py as a
  # subprocess), the GGUF reader they both import, the gguf-py path helper, and the three MTP scripts -
  # mtp_fetch.py for the SHA256 table its extractor checks against (#327). Add a file here when a tool
  # starts importing another one; the build fails with an ImportError until it is listed.
  toolsFiles = [
    "_paths.py"
    "gguf_reader.py"
    "iq_pack.py"
    "mtp_fetch.py"
    "mtp_pack.py"
    "mtp_rt.py"
    "strata_tokenizer.py"
  ];
in
runCommand "strata-tools-${version}"
  {
    meta = {
      description = "The Strata packing tools at ${version}, pruned to the files the model layer runs";
      homepage = "https://github.com/Niko1221/Strata";
      license = lib.licenses.mit;
      platforms = [ "x86_64-linux" ];
    };
    # the tag these tools came from, for a consumer that wants to say which release made a pack
    passthru.toolsVersion = version;
  }
  ''
    mkdir -p $out/tools $out/data
    ${lib.concatMapStringsSep "\n" (f: "cp ${src}/tools/${f} $out/tools/${f}") toolsFiles}
    cp ${src}/data/draft_vocab.bin $out/data/draft_vocab.bin
  ''
