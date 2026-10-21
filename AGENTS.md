# Agent Instructions

## Code Guidelines

- After changing any `.nix` file, verify that the package still builds. Fix any
  errors or warnings. Iterate until the build is clean, then run `nixfmt` to
  ensure formatting is consistent.
- Do not deeply nest code. Keep it flat and easy to read where possible.
- Do not add superfluous comments. Basic doc comments are fine. Explanatory
  comments should be reserved for complex or non-intuitive logic. In those cases,
  keep comments short.
- Keep implementation as simple as possible.
- After making changes, review your code and look for opportunities to simplify
  or otherwise improve your changes.

Nix-specific:

- If `nixfmt` is not installed on the host, run it through nixpkgs:
  `nix shell nixpkgs#nixfmt --command nixfmt <file>`. The tree is not currently
  nixfmt-clean, so formatting a file you did not otherwise change produces
  unrelated churn — format the files you touched, or do formatting in its own
  commit.
- Every source is a hash-pinned `fetchurl`/`fetchFromGitHub`. Any change to a
  pin (version, tag, HF revision, llama.cpp commit) means re-pinning the hash:
  the first build reports the mismatch, or use
  `nix-prefetch-url --unpack <archive url>`.
- Keep the build network-free. Nothing may fetch at configure or build time; if
  a dependency is needed, pin it as a store path and pass the path in.

## Repository Structure

```text
flake.nix                          # thin wrapper: callPackage the package, expose packages.* and nixosModules.strata
pkgs/by-name/st/strata/            # the package, in nixpkgs' by-name layout (this directory is what would move to nixpkgs)
  package.nix                      # the source pin, the build, and the config the server reads; hipArchs, model and prefillMmq are its parameters
  llama.cpp.nix                    # pinned llama.cpp, source-only store path, used as -DSTRATA_GGML_DIR
modules/services/strata.nix        # the services.strata NixOS module (the service as a systemd unit)
README.md                          # build/run/service usage, and the layout table
```

The package is one output whose closure is the whole package — engine, Python server, model,
tokenizer, MTP draft layer, image encoders, ROCm runtime. It is the assembly: real content for the
Python tree the server runs from, symlinks into the store paths the stage derivations produce. With
this output layout:

```text
bin/strata            the engine (HIP)
bin/strata-device     the device probe (--list-devices)
bin/strata-server     the Python server wrapper
bin/strata-vision     the image encoder (llama.cpp's mtmd), on the CPU: the fallback reader
bin/strata-vision-hip the same encoder on the AMD GPU (ggml-hip), the reader the config names
bin/BUILD.json        the engine version, backend, arch list, model size, picture readers and hipBLASLt
                      version actually compiled
bin/tuning/           the hipBLASLt prompt tables matching that version, for the archs that have one
etc/strata/strata.json  the config the server reads
pack/<size>           the packed model and the tokenizer derived from its GGUF metadata (symlink)
models/<size>         the pinned GGUF file(s) (symlink): two shards, or one Gyro file
vision/               the pinned mmproj the image encoder reads (symlink)
mtp/rt                the packed MTP draft layer (symlink)
data/expert-profile.bin
serve/ tools/ strata_control/ strata_cli/ chat.py requirements.txt
                      the upstream Python tree, run from the store (real copies)
```

## Key Invariants

- The Strata source is **not** a flake input: the package fetches it itself with
  `fetchFromGitHub`, pinned to the tag matching `version`. A flake input named
  `strata` once shadowed the derivation built from it inside its own definition
  and recursed; do not reintroduce one.
- The tag and the engine's version are different numbers: v0.2.1 builds engine 0.1.46, and
  `bin/BUILD.json` carries the engine's, which the assembly reads out of `CMakeLists.txt`'s
  `project(strata VERSION ...)` rather than hardcoding it. The server reads that file as the engine's
  version, and `setup.py` compares it against per-model minimums (`GYRO_ENGINE` and friends), so a
  hardcoded package version there would be wrong.
- Payloads enter the build as `linkFarm` directories, never as bare files in
  `buildInputs`: stdenv `source`s every bare file there as a setup hook.
- `configurePhase = "true"` is deliberate. stdenv's default configure would run
  cmake with no flags and hit the network `FetchContent` for llama.cpp.
