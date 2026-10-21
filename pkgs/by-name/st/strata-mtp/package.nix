# The MTP draft layer the engine speculates with, as a package of its own.
#
# It is size-independent and engine-independent: keyed on the checkpoint's pins and the pinned tools tree
# (strata-tools), never on the engine's source. A Strata release that leaves tools/mtp_*.py alone costs it
# nothing, and switching model size keeps it cached.
#
# The model GGUF ships no MTP head; the original BF16 checkpoint (Qwen/Qwen3.8-Flash-Next, 360 GB in 131
# shards) does: 31 `mtp.*` tensors (~5 GB) scattered over 28 of the shards. Those 28 shards (55.17 GB) and
# the checkpoint's index file are fetched as store paths, pinned to the repository's revision of 2026-09-30
# (the current `sha`) by their LFS sha256; the build then extracts only the MTP byte ranges from the local
# files and checks every tensor against the SHA256 table tools/mtp_fetch.py pins for that revision (#327) -
# the original range-fetching implementation, whose table stays the single source of truth for the pins. No
# network in the build.

{
  lib,
  runCommand,
  linkFarm,
  fetchurl,
  writeTextFile,
  python3,
  strataTools,
  strataLlamaCpp,
}:
let
  qwenRev = "de4b8e4d43b917e7706784d8bb445c9af86a3540";
  qwen =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/Qwen/Qwen3.8-Flash-Next/resolve/${qwenRev}/${name}";
      inherit sha256;
    };
  qwenIndex = qwen "model.safetensors.index.json" "99e815241ef03325536b0aaa4441deea45174c17fae31e10f0bb456410c590de";
  mtpShards = [
    (qwen "model-00037-of-00131.safetensors" "73b53c94d23589bdfde55b20538a515525f22fd37c7cdf24e85738ed771218e1")
    (qwen "model-00041-of-00131.safetensors" "0465251c296b1a6aa014480e54f0f23ce6899bca72ba2be4804cd9187095cc7c")
    (qwen "model-00043-of-00131.safetensors" "a88f0411382143c6eb5ddeed84280a80f18f18d94670bda54cee1c1cd47cd824")
    (qwen "model-00047-of-00131.safetensors" "eb79852b4266e63fc7050e79349ece1eb3160eedb13bdb5f39b4c768e0741a4f")
    (qwen "model-00049-of-00131.safetensors" "cbab68ff417bf8905ccfa1697deb5c6b42ae9ee9bf6cbb0ebe687e116e5e6da8")
    (qwen "model-00053-of-00131.safetensors" "1bf2bbe69b64fc9ac33c264490445a0b42a3488c6b87722d918c3d3abe6bbeab")
    (qwen "model-00057-of-00131.safetensors" "77ec2297055779ab6dc6e15e3a88837b888e13ce199543f12a40a5036e5b8a4a")
    (qwen "model-00060-of-00131.safetensors" "8fd21925cb11bc7cf68d7c5cab498f3c13f455aed32e8c5ac90cda92c6961487")
    (qwen "model-00062-of-00131.safetensors" "e62ba3c6e2e9e213b6aa0534498bb341e89b86ce388347a8421ccff0d5887f0a")
    (qwen "model-00066-of-00131.safetensors" "550a89f69aa7d57e58f344ac06e7ea0ef471813eb16a6adb95373339df895f6c")
    (qwen "model-00070-of-00131.safetensors" "9644884762cc198d27a2a4d1078702fa4744ad8ff272afc565568fc8e04c6f59")
    (qwen "model-00072-of-00131.safetensors" "2415f75c86da428daf68924f98f1bb159b0a589a9571f0d690f8a27ce4839689")
    (qwen "model-00076-of-00131.safetensors" "14860603fb56ceaf4748a819ca0e561c685ad1e2182d91cc32170a8b1cddcb9e")
    (qwen "model-00078-of-00131.safetensors" "e9ac55c3032056303f9f8cce6b0f486e0bfedad2258a384eff6531e973cd7220")
    (qwen "model-00082-of-00131.safetensors" "0fe8d836b886ac8942f74e835e17487f53454e96bf38263d45fb329006dde7a9")
    (qwen "model-00086-of-00131.safetensors" "757b82b98441356169d5030ac338d3a7d55fadc332c3f4c396fba795ac64d810")
    (qwen "model-00088-of-00131.safetensors" "2feec63478c327f8436222d0df2b1f1cdd65947704cc5bab0ae891122ed3656f")
    (qwen "model-00090-of-00131.safetensors" "af53d439e4e26865b7cfda192ef46a29762f3c49b1fe8e06b54adee132b80880")
    (qwen "model-00094-of-00131.safetensors" "c31221b8e6a5df3151c85e24fd1c8e0693af21fed7814d2804de032e8566e4b3")
    (qwen "model-00100-of-00131.safetensors" "78da7091e9a36803c4ccd1c10fa6dc0f61b65ad7e70c314722c0582a94c619f2")
    (qwen "model-00102-of-00131.safetensors" "6caf691248517c088adb462caef16a7c5bbcdad796ceb2fee4c3cb575a86e8e1")
    (qwen "model-00106-of-00131.safetensors" "2903f5b2c539142163c7157fd191d8799019dbfe3a5ab2560276546b9b0fa44e")
    (qwen "model-00108-of-00131.safetensors" "426251e0773e900de9a227db60fd8c05ee7f25b8d514458b7a8b37028f6d90ac")
    (qwen "model-00112-of-00131.safetensors" "90d2e46457dd629a0ebab7d3f4c36de7a0613518fcd3ba6e6a0143d9c24ae04f")
    (qwen "model-00114-of-00131.safetensors" "b8d004974b91dad16757c9ad6be6682756e17843c7026e441f2a075de33ab4f5")
    (qwen "model-00118-of-00131.safetensors" "ffe5cc04b3c2bdfeaba652267ecce7f9ded512646840effe6dd1908f65a299b4")
    (qwen "model-00120-of-00131.safetensors" "6a13f7374f7998ce5413fd1a94a2796f10a389ac4ba0da073e80fa91eca1b40e")
    (qwen "model-00124-of-00131.safetensors" "bf22358402faf83962759e05b13480151b138d03203d30f04524f8d53e498c7c")
  ];

  # stdenv `source`s every bare file in buildInputs (its "setup hook" mechanism), so the checkpoint shards
  # enter as a linkFarm directory, never as bare paths. The interpolation into linkFarm's script is what
  # makes the 55 GB of store paths dependencies of this derivation; the build sandbox resolves the links
  # through to them.
  mtpData = linkFarm "mtp-data" (
    [
      {
        name = "model.safetensors.index.json";
        path = qwenIndex;
      }
    ]
    ++ lib.map (s: {
      name = s.name;
      path = s;
    }) mtpShards
  );
  # The build-time extractor: the same layout tools/mtp_fetch.py fetch writes (tensors/<name>.bin
  # plus mtp-manifest.json), read from the local pinned shards instead of HTTP ranges, so
  # tools/mtp_pack.py and tools/mtp_rt.py run unchanged. Stdlib only.
  mtpLocal = writeTextFile {
    name = "mtp-local-extract";
    text = ''
      import hashlib, json, os, struct, sys
      index_path, out, shard_paths, tools_dir = sys.argv[1:5]
      sys.path.insert(0, tools_dir)
      import mtp_fetch                                   # for its pinned SHA256 table (#327)
      weight_map = json.load(open(index_path, encoding="utf-8"))["weight_map"]
      want = {k: v for k, v in weight_map.items() if k.startswith("mtp.")}
      by_name = {os.path.basename(p): p for p in shard_paths.split()}
      os.makedirs(os.path.join(out, "tensors"), exist_ok=True)
      manifest = []
      for name in sorted(want):
          shard = want[name]
          path = by_name.get(shard)
          if path is None:
              sys.exit("tensor %s: its shard %s is not among the pinned fetchurl inputs" % (name, shard))
          f = open(path, "rb")
          n = struct.unpack("<Q", f.read(8))[0]
          meta = json.loads(f.read(n))[name]
          a, b = meta["data_offsets"]
          f.seek(8 + n + a)
          data = f.read(b - a)
          f.close()
          digest = hashlib.sha256(data).hexdigest()
          want_hash = mtp_fetch.SHA256.get(name)
          if want_hash is not None and digest != want_hash:
              sys.exit("%s: sha256 %s is not the pinned %s" % (name, digest, want_hash))
          rel = "tensors/%s.bin" % name
          with open(os.path.join(out, rel), "wb") as o:
              o.write(data)
          manifest.append(dict(name=name, shard=shard, dtype=meta["dtype"], shape=meta["shape"],
                               start=8 + n + a, end=8 + n + b - 1, bytes=b - a,
                               file=rel, sha256=digest))
          print(name, b - a, flush=True)
      with open(os.path.join(out, "mtp-manifest.json"), "w", encoding="utf-8") as o:
          json.dump(manifest, o, indent=1)
      print("%d MTP tensors, %.3f GB" % (len(manifest), sum(r["bytes"] for r in manifest) / 1e9))
    '';
  };

  # Python for the extract: numpy + the regex module, and the two third-party imports llama.cpp's gguf-py
  # pulls in (pyyaml, requests); gguf-py itself is found through STRATA_GGUF_PY.
  toolsPython = python3.withPackages (p: [
    p.numpy
    p.regex
    p.pyyaml
    p.requests
  ]);
