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
flake.nix                          # wires the pins together and exposes packages.* (strata, strata-tools, strata-mtp and one strata-model-<size> per size) and nixosModules.strata
pkgs/by-name/st/strata/            # the engine and its assembly, in nixpkgs' by-name layout (this directory is what would move to nixpkgs)
  package.nix                      # the source pin, the build, and the config the server reads; hipArchs, model, mtp and prefillMmq are its parameters
  llama.cpp.nix                    # pinned llama.cpp, source-only store path, used as -DSTRATA_GGML_DIR and for gguf-py
pkgs/by-name/st/strata-tools/      # the pinned Strata tools tree the pack and the draft-layer extract run, at its own rev
pkgs/by-name/st/strata-mtp/        # the MTP draft layer: the pinned checkpoint shards plus the extract
pkgs/by-name/st/strata-model-<size>/  # one per size (iq2-xs, q2-0, iq3-xxs, iq3-s, gyro-s, gyro-m): its GGUF shards, its pack/tokenizer, its family mmproj
modules/services/strata.nix        # the services.strata NixOS module (the service as a systemd unit)
README.md                          # build/run/service usage, and the layout table
```

The engine package is one output whose closure is the whole package — engine, Python server, model,
tokenizer, MTP draft layer, image encoders, ROCm runtime. It is the assembly: real content for the
Python tree the server runs from, symlinks into the store paths the stage derivations and the model and
draft-layer packages produce. With
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
- The tag and the engine's version are different numbers: v0.2.2 builds engine 0.1.47, and
  `bin/BUILD.json` carries the engine's, which the assembly reads out of `CMakeLists.txt`'s
  `project(strata VERSION ...)` rather than hardcoding it. The server reads that file as the engine's
  version, and `setup.py` compares it against per-model minimums (`GYRO_ENGINE` and friends), so a
  hardcoded package version there would be wrong.
- Payloads enter the build as `linkFarm` directories, never as bare files in
  `buildInputs`: stdenv `source`s every bare file there as a setup hook.
- `configurePhase = "true"` is deliberate. stdenv's default configure would run
  cmake with no flags and hit the network `FetchContent` for llama.cpp.
- The build is one derivation per stage so the expensive stages cache on their own. The engine stage must
  stay a `stdenv.mkDerivation` with `propagatedBuildInputs = rocmLibs`, which is what patches the RPATH; a
  `runCommand` would not.
- The pack and the draft-layer extract are not stages of the engine package at all: they live in the model
  packages and `strata-mtp`, which take the pinned `strata-tools` store path as an argument and never see the
  engine's source. Nix is input-addressed, so a stage reading `${src}/tools/iq_pack.py` re-runs over ~67 GB on
  every engine release even when the script is byte-identical. Bumping `version` in the engine package leaves
  the six model drvPaths, the pack drvPath and the mtp drvPath byte-identical; only the engine, both readers
  and the assembly change.
- The assembly keeps `serve/` and `tools/` as real copies: `serve/server.py` takes
  `Path(__file__).resolve().parents[1]` as its root, so a symlinked `serve/` would point it at the wrong
  store path. Only the payloads are links, and the closure still contains them. Since 0.2.0 the server
  also imports `strata_control/` (`vision_reader`, `procs`, `engine_component`, `offline`) and, through
  it, `strata_cli/`, so both are copied too; only the terminal's dashboards want `rich`/`textual`, which
  the server never imports, so the Python environment stays five packages (jinja2, regex, psutil, pillow,
  and jsonschema, which `serve/structured.py` needs to actually validate a request's `response_format`).
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
- `hipArchs`, `model`, `mtp` and `prefillMmq` are the caller-visible knobs. `hipArchs` is a list (or a `;`-joined string). It
  is validated by the source's own `cmake/hip_backend.cmake` — gfx1100/gfx1201 by the maintainers,
  gfx1101/gfx1200 by their owners, the rest (the default `gfx1151` included) build with a warning —
  and is recorded in `bin/BUILD.json`. Nothing patches that file: the arch list this repository used to
  carry in `hip_backend.patch` landed upstream in `v0.1.40`.
- `prefillMmq` is the GGML MMQ prompt path (`-DSTRATA_PREFILL_MMQ`, ON here against upstream's OFF default;
  it requires HIP, which this package always enables). It reaches the engine stage alone, so flipping it
  rebuilds the engine and the assembly, not the pack, the encoder or the draft layer, and it is recorded in
  `bin/BUILD.json` as `prefill_mmq`.
- Each size is its own by-name package. `services.strata.model` is a size string (`"IQ3_S"`) and the module
  maps it to `pkgs/by-name/st/strata-model-iq3-s/` — the engine package takes a model *package*, never a
  string, because a by-name package may only use its function arguments and cannot go looking for its siblings.
  Each model package carries its own pins and its own
  pack derivation (`strata-pack-<pack>`, the size lowercased without underscores — one name for all sizes
  would let the caches collide) and exposes `passthru.strata` as the contract the assembly reads: `size`,
  `packName`, `modelName`, `minEngine`, `ram`, `download`, `memoryNote`, `shard1`, `ple`, `mmprojName`, and the
  `shards`/`pack`/`mmprojDir` store paths. The assembly links `${model}/shards`, `${model}/pack`,
  `${model}/mmproj` and `${mtp}`, and fails the build when the engine is older than `minEngine` (setup.py's
  `MIN_ENGINE` and `GYRO_ENGINE`). Switching size rebuilds the assembly alone: the engine, both encoders and
  the draft layer stay cached.
- What differs between the two model lines is written in each model package, mirroring `setup.py`'s
  `FAMILIES`/`MODELS`: the repository and its pinned revision, the published file names, the shard count,
  the `model_name` prefix, and any extra `iq_pack.py` flag. It repeats per file rather than living in one
  shared table because a `by-name` package may only use its function arguments; the mmproj pin repeats the
  same way and collapses to one store path. Shard 2 is byte-identical in every GSQ-RCO size (the PLE table
  alone), so every size pins the same file. Gyro (agentionai's trellis TQ quants) is one
  GGUF that holds the n-gram table, so `--ple-gguf` points at the same file as `--native`, its pack needs
  `--compat-bf16`, and its `experts.bin` is marked v5 with a `hadamard.txt` beside it (Hadamard-folded
  experts an older engine would read as noise). Its mmproj is the GSQ-RCO one, pinned once for both
  families. The trellis MMQ prompt kernels come from `cmake/strata_ggml_tq_overlay.cmake`, which writes an
  overlay of the pinned llama.cpp's ggml-cuda headers at configure time; `STRATA_MMQ_TQ_OVERLAY` is ON
  upstream and this package leaves it at its default.
- `llama.cpp.nix` is `import`ed directly by the engine package, the flake and the service module. That is
  fine here, but a nixpkgs `by-name` package may only use its function arguments, so it would have to
  become its own `by-name` entry to be upstreamed. `strata-tools`, `strata-mtp` and the model packages
  already follow that rule: they take `strataTools` and `strataLlamaCpp` as arguments, which the flake and
  the module pass in.
- The model and draft-layer packages carry `unfreeRedistributable` meta (the Qwen Community License), so
  anything building them needs unfree allowed; this flake imports nixpkgs with `config.allowUnfree = true`
  and a consumer's configuration needs the same. The engine, the readers and the tools pin stay MIT.
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

A change to a model package's recipe re-runs its pack over ~67 GB of model data; a
change to a pin re-downloads. An engine release touches neither: the pack and the
extract run the `strata-tools` pin, and you move that pin only when `tools/iq_pack.py`
or `tools/mtp_*` change, which re-runs the pack for every size and the checkpoint
extract once. Check with `--dry-run` before starting a rebuild.

```sh
# another card: hipArchs is a callPackage parameter of the engine package. Use the flake's locked nixpkgs, not
# <nixpkgs>: another nixpkgs means another ROCm and hipBLASLt, and a table is valid for one version only.
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = p.strata-model-iq2-xs; mtp = p.strata-mtp; }'

# another model size: the payload alone (its downloads and its pack, no engine), then assemble over it
nix build .#strata-model-iq3-s
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { model = p.strata-model-iq3-s; mtp = p.strata-mtp; }'

# re-pin a hash after changing a pin
nix-prefetch-url --unpack https://github.com/Niko1221/Strata/archive/v<version>.tar.gz

# formatting
nix shell nixpkgs#nixfmt --command nixfmt flake.nix pkgs/by-name/st/strata/package.nix
```

There are no tests or CI in this repository. The NixOS module is exercised by
evaluating it in a consumer flake (`nixosModules.strata` +
`services.strata.enable = true`); runtime behaviour needs a real AMD card.
