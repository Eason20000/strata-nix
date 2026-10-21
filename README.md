# strata-nix

A Nix flake that builds [Strata](https://github.com/Niko1221/Strata) — an OpenAI- and
Anthropic-compatible model server running on AMD GPUs plus system RAM. Model download
is hash-pinned, so the build is reproducible and needs no network at configure time.

## Requirements

- Linux, `x86_64`, Nix with flakes enabled
- An AMD GPU whose HIP architecture is in the target list (default `gfx1100`, `gfx1151`, `gfx1201`)
- Disk for the model, checkpoint shards and mmproj: ~124 GB of downloads for IQ2_XS, ~132 GB for
  IQ3_XXS, ~140 GB for IQ3_S, ~114 GB for Gyro-S, ~148 GB for Gyro-M
- Memory for the model: 48 GB of RAM at IQ2_XS, 60 GB at IQ3_XXS, 62 GB at IQ3_S; 27.6 GB of GPU plus
  system RAM together at Gyro-S, 35 GB at Gyro-M

## Models

Each size is a package of its own (`pkgs/by-name/st/strata-model-<size>/`, exposed as
`packages.x86_64-linux.strata-model-<size>`): its GGUF shards, the pack and tokenizer cut from them, and the
image encoder the family shares. The engine package is assembled over one of them, and the service names the
size it wants: `services.strata.model = "IQ3_S"` picks `strata-model-iq3-s`. The default everywhere is
`IQ2_XS`: `packages.strata` is assembled over it, and so is the service unless you set
`services.strata.model`. `nix build .#strata-model-iq3-s` builds that payload alone — its
downloads and the pack — without the engine, which is how to warm the cache before switching a machine over.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Q2_0` | 66.4 GB | 48 GB RAM | 2-bit, the fastest |
| `IQ2_XS` | 68.0 GB | 48 GB RAM | 2-bit i-quant, a little better quality, close in speed |
| `IQ3_XXS` | 75.8 GB | 60 GB RAM | 3-bit i-quant, better quality, slower |
| `IQ3_S` | 83.6 GB | 62 GB RAM | 3.5-bit, the best quality, the slowest; wants a 64 GB PC |
| `Gyro-S` | 58.5 GB | 27.6 GB GPU+RAM | trellis TQ1_0, the smallest; lower quality than the 2-bit sizes |
| `Gyro-M` | 92.0 GB | 35 GB GPU+RAM | trellis TQ2_0, about IQ3_XXS quality in ~20% less memory |

The Gyro files are agentionai's quantizations rather than ISTA's GSQ-RCO ones: one GGUF that carries the
n-gram table inside it, which is why a bigger download costs less memory. Its pack is marked v5 with a
`hadamard.txt` beside it (the experts are Hadamard-folded), which the engine this package builds rotates
natively.

## Build

```sh
nix build .#strata            # ~2 minutes of compile on a 16-core PC (downloads fetched once)
nix run .#strata -- --help    # the engine's usage, from the store
```

The model files carry the Qwen Community License, so the model and draft-layer packages say so in their
meta and nixpkgs refuses to evaluate them unless unfree packages are allowed. This flake allows it for
itself; a configuration that builds these packages on its own needs `nixpkgs.config.allowUnfree = true`.
The engine, the two picture readers and the tools pin are MIT.

The caller-visible knobs are `callPackage` parameters of
`pkgs/by-name/st/strata/package.nix`:

```sh
# the flake's locked nixpkgs, not <nixpkgs>: another nixpkgs means another ROCm and hipBLASLt, and a
# tuning table is valid for one hipBLASLt version only
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = p.strata-model-iq3-s; mtp = p.strata-mtp; prefillMmq = false; }'
```

- `hipArchs` (default `[ "gfx1100" "gfx1151" "gfx1201" ]`) — the HIP target list, validated by the
  source's own `cmake/hip_backend.cmake`
- `model` — a model package, one of `strata-model-{iq2-xs,q2-0,iq3-xxs,iq3-s,gyro-s,gyro-m}`
- `mtp` — the MTP draft-layer package (`strata-mtp`), size-independent
- `prefillMmq` (default `true`) — the GGML MMQ prompt path (`-DSTRATA_PREFILL_MMQ`)

`hipArchs` and `prefillMmq` are recorded in the package's `bin/BUILD.json`, which also carries the size the
assembly was built over.

The compile stages are `passthru` outputs, so a version bump can be checked without the ~120 GB of model
downloads: `nix build .#strata.passthru.engine`, `.passthru.vision` and `.passthru.visionHip`. They are also
the only things a version bump rebuilds: the packs and the draft layer run a separately pinned tools tree
(`strata-tools`), so a Strata release that leaves `tools/iq_pack.py` and `tools/mtp_*.py` alone costs the
~67 GB of pack work and the ~55 GB of checkpoint extract nothing. Move the tools pin only when those files
change.

