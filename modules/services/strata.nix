# The Strata service: the engine and its Python server as a systemd unit.
#
# The package is self-contained, so the service needs nothing outside its closure except the GPU device
# nodes (/dev/kfd and /dev/dri) and a writable directory for the engine's cwd. It runs on the package's own
# etc/strata/strata.json with the service's settings merged in: the pins stay in the package, this module
# adds only what a service has to know. The option descriptions below cover the rest.
#
# Import it from the flake (nixosModules.strata), then:
#
#   services.strata.enable = true;
#   services.strata.apiKey = "a long random secret";   # or environment.STRATA_API_KEY
#   services.strata.host = "0.0.0.0";                  # only if other devices should reach it
#
# Keyless servers answer only requests whose Host is a loopback name (v0.1.38's DNS-rebinding protection),
# so one reached under another name needs extraConfig.allowed_hosts = [ "that.name" ]. A key in the Nix
# config lands in the store, which is why apiKey defaults to null and the server reads the variable.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.strata;
  types = lib.types;

  # How the flake wires the by-name packages, repeated here for the default package: they take the pinned
  # llama.cpp and the pinned Strata tools tree as arguments rather than importing them, so a configuration
  # building them has to pass them in.
  strataLlamaCpp = import ../../pkgs/by-name/st/strata/llama.cpp.nix {
    inherit (pkgs) fetchurl stdenvNoCC;
  };
  strataTools = pkgs.callPackage ../../pkgs/by-name/st/strata-tools/package.nix { };
  strataPayloadArgs = {
    inherit strataTools strataLlamaCpp;
  };

  # services.strata.model names a size and this picks the by-name package that carries it. The engine
  # package takes a model package rather than a string - it is a by-name package and may only use its
  # arguments, so it cannot go looking for its siblings - which leaves the choice to make here.
  # The keys are setup.py's MODELS keys.
  modelPackages = {
    Q2_0 = "strata-model-q2-0";
    IQ2_XS = "strata-model-iq2-xs";
    IQ3_XXS = "strata-model-iq3-xxs";
    IQ3_S = "strata-model-iq3-s";
    Gyro-S = "strata-model-gyro-s";
    Gyro-M = "strata-model-gyro-m";
  };

  # The longest context the model was trained on. Past it the rotary angles have to be rescaled, and
  # setup.py's answer there is yarn with the factor the final context over the trained one.
  trainedContext = 262144;

  # The engine's performance switches as typed options instead of raw env. They are engine environment
  # variables, so they reach the config the same way the package's own STRATA_RESIDENT_PIN does; the raw
  # services.strata.env is applied after them, so setting the same variable there wins. The engine reads
  # them as numbers and treats an unset variable as "the default for this architecture", which is why a
  # null option leaves the key out rather than writing an empty value.
  perfEnv =
    (lib.optionalAttrs (cfg.hipWmma != null) { STRATA_HIP_WMMA = if cfg.hipWmma then "1" else "0"; })
    // (lib.optionalAttrs (cfg.coldOverlap != null) { STRATA_COLD_OVERLAP = toString cfg.coldOverlap; })
    // (lib.optionalAttrs (cfg.ioPrefetch != null) {
      STRATA_IO_PREFETCH = if cfg.ioPrefetch then "1" else "0";
    })
    # the priority the server gives the engine process. Since v0.2.2 the server starts it at nice +5 on a PC
    # whose graphics is part of the CPU so the desktop keeps its CPU share; the server reads this from the
    # config's env rather than the engine reading it.
    // (lib.optionalAttrs (cfg.engineNice != null) {
      STRATA_ENGINE_NICE = toString cfg.engineNice;
    });

  # The hipBLASLt table switch belongs to the server rather than to the engine's environment, so it is a
  # config key (strata_control/hipblaslt_tuning.py reads "hipblaslt_table") that bin/strata-server applies
  # when it picks the table for the card it finds.
  tuningCfg = lib.optionalAttrs (cfg.hipblasltTable != null) {
    hipblaslt_table = cfg.hipblasltTable;
  };

  # The config is written at build time, from the package's own file: the package is an input of this
  # derivation, so the store paths inside the config are real dependencies rather than text. (A
  # string read from the store at eval time carries no context and cannot be written back out.)
  confFile =
    pkgs.runCommand "strata-service-config.json"
      {
        srcs = [ cfg.package ];
      }
      ''
        ${pkgs.jq}/bin/jq -n \
          --slurpfile base ${cfg.package}/etc/strata/strata.json \
          --arg cwd "${cfg.stateDir}" \
          --argjson env '${builtins.toJSON (perfEnv // cfg.env)}' \
          --argjson extra '${builtins.toJSON (tuningCfg // cfg.extraConfig)}' \
          --argjson args '${builtins.toJSON cfg.engineArgs}' \
          --argjson model '${builtins.toJSON cfg.modelName}' \
          --argjson roles '${builtins.toJSON cfg.gpuRoles}' \
          --argjson ctx '${builtins.toJSON cfg.maxContext}' \
          --argjson trained '${toString trainedContext}' \
          '# rewrite one flag: drop every occurrence of it and the value that follows it, then append
           # ours, so a flag repeated in engineArgs cannot win (the engine keeps the last one it sees)
           def set_arg($name; $val):
             . as $a
             | [ range(0; $a | length) as $i
                 | select($a[$i] != $name and ($i == 0 or $a[$i - 1] != $name))
                 | $a[$i] ]
               + [ $name, $val ];
           # the context flags to write: --max-context, and past the trained length the yarn scaling
           # setup.py adds - unless the args already choose a rope method, which wins as it does there
           def context_args($tokens; $trained):
             [ [ "--max-context", ($tokens | tostring) ] ]
             + (if $tokens > $trained and (any(.[]; . == "--rope-scaling") | not)
                then [ [ "--rope-scaling", "yarn" ], [ "--rope-scale", ($tokens / $trained | tostring) ] ]
                else []
                end);
           def engine_args($base):
             (if $args != null then $args else ($base.args // []) end)
             | (if $ctx == null then [] else context_args($ctx; $trained) end) as $set
             | reduce $set[] as $kv (.; set_arg($kv[0]; $kv[1]));
           $base[0]
             + { cwd: $cwd,
                 env: (($base[0].env // {}) + $env),
                 args: engine_args($base[0]) }
             + (if $model != null then { model_name: $model } else {} end)
             + (if $roles != null then { gpu_roles: $roles } else {} end)
             + $extra' > $out
      '';

  # strata-server passes its own --config first; argparse takes the last one, so this one wins
  serverArgs = [
    "--config"
    confFile
  ]
  ++ lib.optionals (cfg.host != null) [
    "--host"
    cfg.host
  ]
  ++ [
    "--port"
    (toString cfg.port)
  ]
  ++ lib.optionals (cfg.apiKey != null) [
    "--api-key"
    cfg.apiKey
  ]
  ++ lib.optionals (cfg.gpu != null) [
    "--gpu"
    (toString cfg.gpu)
  ]
  ++ cfg.extraArgs;
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "the Strata model server (OpenAI- and Anthropic-compatible APIs)";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.callPackage ../../pkgs/by-name/st/strata/package.nix {
        inherit (cfg)
          hipArchs
          mtp
          prefillMmq
          ;
        model = pkgs.callPackage ../../pkgs/by-name/st/${modelPackages.${cfg.model}}/package.nix strataPayloadArgs;
      };
      description = "The Strata package to serve (the engine, the two picture readers and the server, assembled
        over the model package services.strata.model selects and services.strata.mtp). Set this to a package built
        for the card in the machine, or to the flake's own package.";
    };

    hipArchs = lib.mkOption {
      type = types.listOf types.str;
      default = [
        "gfx1100"
        "gfx1151"
        "gfx1201"
      ]; # the package's own default
      example = [
        "gfx1100"
        "gfx1201"
      ];
      description = "The HIP target list the default package is compiled for, one architecture per
        entry; only used to build the default package, so override services.strata.package instead when
        the machine's card is a different one.";
    };

    model = lib.mkOption {
      type = types.enum (lib.attrNames modelPackages);
      default = "IQ2_XS";
      example = "IQ3_S";
      description = "Which model to serve. It picks the model package the default package is assembled over -
        pkgs/by-name/st/strata-model-<size>/, carrying that size's pinned GGUF shards, the pack and tokenizer cut
        from them, and the image encoder - so switching size keeps the engine, both picture readers and the draft
        layer cached. The size decides which pins that package carries and which pack it runs, and its experts
        want memory (setup.py's MODELS: IQ2_XS 48 GB of RAM, IQ3_XXS 60, IQ3_S 62, Gyro-S 27.6 and Gyro-M 35 of
        VRAM and RAM together), so the machine must have that much. To serve a model package the flake does not
        carry, set services.strata.package to one assembled over it.";
    };

    mtp = lib.mkOption {
      type = types.package;
      default = pkgs.callPackage ../../pkgs/by-name/st/strata-mtp/package.nix strataPayloadArgs;
      description = "The MTP draft layer the engine speculates with, as its own package (pkgs/by-name/st/strata-mtp/).
        It is size-independent, so switching services.strata.model keeps it cached. Only used to build the default
        package.";
    };

    prefillMmq = lib.mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = "Whether the default package builds the GGML MMQ prompt path, the engine's fused
        prompt-expert kernels for the prefill. Only used to build the default package, so override
        services.strata.package instead when you want a package that is already built. It reaches the
        engine stage alone, so changing it rebuilds the engine, not the pack.";
    };

    port = lib.mkOption {
      type = types.port;
      default = 8080;
      description = "The port the API listens on.";
    };

    hipWmma = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = "Whether the prompt path's attention runs on the GPU's matrix cores (the engine's
        STRATA_HIP_WMMA). Null: the engine's choice for the card, which is on for RDNA4 (gfx1200/gfx1201)
        and off for RDNA3 (gfx1100/gfx1101/gfx1151). True forces it on, which is what a gfx11 card needs
        to get it at all; the kernel is the same one either way, and the engine says once in its log which
        it used. It changes the text slightly (the matrix cores accumulate differently), which is why the
        engine leaves it off for the older cards. For the per-prompt choice, set STRATA_HIP_WMMA=auto in
        services.strata.env instead.";
    };

    coldOverlap = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      example = 0;
      description = "How many layers' experts the engine computes straight out of the page cache instead
        of copying them first (the engine's STRATA_COLD_OVERLAP): 4 is its default, 0 turns it off. Null:
        the engine's default. It only applies when the experts are read in place from the model file, so
        with this package's config - the resident mode, whose experts come from pack/experts.bin - it
        changes nothing until services.strata.engineArgs replaces --resident-experts with
        --mmap-experts.";
    };

    ioPrefetch = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = "Whether the engine reads the experts it will need next on separate I/O threads while
        the current layer computes (the engine's STRATA_IO_PREFETCH). Null: the engine's default, which is
        on for a model read in place from the file on Linux and off for a pack's experts.bin. Like
        services.strata.coldOverlap it is about the file, so with this package's resident-experts config
        it changes nothing until services.strata.engineArgs replaces --resident-experts with
        --mmap-experts; upstream also turns it off on an AMD laptop APU whose driver resets with it and
        the adaptive expert tier.";
    };

    hipblasltTable = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = true;
      description = "Whether the prompt's dense matrix products run on one of the measured hipBLASLt
        solution tables the package ships in bin/tuning (the server's hipblaslt_table, which
        bin/strata-server applies at start). Null: automatic, which upstream enables on gfx1151 only - and
        nixpkgs' hipBLASLt has no gfx1151 table, so nothing is used until this is true. True: use the table
        for the card, which a community A/B measured at 251 to 529 prompt tokens per second on Strix Halo.
        False: never. A table changes which hipBLASLt solution runs, so answers can differ in the last
        digits; the engine checks the table's architecture and hipBLASLt version against the card and falls
        back to plain hipBLAS for anything it does not cover. To use a table of your own instead, set
        STRATA_HIPBLASLT_TUNING to its path in services.strata.env - the server leaves that choice alone.";
    };

    host = lib.mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = "The address to listen on. 127.0.0.1 is this machine only; 0.0.0.0 also serves
        other devices on the network, and then an API key is required.";
    };

    apiKey = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "a long random secret";
      description = "The key required on /v1/* (Authorization: Bearer or x-api-key). Null: the server
        uses $STRATA_API_KEY from the service environment instead, which is how to keep the key out of
        the Nix configuration.";
    };

    gpu = lib.mkOption {
      type = types.nullOr (
        types.oneOf [
          types.int
          types.str
        ]
      );
      default = null;
      example = "0,1";
      description = "The GPU (or the layer split across several, as \"0,1\") the engine runs on. Null:
        the engine's own choice. With several cards the server puts the faster one last - the Main card,
        which holds the last layers - and never puts built-in graphics last. This is the flag form of the
        choice, and it wins over services.strata.gpuRoles, which says the roles themselves.";
    };

    gpuRoles = lib.mkOption {
      type = types.nullOr (
        types.attrsOf (
          types.enum [
            "main"
            "helper"
            "off"
          ]
        )
      );
      default = null;
      example = lib.literalExpression ''
        { "1" = "main"; "0" = "helper"; }
      '';
      description = "What each graphics card is for on a machine with more than one, since v0.2.2: Main
        holds the last layers, the draft layer and the final check of every window, a Helper holds a share
        of the layers and of the expert cache, and an Off card gets no process at all. The keys are the card
        numbers the engine reports. This replaces services.strata.gpu rather than adding to it - passing
        --gpu is read as a hand-edited card list, which the server says it ignores. Null: the server's
        recommendation, which starts the fastest card as Main and a card of 8 GB or less as Off.";
    };

    engineNice = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      example = 0;
      description = "The nice value the server starts the engine process with (STRATA_ENGINE_NICE). Since
        v0.2.2 the server uses +5 on a PC whose graphics is part of the CPU (Strix Halo and the other
        APUs), because the engine's CPU pool would otherwise compete with the desktop for the CPU. Null:
        that automatic choice; 0 turns it off, which is what a headless machine wants - nothing else runs
        there, and the penalty only costs the engine.";
    };

    stateDir = lib.mkOption {
      type = types.str;
      default = "/var/lib/strata";
      description = "The engine's working directory: the only place it can write, since the package
        itself is a read-only store path. Created by StateDirectory.";
    };

    maxContext = lib.mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 32768;
      description = "The context window in tokens: how much one request can hold (the conversation, the files,
        the tool output). Null: the package's own, 131072. It rewrites --max-context in the engine arguments
        and leaves the rest of them as they are, so it composes with services.strata.engineArgs, which it is
        applied after. The sizes setup.py offers are 8192, 32768, 65536, 131072, 204800, 262144, 393216 and
        524288: the KV cache grows with the context and takes VRAM the resident experts would otherwise hold,
        and past 131072 the experts plus the cache want more RAM than a 64 GB PC has. The model is trained to
        262144 positions; a larger context also gets yarn rope scaling with the factor the context over
        262144, as setup.py writes it there - an explicit --rope-scaling in engineArgs (linear, or yarn with a
        --rope-scale of your own) is left alone.";
    };

    engineArgs = lib.mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = lib.literalExpression ''
        # the package's own args, with the resident mode swapped for the GGUF-in-place file tier:
        # engineArgs replaces the whole list, so start from the package's and change what you want
        (lib.remove "--resident-experts" (builtins.fromJSON (builtins.readFile "''${cfg.package}/etc/strata/strata.json").args))
        ++ [ "--mmap-experts" ]
      '';
      description = "The engine's arguments, replacing the package's list entirely: write out every flag the run
        needs, not only the ones you change (its --pack, --native and --ple-gguf point into the store, so read them
        out of the package's etc/strata/strata.json rather than retyping them). services.strata.maxContext is the
        cheaper way to move one flag: it rewrites --max-context inside the package's own list. Null: the package's
        own, unchanged.";
    };

    modelName = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The model name the API reports. Null: the package's.";
    };

    env = lib.mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        STRATA_RESIDENT_PIN = "1";
      };
      description = "Engine environment, added to what the package's config carries. Applied after the
        typed switches above, so a variable set here wins over them.";
    };

    extraConfig = lib.mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = {
        api_monitor = true;
        idle_unload_s = 300;
        allowed_hosts = [ "that.name" ];
        vision = null;
      };
      description = "Anything else the server's config accepts (sampling, aliases, mcp_servers,
        cors_origins, allowed_hosts, engine_silence_s, ...), merged into the generated config. The
        package's config has a `vision` entry for the image encoder, so setting it to null here turns
        image support off for this machine. Its `exe` is the GPU reader and `cpu_exe` the fallback: the
        server switches to the CPU reader by itself when the GPU one does not start, so a smaller card
        needs nothing here - to ask for the CPU reader outright, set vision to the package's section with
        exe pointing at bin/strata-vision and gpu false.";
    };

    extraArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--api-monitor"
        "--fit-max-tokens"
      ];
      description = "Extra flags for serve.server (--api-monitor, --idle-unload ...). --lazy is
        refused while the config has a vision entry, so turn images off with extraConfig first.";
    };

    user = lib.mkOption {
      type = types.str;
      default = "strata";
      description = "The user the service runs as.";
    };

    group = lib.mkOption {
      type = types.str;
      default = "strata";
      description = "The group the service runs as.";
    };

    openFirewall = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Open the port in the firewall. Only meaningful when host is not 127.0.0.1.";
    };

    startTimeout = lib.mkOption {
      type = types.str;
      default = "infinity";
      description = "systemd's start timeout. Loading the model takes minutes on the first start, so
        the default does not cut the service off in the middle of it.";
    };

    generatedConfigFile = lib.mkOption {
      type = types.path;
      internal = true;
      default = confFile;
      description = "The engine config the service runs with: the package's, with the service's
        settings merged in. Internal, so a test or a debug shell can read it.";
    };
  };

  config = lib.mkIf cfg.enable {
    # a gpu_roles the server cannot read is ignored rather than refused, so the shape is checked here
    assertions = lib.optionals (cfg.gpuRoles != null) [
      {
        assertion = cfg.gpu == null;
        message = "services.strata.gpu and services.strata.gpuRoles both choose cards, and --gpu wins: the server reads a card list it did not write as the person's order and ignores the roles. Keep one of the two.";
      }
      {
        assertion = lib.all (k: builtins.match "[0-9]+" k != null) (builtins.attrNames cfg.gpuRoles);
        message = "services.strata.gpuRoles keys are card numbers as strings, as { \"1\" = \"main\"; \"0\" = \"helper\"; }.";
      }
      {
        assertion = lib.any (r: r != "off") (builtins.attrValues cfg.gpuRoles);
        message = "services.strata.gpuRoles sets every card to off, which the server ignores (it falls back to the engine's own choice), and this engine cannot start without a card. Name one card main or helper.";
      }
      {
        assertion =
          builtins.length (builtins.attrValues (lib.filterAttrs (_: r: r == "main") cfg.gpuRoles)) <= 1;
        message = "services.strata.gpuRoles names one Main card at most; the others are helper or off.";
      }
    ];

    users.users.${cfg.user} = {
      group = cfg.group;
      isSystemUser = true;
    };
    users.groups.${cfg.group} = { };

    systemd.services.strata = {
      description = "Strata model server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "strata";
        ExecStart = lib.escapeShellArgs ([ "${cfg.package}/bin/strata-server" ] ++ serverArgs);
        Restart = "on-failure";
        RestartSec = 10;
        # the card is reached through the kernel driver: /dev/kfd and /dev/dri have to stay visible,
        # so no PrivateDevices, and the service needs the render/video groups
        SupplementaryGroups = [
          "render"
          "video"
        ];
        # the resident experts pin memory, and ROCm wants an unlimited memlock for that
        LimitMEMLOCK = "infinity";
        TimeoutStartSec = cfg.startTimeout;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        # strict makes the whole hierarchy read-only, so the service needs its own writable /tmp: the
        # image encoder creates its cache directory with tempfile.mkdtemp(), which falls back to the
        # process's cwd - the read-only store path - when /tmp is not writable.
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [ cfg.port ];
  };
}
