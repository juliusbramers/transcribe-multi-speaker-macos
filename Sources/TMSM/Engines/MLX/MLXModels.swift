import Foundation

/// The MLX models tmsm ships, each pinned to one Hugging Face commit with every file's size and
/// SHA-256. Changing a model is an explicit edit here; nothing follows a moving branch.
extension MLXEngine {
  /// The forced aligner every MLX entry uses for word timings.
  public static let aligner = MLXModel(
    repo: "aufklarer/Qwen3-ForcedAligner-0.6B-8bit", name: "Qwen3 forced aligner 0.6B 8-bit",
    revision: "0457b7f546f629bacd1671d57252f1c561347bcb",
    files: [
      .init(
        "config.json", 5982, "d616c65d46c4b90bdc651b0a0963ea932732241140f337f9bb6b0335a9c8ef09"),
      .init(
        "merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
      .init(
        "model.safetensors", 1_276_733_128,
        "a815242e6f63731568794dee3036a88bcb4b20df3d9407a0679e1f0e0242535e"),
      .init(
        "quantize_config.json", 214,
        "54a4f0a45de4b8afab2f70b7226344981bc6111622275d4a4a9c5f45986c3ebb"),
      .init(
        "tokenizer_config.json", 12666,
        "3ab80063f8511deb9566e6ad438d17b7a6277fcffd52d92854112f19d36bd81c"),
      .init(
        "vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ])

  /// MOSS-Transcribe-Diarize 0.9B, decoder in int8 (the audio encoder stays fp16).
  static let mossBit8Model = MLXModel(
    repo: "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8", name: "MOSS-Transcribe-Diarize 0.9B",
    revision: "90aa65287111a327db98eb83e325bd5332945edd",
    files: [
      .init(
        "added_tokens.json", 707, "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"
      ),
      .init(
        "audio_encoder.safetensors", 624_970_399,
        "9cd0ac331cba4fddbd3c770e1ee327a8d03cbd65c740fcc4eafe9bbf0d21a71d"),
      .init(
        "chat_template.jinja", 4762,
        "8641466a16b184ebaf7c4903391e607cfd532ab937e81a64120628ab79d827f4"),
      .init(
        "config.json", 1035, "a80f290aa7ff92dbcb255c1f98274a357ca69ab7c984c3de0ed35d56c78ced27"),
      .init(
        "decoder.safetensors", 633_438_366,
        "f43b7f2fe6ac2cbbc7bf54c3b4728d1fe424cb89f386d14dea38ed09e771d1fc"),
      .init(
        "export_config.json", 2372,
        "c66f9ec6850ea0a1fbec7369e975bbf831c1d790a9ba017b3264e2d25e216b2e"),
      .init(
        "generation_config.json", 107,
        "e53a4b3ce4f944230cf1ca8fed0c42f4ff0d8c1443eaf98b5315d987334dd9e4"),
      .init(
        "merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
      .init(
        "preprocessor_config.json", 315,
        "ba2e601484abc80f4cded977f9a4fd4a53175b7d35c2f2511f0cfc3a32ad2499"),
      .init(
        "processor_config.json", 292,
        "a978c2dd54a65b576c3dae4b654fe9bcbac1184c6db2df0afb2c90fcdc872ae7"),
      .init(
        "source_config.json", 2335,
        "2b2b7a6e61334152bdd7ecf8a4da3073b4940a097e193d1d2b22093e77535234"),
      .init(
        "special_tokens_map.json", 613,
        "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
      .init(
        "tokenizer.json", 11_423_222,
        "bcf03774334462d6e34b5005cb11120a62275f146ee2953e68731ecdbce84fbb"),
      .init(
        "tokenizer_config.json", 503,
        "61d04c96104177240688396655ae3f7cf38ce2ea036db867a1d2b6883e27c3d5"),
      .init(
        "validation.json", 1791, "83f2f9f5bdfc5a4cd84e2c94840437ff092767432a2f4332534b8aafe0707a2a"),
      .init(
        "vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ])

  static let qwen3Bit8Model = MLXModel(
    repo: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", name: "Qwen3-ASR 1.7B 8-bit",
    revision: "e5450a26d1fd417c45fc9c405651ddc3180a27a6",
    files: [
      .init(
        "config.json", 7188, "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"),
      .init(
        "merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
      .init(
        "model.safetensors", 2_463_307_541,
        "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"),
      .init(
        "model.safetensors.index.json", 78968,
        "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"),
      .init(
        "tokenizer_config.json", 12487,
        "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
      .init(
        "vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ])

  static let qwen3Bit5Model = MLXModel(
    repo: "aufklarer/Qwen3-ASR-1.7B-MLX-5bit", name: "Qwen3-ASR 1.7B 5-bit",
    revision: "1645ca9ce8767dac9a4a047e9de835950c42596e",
    files: [
      .init("config.json", 560, "d63514df8a5e247f7c1b6f457372777b8eb5d1ac855a24dd7bee629063f57932"),
      .init(
        "merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
      .init(
        "model.safetensors", 2_440_468_080,
        "4c3dd2e56a6fa3523bc996e728b7011362af317c6b0616c8d78bb1b8d9ff600e"),
      .init(
        "tokenizer_config.json", 12487,
        "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
      .init(
        "vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ])

  static let voxtralBit8Model = MLXModel(
    repo: "aufklarer/Voxtral-Mini-3B-2507-MLX-8bit", name: "Voxtral Mini 3B 8-bit",
    revision: "fd378a44090b8b06fdb9f415896e4672edb02ecf",
    files: [
      .init(
        "config.json", 1743, "3a5aecd2c4ec43116a15d6c969ef082829c9a292d2d7a3e5f50d34176c7c0d74"),
      .init(
        "generation_config.json", 108,
        "cebeed3d4a1680c9b311863385d32b91008480dfbf8cf7abc2142447b8f73b76"),
      .init(
        "model-00001-of-00002.safetensors", 5_368_741_916,
        "d497498404c4717e4be6f04b65ed5ab88c17ea08a4671c21dcf00f0f8a2d0f54"),
      .init(
        "model-00002-of-00002.safetensors", 197_276_087,
        "cdf722bf98262d6e310eb5ef92e562b415d557dc037b4e317c1b096c534b64fc"),
      .init(
        "model.safetensors.index.json", 113861,
        "7cfdb0801df87297677a2bddb3e6b4439810a8fd4d265d5fb27cab8abd5dc9cd"),
      .init("params.json", 731, "4a37e19f2524a44bebf36a3da37a55dde31b8df9eab9b35d359b9a315c74e991"),
      .init(
        "preprocessor_config.json", 357,
        "86d67d926e17d3a9bb0bae334c9fc46bc163181992357a0357c0aec2c7e131d1"),
      .init(
        "tekken.json", 14_894_206,
        "4aaf3836c2a5332f029ce85a7a62255c966f47b6797ef81dedd0ade9c862e4a8"),
    ])
}
