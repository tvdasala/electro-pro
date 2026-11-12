// Escrita simples de arquivos WAV (PCM16 / Float32) para testes.
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace npno {

inline bool writeWav16(const std::string& path, const int16_t* interleaved, size_t frames, uint16_t channels,
                       uint32_t sampleRate) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const uint32_t dataBytes = uint32_t(frames * channels * 2);
    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f);
    u32(36 + dataBytes);
    std::fwrite("WAVEfmt ", 1, 8, f);
    u32(16);
    u16(1);
    u16(channels);
    u32(sampleRate);
    u32(sampleRate * channels * 2);
    u16(uint16_t(channels * 2));
    u16(16);
    std::fwrite("data", 1, 4, f);
    u32(dataBytes);
    std::fwrite(interleaved, 2, frames * channels, f);
    std::fclose(f);
    return true;
}

inline bool writeWavFloatStereo(const std::string& path, const std::vector<float>& L, const std::vector<float>& R,
                                uint32_t sampleRate) {
    std::vector<int16_t> pcm(L.size() * 2);
    for (size_t i = 0; i < L.size(); ++i) {
        auto conv = [](float x) {
            float y = x * 32767.0f;
            if (y > 32767.0f) y = 32767.0f;
            if (y < -32768.0f) y = -32768.0f;
            return int16_t(y);
        };
        pcm[2 * i] = conv(L[i]);
        pcm[2 * i + 1] = conv(R[i]);
    }
    return writeWav16(path, pcm.data(), L.size(), 2, sampleRate);
}

}  // namespace npno
