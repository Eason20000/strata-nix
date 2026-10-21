# Strata: the inference engine (HIP), its Python server and its image encoders (CPU and GPU), assembled
# over a model package and an MTP draft-layer package, every download a pinned fetchurl.
#
# One derivation per stage, so the expensive stages are cached on their own. This package holds the
# compiled stages only - the engine, the two picture readers, the Python tree, the tuning tables and the
# config the server reads. The model (its shards, its pack and its tokenizer, its image encoder) and the
# draft layer are separate packages passed in, so a Strata release rebuilds the compiled stages alone and
# never the ~67 GB of pack work, and a model size change rebuilds nothing here.
#
# This is the package definition; the flake callPackages it (flake.nix). Everything - the source pin, the
# build, the config the server reads - lives here, and it reads nothing outside this directory: the four
# things the caller chooses are all parameters below.
#   pkgs.callPackage path/to/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = strataPkgs.models.iq3_s; mtp = strataPkgs.mtp; prefillMmq = false; }
# hipArchs and prefillMmq reach the compiled stages; model and mtp reach the config and the closure.

{
  lib,
  stdenv,
  stdenvNoCC,
  runCommand,
  cmake,
  ninja,
  fetchurl,
  fetchFromGitHub,
  rocmPackages,
  python3,
  hipArchs ? [
    "gfx1100"
    "gfx1151"
    "gfx1201"
  ],
  model,
  mtp,
  prefillMmq ? true,
}:
let
  rocm = rocmPackages;

  # The repository tag. The engine's own version is a separate number (CMakeLists.txt's project
  # version, 0.1.46.3 for this tag), and BUILD.json carries that one, because that is what the server
  # reads as the engine's version.
  version = "0.2.1.4";
  # The target list as a list. A semicolon-separated string is accepted too, which is the form CMake
  # and the source's own scripts take; services.strata.hipArchs passes a list.
  archList = if builtins.typeOf hipArchs == "string" then lib.splitString ";" hipArchs else hipArchs;
  # CMake takes the list as one argument with the ";" separator
  archString = lib.concatStringsSep ";" archList;

  # The source, fetched from GitHub at the tag matching this package's version. The hash is the
  # unpacked archive's, so a version bump (or a change to the tag) means re-pinning it - the first
  # build reports the mismatch, or: nix-prefetch-url --unpack <archive url>.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-lLfTVwKrgJ+2/tH29G6XwR2MwMbOxS7UBgOIthZI7PU=";
  };

  # The HIP target list is validated by the source's own cmake/hip_backend.cmake: gfx1100 and gfx1201 by the
  # maintainers, gfx1101 and gfx1200 by their owners, and the rest - gfx1151 (Radeon 8060S), which this
  # package's default hipArchs targets, is among them - builds with a warning. Nothing patches it any more:
  # the arch list this package used to carry as a patch landed upstream in v0.1.40.

  # llama.cpp pinned at the commit CMakeLists.txt's FetchContent default uses (setup.py's
  # LLAMA_CPP_COMMIT and third_party/ggml/VERSION.txt record the same id). -DSTRATA_GGML_DIR points
  # CMake at the unpacked store path, so the sandbox needs no network at configure time. Its
  # gguf-py/ (the Python GGUF reader) is what the build-time tools below import through STRATA_GGUF_PY.
  # The repo's own module, now beside this package (llama.cpp.nix); this whole directory is what would
  # have to move if this package were upstreamed to nixpkgs.
  llamaCpp = import ./llama.cpp.nix {
    inherit fetchurl stdenvNoCC;
  };

  # The server's non-stdlib imports (serve/, strata_control/ and strata_cli/, which the server imports
  # since 0.2.0, and tools/strata_tokenizer.py): jinja2 (chat templates), regex (the tokenizer), psutil
  # (RAM telemetry), pillow (the image formats the image encoder's decoder cannot read, which the server
  # converts to PNG before handing them over), jsonschema (serve/structured.py validates a request's
  # response_format json_schema against it, and without it the server says so and only checks that the
  # answer is one JSON object). No web framework - serve/server.py is the stdlib http.server. rich and
  # textual are not here: only the terminal's dashboards import them, and the server never touches those.
  python = python3.withPackages (p: [
    p.jinja2
    p.regex
    p.psutil
    p.pillow
    p.jsonschema
  ]);

  # ---- the payload: the model package and the MTP draft layer --------------------------------
  # Both are packages of their own, passed in as arguments: strata-model-<size> carries the GGUF shards, the
  # pack cut from them with the tokenizer derived from their metadata, and the family's image encoder;
  # strata-mtp carries the draft layer. Neither reads this package's source, so a Strata release rebuilds the
  # engine and the two picture readers alone - the ~67 GB of pack work and the ~55 GB of checkpoint extract
  # stay cached, and so does everything when only the model size changes.
  #
  # What the assembly needs is the model package's passthru.strata: the size, the pack name, the published
  # file names, the model_name the API reports, the memory the size wants, and the first engine version that
  # can read its pack.
  m =
    model.passthru.strata
    or (throw "the model passed to the Strata package must be one of the strata-model-* packages: it carries no passthru.strata, so the assembly cannot name its shards, its pack or its image encoder");

  # nixpkgs has no single /opt/rocm prefix: each package is its own store path, and CMake's
  # find_package(... CONFIG) finds the configs against them through CMAKE_PREFIX_PATH. What each is for:
  #   clr         the hipcc driver + hip-lang/hip CMake configs (enable_language(HIP), hip::host, libamdhip64)
  #   hipblas     roc::hipblas (the dense matrix path)
  #   hipblaslt   roc::hipblaslt (the optional fast prefill GEMMs; its GPU kernels cover nixpkgs' full
  #               target list, which includes every supported gfx* above)
  #   rocm-core   hsa-runtime64 / hsakmt, the HSA runtime the engine loads at start
  #   rocm-comgr  libamdcomgr (LLVM bitcode compilation at load time)
  #   rocm-runtime the remaining runtime libraries
  #   hip-common  the HIP headers hipcc includes
  # rocBLAS is deliberately absent from the engine: CMakeLists.txt finds it only for the gfx103x solution
  # table (STRATA_ROCBLAS_TUNING), and configure reports "not found" as a status, not an error.
  rocmLibs = [
    rocm.clr
    rocm.hipblas
    rocm.hipblaslt
    rocm.rocm-core
    rocm.rocm-comgr
    rocm.rocm-runtime
    rocm.hip-common
  ];
  # The GPU picture reader is the one stage that cannot do without rocBLAS: it links llama.cpp's ggml-hip,
  # which does find_package(rocblas REQUIRED). That is 791 MB the engine itself does not need.
  visionHipLibs = rocmLibs ++ [ rocm.rocblas ];

  # the engine loads libamdhip64 / hsa-runtime64 / the hipBLAS libraries at run time; stdenv patches
  # their store paths into the binaries' RPATH, so nothing ROCm lives outside this package's closure
  cmakeFlags = builtins.concatStringsSep " " [
    "-DSTRATA_ENABLE_HIP=ON"
    "-DSTRATA_ENABLE_CUDA=OFF"
    "-DSTRATA_BUILD_TESTS=OFF"
    "-DSTRATA_NATIVE_EXPERTS=ON"
    # the GGML MMQ prompt path (the prefillMmq parameter), off in CMakeLists.txt by default: this is what
    # compiles the gfx11 WMMA fused prompt-expert kernels, and it is on in upstream's own Strix Halo build
    # line (docs/STRIX_HALO.md). It requires HIP, which this package always enables.
    "-DSTRATA_PREFILL_MMQ=${if prefillMmq then "ON" else "OFF"}"
    # this machine is not the target PC: ggml-cpu at the AVX2 baseline instead of host-native
    # (CMakeLists.txt's STRATA_PORTABLE); the AVX-512 expert kernels keep their runtime CPU dispatch
    "-DSTRATA_PORTABLE=ON"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_PREFIX_PATH=${lib.makeSearchPath ":" rocmLibs}"
    # the HIP driver (ROCm clang with the ROCm environment wired up) for the .cu sources
    # the package's hip_backend.cmake relabels to the HIP language
    "-DCMAKE_HIP_COMPILER=${rocm.clr}/bin/amdclang++"
    # the target list (the hipArchs parameter); shell-quoted because the ";" list separator is a bash
    # command separator in buildPhase
    "-DCMAKE_HIP_ARCHITECTURES='${archString}'"
    # llama.cpp from the store instead of a FetchContent network fetch
    "-DSTRATA_GGML_DIR=${llamaCpp}"
    # STRATA_MMQ_TQ_OVERLAY (ON here, as upstream) is what makes the MMQ prompt path cover the Gyro
    # trellis types on an upstream llama.cpp: it writes an overlay of ggml-cuda headers at configure
    # time (cmake/strata_ggml_tq_overlay.cmake). Kept at its default, and it needs nothing of ours.
  ];

  # tools/vision is its own CMake project (strata-vision, the image encoder). MTMD_VIDEO is off: the
  # server hands the encoder still images only, so it needs no ffmpeg. Both readers are built:
  #   strata-vision       the CPU one, the same AVX2 baseline as the engine, always the fallback
  #   strata-vision-hip   the GPU one, which is what setup.py chooses for a card of 24 GB or more
  #                       (hip_vision() in 0.2.0), and it is a separate program so that a PC where the
  #                       HIP runtime will not load still has the CPU reader to fall back on.
  # The CPU build stays non-HIP: the two are different programs by CMake's own rule (STRATA_VISION_CUDA
  # and STRATA_VISION_HIP refuse each other), and the target list reaches the GPU one alone.
  visionFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DLLAMA_DIR=${llamaCpp}"
    "-DSTRATA_VISION_CUDA=OFF"
    "-DSTRATA_PORTABLE=ON"
    "-DMTMD_VIDEO=OFF"
  ];
  visionCmakeFlags = builtins.concatStringsSep " " visionFlags;
  # the HIP reader: ggml-hip at the pinned commit, for the same target list as the engine. STRATA_PORTABLE
  # (already in the flags above) keeps the CPU side at the AVX2 baseline, which upstream's own HIP build
  # does not set but this package always wants.
  visionHipCmakeFlags = builtins.concatStringsSep " " (
    visionFlags
    ++ [
      "-DSTRATA_VISION_HIP=ON"
      "-DSTRATA_VISION_HIP_ARCHS='${archString}'"
      "-DCMAKE_PREFIX_PATH=${lib.makeSearchPath ":" visionHipLibs}"
      "-DCMAKE_HIP_COMPILER=${rocm.clr}/bin/amdclang++"
    ]
  );

  # ---- the engine: what the HIP target list reaches, together with the GPU picture reader ---------
  engine = stdenv.mkDerivation {
    pname = "strata-engine";
    inherit version src;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    # stdenv skips its default configure (it would run cmake with no flags and hit the network
    # FetchContent): everything happens in buildPhase
    configurePhase = "true";
    buildPhase = ''
      cmake -S . -B build -G Ninja ${cmakeFlags}
      ninja -C build strata strata-device
    '';
    installPhase = ''
      mkdir -p $out/bin
      for exe in strata strata-device; do
        install -m 755 build/$exe $out/bin/$exe
      done
    '';
    propagatedBuildInputs = rocmLibs;
  };

  # ---- the image encoder: no HIP target list, so a change to hipArchs does not rebuild it.
  visionBin = stdenv.mkDerivation {
    pname = "strata-vision-engine";
    inherit version src;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    configurePhase = "true";
    buildPhase = ''
      cmake -S tools/vision -B build-vision -G Ninja ${visionCmakeFlags}
      ninja -C build-vision strata-vision
    '';
    installPhase = ''
      mkdir -p $out/bin
      install -m 755 build-vision/bin/strata-vision $out/bin/strata-vision
    '';
  };

  # The GPU picture reader. Its CMake project forces RUNPATH "$ORIGIN" for a relocatable folder, which
  # stdenv's RPATH patching replaces with the store paths of what it links; propagatedBuildInputs is what
  # puts ROCm in that set, exactly as for the engine.
  visionHipBin = stdenv.mkDerivation {
    pname = "strata-vision-hip";
    inherit version src;
    nativeBuildInputs = [
      cmake
      ninja
    ];
    configurePhase = "true";
    buildPhase = ''
      cmake -S tools/vision -B build-vision -G Ninja ${visionHipCmakeFlags}
      # the target is still named strata-vision; only its OUTPUT_NAME becomes strata-vision-hip
      ninja -C build-vision strata-vision
    '';
    installPhase = ''
      mkdir -p $out/bin
      install -m 755 build-vision/bin/strata-vision-hip $out/bin/strata-vision-hip
    '';
    # llama.cpp's ggml-hip, which this project compiles, does `find_package(rocblas REQUIRED)` and links
    # roc::rocblas, so the GPU reader needs rocBLAS (791 MB) where the engine does not.
    propagatedBuildInputs = visionHipLibs;
  };