## Run

```sh
nix shell .#strata --command strata-server        # OpenAI + Anthropic APIs on 127.0.0.1:8080
curl http://127.0.0.1:8080/health | python3 -m json.tool   # from another shell
```

`strata-server` reads the package's `etc/strata/strata.json` and forwards remaining flags to the server
(`--port`, `--host`, `--api-key`, `--gpu 0,1`, `--config <file>`), so:

```sh
nix shell .#strata --command strata-server --port 9000 --host 0.0.0.0 --api-key <a long random secret>
```

To serve other devices, `--host 0.0.0.0` must come **together with** `--api-key`. The engine alone is
`--command strata`; the device probe is `--command strata-device --list-devices` — run it first when a
card is not found.

## Images

The package's config carries a `vision` entry and `--vision` in the engine's args, so the server encodes
pictures (OpenAI `image_url` parts, Anthropic image blocks, `chat.py`'s `/image <path>`). Since v0.2.0 the
AMD backend has a GPU encoder of its own, and the package builds both: `bin/strata-vision-hip` (llama.cpp's
HIP backend, compiled for the same `hipArchs`) is what the config names, and `bin/strata-vision` (CPU) is
its `cpu_exe`. The server switches to the CPU reader by itself when the GPU one cannot start — no HIP
runtime, a card outside the target list, a busy card — so nothing has to be chosen per machine. The GPU
reader keeps about 1.4 GB of VRAM that the experts would otherwise use, which is why upstream prefers the
CPU reader under 24 GB; to ask for it outright, set `services.strata.extraConfig.vision` to the package's
section with `exe` at `bin/strata-vision` and `gpu` false. Turn images off by making `vision` null.

The GPU reader links rocBLAS (791 MB), which the engine itself does not need — that is the only cost of
shipping it.

## hipBLASLt tuning tables

Since v0.2.1 an AMD engine package carries measured hipBLASLt solution tables, and the package stages the
ones matching the hipBLASLt it links: `bin/tuning/<arch>-hipblaslt-<version>.txt`, with that version in
`bin/BUILD.json` as `hipblaslt_version`. nixpkgs' hipBLASLt is 1.2.2 (100202), for which the source has
tables for gfx1100 and gfx1201 and none for gfx1151 — its tables need hipBLASLt 1.4 or 1.5 — so a Strix
Halo build keeps plain hipBLAS. A table decides which hipBLASLt solution runs the prompt's dense matrix
products, so answers can differ in the last digits, and upstream's automatic choice takes one only on
gfx1151, where a community A/B measured 251 to 529 prompt tokens per second. Since nixpkgs' hipBLASLt has
no gfx1151 table, nothing is used here until you ask: `services.strata.hipblasltTable = true`, `false` to
refuse one. `strata-server` picks the table for the card it finds at start and exports it to the engine,
which checks the architecture and version again and falls back to plain hipBLAS for anything the table does
not cover. To try a table of your own, set `STRATA_HIPBLASLT_TUNING` to its path in
`services.strata.env` — the server leaves that choice alone.

## As a NixOS service

```nix
{
  inputs.strata-nix.url = "github:ShadowApex/strata-nix";
  outputs = { self, nixpkgs, strata-nix }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata-nix.nixosModules.strata
        {
          services.strata.enable = true;
          services.strata.hipArchs = [ "gfx1100" "gfx1151" "gfx1201" ];   # the card in the machine
          services.strata.model = "IQ3_S";                                      # one of the sizes in the table above
          services.strata.apiKey = "a long random secret";                # or null + environment.STRATA_API_KEY
        };
      ];
    };
  };
}
```

The unit runs as the `strata` user with the `render` and `video` groups, keeps `/dev/kfd` and `/dev/dri`
visible, allows unlimited memlock, and has no start timeout (loading the model takes minutes). Its working
directory is `/var/lib/strata`, the only writable place. `services.strata.package` takes any assembled
package instead, such as `packages.strata`; `services.strata.model` names a size and `services.strata.mtp` is
the draft-layer package, and both only build the default one, so switching size keeps the engine and the
picture readers cached.
`services.strata.maxContext` sets the context window (the package's 131072 by default) — past the model's
trained 262144 it adds yarn rope scaling, as `setup.py` does.

Three of the engine's v0.2.0 performance switches are typed options, and they write engine environment
variables into the generated config: `services.strata.hipWmma` (matrix-core attention on the prompt path —
`true` is what a gfx11 card needs to get it at all), `services.strata.coldOverlap` and
`services.strata.ioPrefetch` (both about reading the model file in place, so they only bite once the engine
args switch from `--resident-experts` to `--mmap-experts`). Anything else the engine reads from the
environment goes in `services.strata.env`, which is applied after them. The fourth switch is the server's
rather than the engine's: `services.strata.hipblasltTable` writes a config key, not an environment variable.
