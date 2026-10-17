# strata-nix

A Nix flake that builds [Strata](https://github.com/Niko1221/Strata) — an OpenAI- and
Anthropic-compatible model server running on AMD GPUs plus system RAM. Model download
is hash-pinned, so the build is reproducible and needs no network at configure time.

## Requirements

- Linux, `x86_64`, Nix with flakes enabled
- An AMD GPU whose HIP architecture is in the target list (default `gfx1100`, `gfx1151`, `gfx1201`)
- Disk for the model, checkpoint shards and mmproj: ~124 GB of downloads for IQ2_XS, ~132 GB for
  IQ3_XXS, ~140 GB for IQ3_S
- RAM for the model's experts: 48 GB at IQ2_XS, 60 GB at IQ3_XXS, 62 GB at IQ3_S

## Models

`model` is a `callPackage` parameter, default `IQ2_XS`; the flake also exposes the IQ3 sizes as their own
outputs (`nix build .#strata-iq3-s`).

| `model` | download | RAM for its experts | notes |
| --- | --- | --- | --- |
| `Q2_0` | 66.4 GB | 48 GB | 2-bit, the fastest |
| `IQ2_XS` | 68.0 GB | 48 GB | 2-bit i-quant, a little better quality, close in speed |
| `IQ3_XXS` | 75.8 GB | 60 GB | 3-bit i-quant, better quality, slower |
| `IQ3_S` | 83.6 GB | 62 GB | 3.5-bit, the best quality, the slowest; wants a 64 GB PC |

## Build

```sh
nix build .#strata            # ~2 minutes of compile on a 16-core PC (downloads fetched once)
nix run .#strata -- --help    # the engine's usage, from the store
```

The caller-visible knobs are `callPackage` parameters of
`pkgs/by-name/st/strata/package.nix`:

```sh
nix build --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = "IQ3_S"; prefillMmq = false; }'
```

- `hipArchs` (default `[ "gfx1100" "gfx1151" "gfx1201" ]`) — the HIP target list, validated by the
  source's own `cmake/hip_backend.cmake`
- `model` (default `IQ2_XS`) — one of the sizes above
- `prefillMmq` (default `true`) — the GGML MMQ prompt path (`-DSTRATA_PREFILL_MMQ`)

All three are recorded in the package's `bin/BUILD.json`.

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
pictures (OpenAI `image_url` parts, Anthropic image blocks, `chat.py`'s `/image <path>`) through the
package's `bin/strata-vision`. For the AMD backend the encoder runs on **CPU** — upstream has no GPU image
encoder for HIP. Turn images off by making `vision` null in the config the server reads.

## As a NixOS service

```nix
{
  inputs.strata-nix.url = "github:<you>/strata-nix";
  outputs = { self, nixpkgs, strata-nix }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata-nix.nixosModules.strata
        {
          services.strata.enable = true;
          services.strata.hipArchs = [ "gfx1100" "gfx1151" "gfx1201" ];   # the card in the machine
          services.strata.model = "IQ3_S";                                # one of the sizes above
          services.strata.apiKey = "a long random secret";                # or null + environment.STRATA_API_KEY
        };
      ];
    };
  };
}
```

The unit runs as the `strata` user with the `render` and `video` groups, keeps `/dev/kfd` and `/dev/dri`
visible, allows unlimited memlock, and has no start timeout (loading the model takes minutes). Its working
directory is `/var/lib/strata`, the only writable place. `services.strata.package` takes any package
instead, such as `packages.strata-iq3-s`, and `services.strata.maxContext` sets the context window (the
package's 131072 by default) — past the model's trained 262144 it adds yarn rope scaling, as `setup.py`
does.