in
runCommand "strata-${m.size}-${version}"
  {
    meta = with lib; {
      description = "The Strata inference engine (HIP for ${archString}), its Python server and its image encoders, with the ${m.size} model (~${m.download} GB), its derived tokenizer, the MTP draft layer (28 pinned checkpoint shards, ~55 GB) and the mmproj vision encoder (~0.9 GB): the assembly of the stage derivations above and the model and draft-layer packages, whose closure is the whole package";
      homepage = "https://github.com/Niko1221/Strata";
      license = licenses.mit;
      platforms = [ "x86_64-linux" ];
      # `nix run .#strata -- --help`: the engine's own --help, which prints the usage without a GPU
      mainProgram = "strata";
    };
    # The compile stages as passthru: a version bump can check that the C++ still configures and builds
    # without pulling the ~120 GB of model downloads (nix build .#strata.passthru.engine).
    passthru = {
      engine = engine;
      vision = visionBin;
      visionHip = visionHipBin;
      inherit model mtp;
    };
  }
  ''
    # serve/server.py resolves symlinks for its ROOT (Path(__file__).resolve().parents[1]), so the Python
    # tree it runs from is real content here; only the payloads are links into their own store paths.
    mkdir -p $out/bin $out/etc/strata $out/models $out/pack $out/mtp $out/data
    cp -a ${src}/serve ${src}/tools ${src}/chat.py ${src}/requirements.txt $out/
    # serve/server.py and serve/lifeline.py import these two packages (engine_component, vision_reader,
    # procs, presets, offline), so they are part of the tree the server runs from. Only its terminal
    # dashboards (strata_cli/dashboard.py and friends) want rich/textual, and the server never imports
    # those, so the Python environment stays the five packages above.
    cp -a ${src}/strata_control ${src}/strata_cli $out/
    ln -s ${model}/shards $out/models/${m.size}
    ln -s ${model}/mmproj $out/vision
    ln -s ${model}/pack $out/pack/${m.packName}
    ln -s ${mtp} $out/mtp/rt
    cp ${src}/data/expert-profile.bin $out/data/
    ln -s ${engine}/bin/strata $out/bin/strata
    ln -s ${engine}/bin/strata-device $out/bin/strata-device
    ln -s ${visionBin}/bin/strata-vision $out/bin/strata-vision
    ln -s ${visionHipBin}/bin/strata-vision-hip $out/bin/strata-vision-hip

    # the config shape setup.py writes (exe, args, cwd, tokenizer, model_name), filled for this
    # machine: the low-RAM resident mode - the experts the GPU does not hold live in RAM, the PLE n-gram
    # table stays on disk, and the KV cache is int8 at the full 131072-token context. The model here is
    # ${m.size}: ${m.memoryNote} (setup.py's MODELS), so this is the config for a PC with that much memory
    # plus a 32 GB card.
    # Images need both halves, as setup.py writes them: the "vision" section makes the server spawn the
    # encoder (chat.py's /image, OpenAI image_url parts, Anthropic image blocks), and "--vision" in args is
    # what makes the engine accept the GENI requests it sends - without the flag the engine answers "this
    # engine was started without --vision". Since 0.2.0 the AMD backend has a GPU encoder of its own, and
    # that is what this config names: setup.py's hip_vision() picks it for a card of 24 GB or more, and
    # "cpu_exe" is the fallback it writes beside it, which the server takes over when the GPU reader cannot
    # start or the card is smaller than the reader's target list (serve/vision_reader.py).
    # "model" is the text model the encoder opens vocab-only for the image positions: shard 1, with shard 2
    # beside it under its original name, which is how llama.cpp resolves a split GGUF (one file for Gyro).
    # No "threads": the
    # encoder takes half the cores, what setup.py writes for a CPU encoder, and this package cannot know the
    # target PC's core count. JSON, so no comments here.
    cat > $out/etc/strata/strata.json <<'EOF'
    {
      "exe": "@OUT@/bin/strata",
      "args": [
        "--pack", "@OUT@/pack/@PACK@",
        "--native", "@OUT@/models/@MODEL@/@S1@",
        "--ple-gguf", "@OUT@/models/@MODEL@/@PLE@",
        "--expert-profile", "@OUT@/data/expert-profile.bin",
        "--expert-cache", "auto",
        "--prefill", "auto",
        "--spec", "4",
        "--spec-min-p", "0.5",
        "--mtp", "@OUT@/mtp/rt",
        "--max-context", "131072",
        "--kv", "int8",
        "--resident-experts",
        "--vision"
      ],
      "cwd": "@OUT@",
      "tokenizer": "@OUT@/pack/@PACK@/tokenizer",
      "model_name": "@MODEL_NAME@",
      "backend": "hip",
      "env": { "STRATA_RESIDENT_PIN": "0" },
      "vision": {
        "exe": "@OUT@/bin/strata-vision-hip",
        "cpu_exe": "@OUT@/bin/strata-vision",
        "mmproj": "@OUT@/vision/@MMPROJ@",
        "model": "@OUT@/models/@MODEL@/@S1@",
        "gpu": true,
        "max_tokens": 1024
      }
    }
    EOF
    sed -i -e "s|@OUT@|$out|" -e "s|@MODEL@|${m.size}|" -e "s|@PACK@|${m.packName}|" -e "s|@MODEL_NAME@|${m.modelName}|" -e "s|@S1@|${m.shard1}|" -e "s|@PLE@|${m.ple}|" -e "s|@MMPROJ@|${m.mmprojName}|" $out/etc/strata/strata.json
    # the metadata setup.py's installer records and the server reads from beside the engine. "version" is
    # the engine's own number, read out of the source it was built from rather than the package's version,
    # because the two move apart: this release is tagged v0.2.1 and its engine is 0.1.46. The vision
    # keys are what setup.py writes for a HIP engine with a GPU reader, and the server uses vision_archs to
    # decide whether the GPU reader covers the card it found (strata_control/vision_reader.py).
    engineVersion=$(sed -n 's/^[[:space:]]*project(strata VERSION \([0-9.]*\).*/\1/p' ${src}/CMakeLists.txt | head -1)
    # setup.py refuses an engine older than the model's minimum before it writes a config; the same check here
    # fails the build instead of shipping an engine that reads the pack as noise (a Gyro pack is v5 with
    # Hadamard-folded experts, which an older engine cannot rotate).
    if [ "$(printf '%s\n%s\n' "$engineVersion" "${m.minEngine}" | sort -V | head -1)" != "${m.minEngine}" ]; then
      echo "the engine is $engineVersion but the ${m.size} pack needs at least ${m.minEngine}" >&2
      exit 1
    fi
    cat > $out/bin/BUILD.json <<'EOF'
    {
      "version": "@ENGINE_VERSION@",
      "backend": "hip",
      "archs": [${lib.concatStringsSep ", " (map (a: "\"${a}\"") archList)}],
      "model": "${m.size}",
      "vision": "gpu",
      "vision_archs": [${lib.concatStringsSep ", " (map (a: "\"${a}\"") archList)}],
      "vision_gpu": "strata-vision-hip",
      "vision_cpu": "strata-vision",
      "prefill_mmq": ${lib.boolToString prefillMmq}
    }
    EOF
    sed -i "s|@ENGINE_VERSION@|$engineVersion|" $out/bin/BUILD.json
    # Since 0.2.1 an AMD engine package carries the hipBLASLt tuning tables of tools/hip in tuning/ beside
    # the engine and says in BUILD.json which hipBLASLt it was built against. A table's solution ids are
    # valid for one architecture family and one hipBLASLt version, so upstream's own staging script reads
    # the version from the headers this package builds against and copies only the tables that match - with
    # nixpkgs' hipBLASLt 1.2.2 that is gfx1100 and gfx1201, and nothing for gfx1151, whose tables need
    # 1.4/1.5; the script prints what is missing. strata-server picks the table for the card at startup and
    # logs the reason, so the service log says once per start which table the prompt path uses.
    PYTHONDONTWRITEBYTECODE=1 ${python}/bin/python3 ${src}/packaging/stage_tuning.py --stage $out/bin --archs "${archString}" --rocm ${rocm.hipblaslt}
    # strata-server: the Python server over the stored engine. The engine reads one table path from its
    # environment, and the card is only known at start, so the wrapper asks the server's own chooser
    # (strata_control/hipblaslt_tuning.py) which of the shipped tables fits this PC. Opt-in as upstream is:
    # STRATA_HIPBLASLT_TABLE=on, or "hipblaslt_table": true in the config - "auto" leaves the card's plain
    # hipBLAS alone except on gfx1151, for which nixpkgs' hipBLASLt has no table. The engine checks the
    # table's architecture and version again and falls back to plain hipBLAS for anything else.
    cat > $out/bin/strata-server <<'EOF'
    #!/bin/sh
    export STRATA_ROOT="@OUT@"
    export PYTHONNOUSERSITE=1
    cd "$STRATA_ROOT"
    CONF="$STRATA_ROOT/etc/strata/strata.json"
    prev=
    for a in "$@"; do
      case "$a" in
        --config=*) CONF="''${a#--config=}" ;;
        *) [ "$prev" = "--config" ] && CONF="$a" ;;
      esac
      prev=$a
    done
    export STRATA_CONFIG="$CONF"
    TABLE=$("@PY@/bin/python3" -c 'import json,os,sys; r=os.environ["STRATA_ROOT"]; cfg=json.load(open(os.environ["STRATA_CONFIG"])); sys.path.insert(0,r); from strata_control import hipblaslt_tuning as ht; d=ht.resolve(r+"/bin", ht.present_archs(cfg), cfg=cfg); d.message and print(d.message, file=sys.stderr); print(d.path or "")')
    [ -n "$TABLE" ] && export STRATA_HIPBLASLT_TUNING="$TABLE"
    exec "@PY@/bin/python3" -m serve.server --engine strata --config "$CONF" "$@"
    EOF
    sed -i -e "s|@OUT@|$out|" -e "s|@PY@|${python}|" $out/bin/strata-server
    chmod +x $out/bin/strata-server
  ''
