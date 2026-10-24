{
  description = "Strata: an OpenAI- and Anthropic-compatible model server on one AMD GPU plus system RAM (Linux, ROCm from nixpkgs); the engine package is assembled over a model package (six sizes: the GSQ-RCO quants and the Gyro trellis quants) and an MTP draft-layer package, every download a pinned fetchurl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # the project source is not an input: the packages fetch it themselves with pkgs.fetchFromGitHub,
    # pinned to the v0.2.3.1 tag (the `version` in the engine package; the separate tools pin in
    # pkgs/by-name/st/strata-tools/ moves only when the packing tools change). To track main or bump the
    # version, change those fetches.
  };

  outputs =
    { self, nixpkgs }:
    let
      # allowUnfree because the model packages say what they are: the GGUF files carry the Qwen Community
      # License, so their meta is unfreeRedistributable and nixpkgs refuses to evaluate them otherwise. A
      # consumer building these packages from their own flake or NixOS configuration needs the same switch
      # (nixpkgs.config.allowUnfree = true); the engine, the image readers and the tools pin stay MIT.
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };

      # The two pins the by-name packages take as arguments rather than importing: the llama.cpp the engine
      # builds ggml from (and whose gguf-py the build-time tools import), and the Strata tools tree the packs
      # and the draft-layer extract run. The engine package imports the first itself; the model layer gets
      # both from here, which is what keeps its derivations free of the engine's source pin.
      strataLlamaCpp = import ./pkgs/by-name/st/strata/llama.cpp.nix {
        inherit (pkgs) fetchurl stdenvNoCC;
      };
      strataTools = pkgs.callPackage ./pkgs/by-name/st/strata-tools/package.nix { };
      modelArgs = {
        inherit strataTools strataLlamaCpp;
      };

      # One package per model size (pkgs/by-name/st/strata-model-<size>/): its GGUF shards, the pack cut from
      # shard 1 with the tokenizer derived from its metadata, and the family's image encoder. Keyed by package
      # name, which is also the flake output name (`nix build .#strata-model-iq3-s`). Each carries its payload
      # description in passthru.strata.
      models = {
        strata-model-iq2-xs = pkgs.callPackage ./pkgs/by-name/st/strata-model-iq2-xs/package.nix modelArgs;
        strata-model-q2-0 = pkgs.callPackage ./pkgs/by-name/st/strata-model-q2-0/package.nix modelArgs;
        strata-model-iq3-xxs = pkgs.callPackage ./pkgs/by-name/st/strata-model-iq3-xxs/package.nix modelArgs;
        strata-model-iq3-s = pkgs.callPackage ./pkgs/by-name/st/strata-model-iq3-s/package.nix modelArgs;
        strata-model-gyro-s = pkgs.callPackage ./pkgs/by-name/st/strata-model-gyro-s/package.nix modelArgs;
        strata-model-gyro-m = pkgs.callPackage ./pkgs/by-name/st/strata-model-gyro-m/package.nix modelArgs;
      };

      # The MTP draft layer: size-independent, pinned to the original checkpoint's shards and the tools pin.
      mtp = pkgs.callPackage ./pkgs/by-name/st/strata-mtp/package.nix modelArgs;

      # The engine and its assembly (pkgs/by-name/st/strata/package.nix: the source pin, the build, the
      # config the server reads) over a model package. hipArchs and prefillMmq are its other parameters,
      # default [ "gfx1100" "gfx1151" "gfx1201" ] and true; for another card, callPackage it yourself:
      #   pkgs.callPackage ./pkgs/by-name/st/strata/package.nix { hipArchs = [ "gfx1100" "gfx1201" ]; model = strataPkgs.strata-model-iq3-s; inherit (strataPkgs) strata-mtp; }
      # In a NixOS configuration, services.strata.hipArchs, services.strata.prefillMmq and
      # services.strata.model (a size string the module maps to the matching model package) do the same. The target list is validated by the source's own
      # hip_backend.cmake (gfx1100 + gfx1201 maintainer-validated, gfx1101 + gfx1200 community-validated,
      # the rest - gfx1151 included - build with a warning; docs/AMD_HIP.md), and is recorded in the
      # package's bin/BUILD.json.
      strataFor =
        model:
        pkgs.callPackage ./pkgs/by-name/st/strata/package.nix {
          inherit model mtp;
        };
      strata = strataFor models.strata-model-iq2-xs;
    in
    {
      # Packages exposed in this flake, each under its package name: the engine assembled over IQ2_XS, and the
      # pieces it is assembled from. A model package builds its payload alone - ~68 GB of downloads and the
      # pack - without the engine, and `nix build .#strata-model-iq3-s` is how to warm that cache before
      # switching a service to it. A configuration asks for one by size: services.strata.model = "IQ3_S";
      packages.x86_64-linux = {
        strata = strata;
        default = strata;
        strata-tools = strataTools;
        strata-mtp = mtp;
      }
      // models;

      # the service module (modules/services/strata.nix): import it in a NixOS configuration as
      # nixosModules.strata, then services.strata.enable = true
      nixosModules.strata = import ./modules/services/strata.nix;
    };
}
