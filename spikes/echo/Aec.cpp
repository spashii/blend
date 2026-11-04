// Spike S4: runs WebRTC AEC3 offline over a recording made by `lab record-echo`.
// Input: 3-channel float WAV, channel 0 the raw mic, channels 1 and 2 the speaker
// reference from a system tap. Output: the echo-cancelled mic as mono float WAV.
//
// usage: aec IN.wav OUT.wav [CAPTURE_DELAY_MS] [--ns]
//
// CAPTURE_DELAY_MS delays the mic relative to the reference, for when the tap delivers the
// reference later than the speakers play it (AEC3 cannot model a reference that lags).

#include <modules/audio_processing/include/audio_processing.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

struct Wav
{
    int rate = 0;
    int channels = 0;
    std::vector<float> samples; // interleaved
};

bool ReadWav(const char* path, Wav& wav)
{
    std::ifstream in(path, std::ios::binary);
    char riff[12];
    if (!in.read(riff, 12) || std::memcmp(riff, "RIFF", 4) || std::memcmp(riff + 8, "WAVE", 4)) {
        return false;
    }
    int format = 0, bits = 0;
    while (in) {
        char id[4];
        uint32_t size = 0;
        if (!in.read(id, 4) || !in.read(reinterpret_cast<char*>(&size), 4)) {
            break;
        }
        std::vector<char> chunk(size);
        in.read(chunk.data(), size);
        if (size & 1) {
            in.ignore(1);
        }
        if (!std::memcmp(id, "fmt ", 4)) {
            format = *reinterpret_cast<uint16_t*>(&chunk[0]);
            wav.channels = *reinterpret_cast<uint16_t*>(&chunk[2]);
            wav.rate = int(*reinterpret_cast<uint32_t*>(&chunk[4]));
            bits = *reinterpret_cast<uint16_t*>(&chunk[14]);
            if (format == 0xFFFE && size >= 26) {
                format = *reinterpret_cast<uint16_t*>(&chunk[24]);
            }
        } else if (!std::memcmp(id, "data", 4)) {
            if (format != 3 || bits != 32) {
                std::fprintf(stderr, "need 32-bit float WAV (format=%d bits=%d)\n", format, bits);
                return false;
            }
            wav.samples.resize(size / 4);
            std::memcpy(wav.samples.data(), chunk.data(), size);
        }
    }
    return wav.rate > 0 && !wav.samples.empty();
}

void WriteWav(const char* path, int rate, const std::vector<float>& mono)
{
    std::ofstream out(path, std::ios::binary);
    auto u32 = [&](uint32_t v) { out.write(reinterpret_cast<char*>(&v), 4); };
    auto u16 = [&](uint16_t v) { out.write(reinterpret_cast<char*>(&v), 2); };
    const uint32_t bytes = uint32_t(mono.size() * 4);
    out.write("RIFF", 4);
    u32(36 + bytes);
    out.write("WAVEfmt ", 8);
    u32(16);
    u16(3);
    u16(1);
    u32(uint32_t(rate));
    u32(uint32_t(rate * 4));
    u16(4);
    u16(32);
    out.write("data", 4);
    u32(bytes);
    out.write(reinterpret_cast<const char*>(mono.data()), bytes);
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: aec IN.wav OUT.wav [CAPTURE_DELAY_MS] [--ns]\n");
        return 2;
    }
    const int delayMs = argc > 3 && argv[3][0] != '-' ? std::atoi(argv[3]) : 0;
    bool ns = false;
    for (int i = 3; i < argc; i++) {
        ns = ns || std::string(argv[i]) == "--ns";
    }
    Wav wav;
    if (!ReadWav(argv[1], wav) || wav.channels < 2) {
        std::fprintf(stderr, "could not read %s\n", argv[1]);
        return 1;
    }
    const size_t frames = wav.samples.size() / wav.channels;
    const size_t block = size_t(wav.rate / 100);
    const size_t delay = size_t(delayMs) * size_t(wav.rate) / 1000;

    std::vector<float> mic(frames + delay, 0.0f), ref(frames + delay, 0.0f);
    for (size_t f = 0; f < frames; f++) {
        mic[f + delay] = wav.samples[f * wav.channels];
        float r = 0;
        for (int c = 1; c < wav.channels; c++) {
            r += wav.samples[f * wav.channels + c];
        }
        ref[f] = r / float(wav.channels - 1);
    }

    auto apm = webrtc::AudioProcessingBuilder().Create();
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.high_pass_filter.enabled = true;
    config.noise_suppression.enabled = ns;
    config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
    apm->ApplyConfig(config);
    webrtc::StreamConfig stream(wav.rate, 1);

    std::vector<float> out(mic.size(), 0.0f);
    std::vector<float> nearBlock(block), farBlock(block), outBlock(block);
    for (size_t at = 0; at + block <= mic.size(); at += block) {
        std::memcpy(farBlock.data(), &ref[at], block * 4);
        std::memcpy(nearBlock.data(), &mic[at], block * 4);
        float* farPtr = farBlock.data();
        float* nearPtr = nearBlock.data();
        float* outPtr = outBlock.data();
        apm->ProcessReverseStream(&farPtr, stream, stream, &farPtr);
        apm->set_stream_delay_ms(0);
        apm->ProcessStream(&nearPtr, stream, stream, &outPtr);
        std::memcpy(&out[at], outBlock.data(), block * 4);
        if ((at / block) % 500 == 499) {
            auto stats = apm->GetStatistics();
            std::printf("t=%5.1fs erle=%5.1f dB delay=%d ms\n", double(at) / wav.rate,
                stats.echo_return_loss_enhancement.value_or(NAN),
                stats.delay_ms.value_or(-1));
        }
    }
    out.erase(out.begin(), out.begin() + long(delay));
    WriteWav(argv[2], wav.rate, out);
    return 0;
}