in
runCommand "strata-mtp-rt"
  {
    nativeBuildInputs = [ toolsPython ];
    buildInputs = [ mtpData ];
    env.STRATA_GGUF_PY = "${strataLlamaCpp}/gguf-py";
    env.PYTHONDONTWRITEBYTECODE = "1";
    meta = {
      description = "The Strata MTP draft layer: the ~5 GB of mtp.* tensors extracted from 28 pinned shards of the original BF16 checkpoint (~55 GB), packed Q2_0 and relaid out for the engine";
      homepage = "https://huggingface.co/Qwen/Qwen3.8-Flash-Next";
      # the base model's Qwen Community License, as setup.py records it for the model files
      license = lib.licenses.unfreeRedistributable;
      platforms = [ "x86_64-linux" ];
    };
  }
  ''
    # the ~5 GB of MTP tensors out of the 28 pinned checkpoint shards, every tensor checked against
    # tools/mtp_fetch.py's pinned SHA256 table, then packed Q2_0 and relaid out for the engine
    ${toolsPython}/bin/python3 ${mtpLocal} \
      ${mtpData}/model.safetensors.index.json $TMPDIR/mtp \
      "$(ls ${mtpData}/model-00*.safetensors)" ${strataTools}/tools
    ${toolsPython}/bin/python3 ${strataTools}/tools/mtp_pack.py --src $TMPDIR/mtp --experts q2_0 \
      --out $TMPDIR/mtp/mtp-q2_0.gguf
    ${toolsPython}/bin/python3 ${strataTools}/tools/mtp_rt.py --gguf $TMPDIR/mtp/mtp-q2_0.gguf --out $out
    cp ${strataTools}/data/draft_vocab.bin $out/draft_vocab.bin
  ''