- The build is one derivation per stage so the expensive stages cache on their own. The pack and the
  MTP stage read only the pins, the tools scripts and `toolsPython` — never `hipArchs`, ROCm or CMake —
  so they stay cached when the target list changes. The engine stage must stay a `stdenv.mkDerivation`
  with `propagatedBuildInputs = rocmLibs`, which is what patches the RPATH; a `runCommand` would not.
- The assembly keeps `serve/` and `tools/` as real copies: `serve/server.py` takes
  `Path(__file__).resolve().parents[1]` as its root, so a symlinked `serve/` would point it at the wrong
  store path. Only the payloads are links, and the closure still contains them. Since 0.2.0 the server
  also imports `strata_control/` (`vision_reader`, `procs`, `engine_component`, `offline`) and, through
  it, `strata_cli/`, so both are copied too; only the terminal's dashboards want `rich`/`textual`, which
  the server never imports, so the Python environment stays the four packages.
- Store paths inside generated files must be real dependencies, not text. The
  package substitutes `@OUT@`/`@PY@` with `sed`; the service module builds its
  config with `runCommand` (a string read from the store at eval time carries no
  context and cannot be written back out).
- `etc/strata/strata.json` is read with plain `json.loads`, so nothing in it may
  be a comment; the explanation of the `vision` section lives in the Nix source.
- Images need both halves of the config, as `setup.py` writes them: the `vision` section makes the server
  spawn the encoder, and `--vision` in `args` is what makes the engine accept the `GENI` requests it sends.
  The server passes the config's `args` unchanged, so the flag belongs in the package's file.
- Since v0.2.0 the AMD backend has two picture readers, and the package ships both: `tools/vision` built
  plain (`bin/strata-vision`, CPU) and built with `-DSTRATA_VISION_HIP=ON
  -DSTRATA_VISION_HIP_ARCHS="<the same target list>"` (`bin/strata-vision-hip`). The config names the GPU
  one as `exe` with the CPU one as `cpu_exe`, which is what `setup.py` writes for a card of 24 GB or more;
  `serve/vision_reader.py` falls back to the CPU reader when the GPU one cannot start, and `BUILD.json`'s
  `vision_archs` is how it knows the card is not covered. Both are the second CMake project, built against
  the llama.cpp store path with `-DLLAMA_DIR=` and `MTMD_VIDEO=OFF` (the server sends still images only,
  so it needs no ffmpeg). Its `model` is shard 1 with shard 2 beside it under the original names, which is
  how llama.cpp resolves a split GGUF.
- The GPU reader's stage is the one stage that needs `rocm.rocblas`: llama.cpp's `ggml-hip` does
  `find_package(rocblas REQUIRED)` and links it (791 MB in the closure). The engine stage still omits it —
  its CMakeLists finds it only for the gfx103x solution table and treats "not found" as a status.
- nixpkgs has no single `/opt/rocm` prefix: each ROCm package is its own store
  path, found through `CMAKE_PREFIX_PATH`, and the HIP compiler is
  `rocm.clr/bin/amdclang++`.
- Since v0.2.1 an AMD engine package carries hipBLASLt prompt tables, and the assembly stages them with the
  source's own `packaging/stage_tuning.py`: it reads the hipBLASLt version out of the headers it builds
  against (`${rocm.hipblaslt}`), copies `tools/hip/<arch>-hipblaslt-<version>.txt` for the target archs into
  `bin/tuning/`, and writes that version to `BUILD.json` as `hipblaslt_version`. Do not hand-copy the
  tables: a table's solution ids are valid for one architecture family and one hipBLASLt version, and the
  engine refuses a mismatch. nixpkgs' hipBLASLt is 1.2.2 (100202), which has tables for gfx1100 and gfx1201
  and none for gfx1151 (those need 1.4 or 1.5), so the default target keeps plain hipBLAS. The server looks
  for `tuning/` only for a config whose `exe` is `component:strata-engine`, which this package does not use,
  so `bin/strata-server` asks `strata_control/hipblaslt_tuning.py` which table fits the card it finds and
  exports `STRATA_HIPBLASLT_TUNING`. It stays off unless the run config says `"hipblaslt_table": true`
  (`services.strata.hipblasltTable` writes it; a `STRATA_HIPBLASLT_TABLE` environment switch overrides the
  config), because a table changes the prompt's floating-point sums.
