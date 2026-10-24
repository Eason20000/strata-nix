# strata-nix

A Nix flake that builds [Strata](https://github.com/Niko1221/Strata) — an OpenAI- and
Anthropic-compatible model server that runs a large MoE model on one AMD GPU plus system RAM.
Every model download is hash-pinned, so the build is reproducible and fetches nothing at
configure time.

Requires Linux `x86_64`, Nix with flakes enabled, an AMD GPU (default HIP targets:
`gfx1100`, `gfx1151`, `gfx1201`), and the disk and RAM listed in the model table below.

The model files carry the Qwen Community License, so building them needs unfree packages
allowed. This flake allows it for itself; your own configuration needs
`nixpkgs.config.allowUnfree = true`. The engine and its tools stay MIT.

## Models

Each size is a package of its own (`strata-model-<size>`): its GGUF shards, the pack and
tokenizer cut from them, and the image encoder for the family. `nix build .#strata-model-iq3-s`
builds that payload alone — downloads and pack, no engine — which is how to warm the cache
before switching a machine over. The default size everywhere is `IQ2_XS`.

| size | download | memory | notes |
| --- | --- | --- | --- |
| `Q2_0` | 66.4 GB | 48 GB RAM | 2-bit, the fastest |
| `IQ2_XS` | 68.0 GB | 48 GB RAM | 2-bit i-quant, a little better quality, close in speed |
| `IQ3_XXS` | 75.8 GB | 60 GB RAM | 3-bit i-quant, better quality, slower |
| `IQ3_S` | 83.6 GB | 62 GB RAM | 3.5-bit, the best quality, the slowest; wants a 64 GB PC |
| `Gyro-S` | 58.5 GB | 27.6 GB GPU+RAM | trellis TQ1_0, the smallest; lower quality than the 2-bit sizes |
| `Gyro-M` | 92.0 GB | 35 GB GPU+RAM | trellis TQ2_0, about IQ3_XXS quality in ~20% less memory |
| `DSV41_IQ1_M` | 239.0 GB | 34 GB RAM | DeepSeek-V4.1-Flash, IST-DAS 1.75 bpw: code and agent work, weaker prose |
| `DSV41_IQ2_XXS` | 256.8 GB | 40 GB RAM | DeepSeek-V4.1-Flash, IST-DAS 2.00 bpw: ~5-7 tokens a second on a 12 GB card |
| `DSV41_IQ2_XS` | 274.0 GB | 44 GB RAM | DeepSeek-V4.1-Flash, IST-DAS 2.25 bpw: the best of the three |
| `DSV41_UD_Q8_K_XL` | 508.4 GB | 306 GB RAM | DeepSeek-V4.1-Flash, Unsloth Dynamic 8-bit: wants hundreds of GB of RAM or several cards |

The `DSV41_*` sizes run a different engine binary (`bin/strata-dsv41`), need an NVMe drive —
their 110 GB n-gram table is read from disk for every word — and take up to an hour to start.
They read no pictures.

## Build and run

```sh
nix build .#strata                        # ~2 minutes of compile; downloads fetched once
nix run .#strata -- --help                # the engine's usage, from the store
nix shell .#strata --command strata-server  # OpenAI + Anthropic APIs on 127.0.0.1:8080
curl http://127.0.0.1:8080/health         # from another shell
```

`strata-server` forwards remaining flags to the server (`--port`, `--host`, `--api-key`,
`--gpu 0,1`, `--config <file>`):

```sh
nix shell .#strata --command strata-server --port 9000 --host 0.0.0.0 --api-key <a long random secret>
```

Serving other devices needs `--host 0.0.0.0` **together with** `--api-key`. If a card is not
found, run `nix shell .#strata --command strata-device --list-devices` to see what the machine
exposes.

For another card or size, pass the engine package's `callPackage` parameters — `hipArchs`,
`model` (a model package), `mtp` (`null` for a `DSV41_*` model) and `prefillMmq`:

```sh
nix build --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }; p = f.packages.x86_64-linux; in pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = p.strata-model-iq3-s; mtp = p.strata-mtp; }'
```

Use the flake's locked nixpkgs, not `<nixpkgs>`: another nixpkgs means another ROCm.

## NixOS service

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
          services.strata.hipArchs = [ "gfx1100" "gfx1151" "gfx1201" ];  # the card in the machine
          services.strata.model = "IQ3_S";                               # a size from the table above
          services.strata.apiKey = "a long random secret";               # or null + environment.STRATA_API_KEY
        };
      ];
    };
  };
}
```

The unit runs as the `strata` user with the `render` and `video` groups, keeps `/dev/kfd` and
`/dev/dri` visible, allows unlimited memlock, and has no start timeout — loading the model takes
minutes. Its working directory, `/var/lib/strata` (`services.strata.stateDir`), is the only
writable place. Other useful options: `services.strata.package` (any assembled package),
`services.strata.maxContext`, `services.strata.port`/`host`, `services.strata.gpu` or
`services.strata.gpuRoles`, `services.strata.env` for anything else the engine reads from the
environment, and `services.strata.extraConfig` for the config the server reads.
