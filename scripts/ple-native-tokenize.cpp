// Tokenize a UTF-8 text file with gufo's own Qwen tokenizer, read from the
// model's first GGUF shard, and write the token ids as int32 little-endian.
//
// Usage: ple-native-tokenize MODEL.gguf IN.txt OUT.ids [BOS]
// BOS != 0 prefixes the tokenizer's BOS id (gufo's server framing does not).
//
// Build (from the gufo tree, after `cmake --preset cpu-test` and target
// gufo_core), mirroring tools/llama_parity/gufo_probe.cpp:
//   g++ -std=c++20 -I. notes/.../ple-native-tokenize.cpp \
//       build/cpu-test/libgufo_core.a $(pkg-config --libs icu-uc icu-i18n) \
//       -o /tmp/ple-native-tokenize
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "src/core/gguf_reader.hpp"
#include "src/models/qwen/tokenizer.hpp"

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: %s MODEL.gguf IN.txt OUT.ids [BOS]\n", argv[0]);
    return 2;
  }
  std::string error;
  auto reader = gufo::core::GgufReader::OpenFile(argv[1], &error);
  if (!reader) {
    std::fprintf(stderr, "open failed: %s\n", error.c_str());
    return 1;
  }
  auto tokenizer =
      gufo::tokenization::QwenTokenizer::CreateFromGguf(*reader, &error);
  if (!tokenizer) {
    std::fprintf(stderr, "tokenizer failed: %s\n", error.c_str());
    return 1;
  }
  std::ifstream in(argv[2], std::ios::binary);
  std::string text((std::istreambuf_iterator<char>(in)),
                   std::istreambuf_iterator<char>());
  if (in.bad()) {
    std::fprintf(stderr, "cannot read %s\n", argv[2]);
    return 1;
  }
  std::vector<gufo::tokenization::TokenId> ids;
  if (argc > 4 && std::string(argv[4]) != "0") {
    ids = tokenizer->Encode(text, {.add_bos = true});
  } else {
    ids = tokenizer->Encode(text);
  }
  std::ofstream out(argv[3], std::ios::binary);
  out.write(reinterpret_cast<const char*>(ids.data()),
            static_cast<std::streamsize>(ids.size() * sizeof(ids[0])));
  out.close();
  if (!out) {
    std::fprintf(stderr, "cannot write %s\n", argv[3]);
    return 1;
  }
  std::printf("tokens=%zu vocab=%zu\n", ids.size(),
              tokenizer->GetVocabSize());
  return 0;
}