- `hipArchs`, `model` and `prefillMmq` are the caller-visible knobs. `hipArchs` is a list (or a `;`-joined string). It
  is validated by the source's own `cmake/hip_backend.cmake` — gfx1100/gfx1201 by the maintainers,
  gfx1101/gfx1200 by their owners, the rest (the default `gfx1151` included) build with a warning —
  and is recorded in `bin/BUILD.json`. Nothing patches that file: the arch list this repository used to
  carry in `hip_backend.patch` landed upstream in `v0.1.40`.
- `prefillMmq` is the GGML MMQ prompt path (`-DSTRATA_PREFILL_MMQ`, ON here against upstream's OFF default;
  it requires HIP, which this package always enables). It reaches the engine stage alone, so flipping it
  rebuilds the engine and the assembly, not the pack, the encoder or the draft layer, and it is recorded in
  `bin/BUILD.json` as `prefill_mmq`.
- `model` selects the size: the model pin and the pack, so each size has its own pack derivation
  (`strata-pack-<size>`) and its own `pack/<size>` output — one name for all sizes would let the caches
  collide. Shard 2 is byte-identical in every GSQ-RCO size (the PLE table alone), so it is pinned once.
  The size reaches the pins and the pack only, so switching sizes keeps the engine, both encoders and the
  draft layer cached. `IQ2_XS` is the default; the IQ3 sizes want more RAM for their experts (60 and 62 GB
  in `setup.py`'s `MODELS`, against IQ2_XS's 48), which is what the generated config's comment states.
- The `families` table carries what differs between the two model lines, mirroring `setup.py`'s
  `FAMILIES`/`MODELS`: the repository and its pinned revision, the published file names, the shard count,
  the `model_name` prefix, and any extra `iq_pack.py` flag. Gyro (agentionai's trellis TQ quants) is one
  GGUF that holds the n-gram table, so `--ple-gguf` points at the same file as `--native`, its pack needs
  `--compat-bf16`, and its `experts.bin` is marked v5 with a `hadamard.txt` beside it (Hadamard-folded
  experts an older engine would read as noise). Its mmproj is the GSQ-RCO one, pinned once for both
  families. The trellis MMQ prompt kernels come from `cmake/strata_ggml_tq_overlay.cmake`, which writes an
  overlay of the pinned llama.cpp's ggml-cuda headers at configure time; `STRATA_MMQ_TQ_OVERLAY` is ON
  upstream and this package leaves it at its default.
- `llama.cpp.nix` is `import`ed directly. That is fine here, but a nixpkgs
  `by-name` package may only use its function arguments, so it would have to
  become its own `by-name` entry to be upstreamed.
- The output is read-only: the service can write only to `services.strata.stateDir`
  (`/var/lib/strata`). The GPU is reached through the kernel driver, so the unit
  keeps `/dev/kfd` and `/dev/dri` visible (no `PrivateDevices`), needs the
  `render`/`video` groups and unlimited memlock, and has no start timeout.
- `x86_64-linux` only: the flake defines no other system and the package's
  `platforms` say so.

## Commands

```sh
nix build .#strata                 # ~2 min compile; ~120 GB of pinned downloads on a cold cache
nix build .#strata.passthru.engine # the compile stages alone (also .vision, .visionHip): no model downloads
nix build .#strata --dry-run       # does this change invalidate the derivation? (nothing printed = cached)
nix run .#strata -- --help         # the engine's usage, from the store (no GPU needed)
nix flake check --no-build         # eval only: checks the derivation and the NixOS module
```

Plain `nix flake check` builds the package, so use `--no-build` for the quick
check.

A change to the build recipe re-runs the pack/extract steps over ~67 GB of model
data; a change to a pin re-downloads. Check with `--dry-run` before starting a
rebuild.

```sh
# another card: hipArchs is a callPackage parameter of the package
nix build --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; }'

# another model size: model is the other callPackage parameter (Q2_0, IQ2_XS, IQ3_XXS, IQ3_S,
# Gyro-S, Gyro-M)
nix build .#strata-iq3-s

# re-pin a hash after changing a pin
nix-prefetch-url --unpack https://github.com/Niko1221/Strata/archive/v<version>.tar.gz

# formatting
nix shell nixpkgs#nixfmt --command nixfmt flake.nix pkgs/by-name/st/strata/package.nix
```

There are no tests or CI in this repository. The NixOS module is exercised by
evaluating it in a consumer flake (`nixosModules.strata` +
`services.strata.enable = true`); runtime behaviour needs a real AMD card.
