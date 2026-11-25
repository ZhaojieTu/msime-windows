#pragma once

#include <msime/voice/wav_writer.h>

#include <array>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace VoiceInput
{
namespace VoiceHistory
{
inline constexpr std::size_t MaxFrames = 16000 * 60 * 60;
inline constexpr auto RecordingName = "recording.wav";
inline constexpr auto TranscriptName = "transcript.txt";

inline void WriteAtomically(const std::filesystem::path &path, const char *bytes, std::size_t size)
{
    auto temp = path;
    temp += ".tmp";
    try
    {
        std::ofstream output(temp, std::ios::binary | std::ios::trunc);
        output.exceptions(std::ios::badbit | std::ios::failbit);
        output.write(bytes, static_cast<std::streamsize>(size));
        output.close();
        std::filesystem::rename(temp, path);
    }
    catch (...)
    {
        std::error_code ignored;
        std::filesystem::remove(temp, ignored);
        throw;
    }
}

inline std::filesystem::path SaveRecording(const std::filesystem::path &root, const std::vector<float> &samples)
{
    const auto wav = metasequoia::voice::WavWriter::create_wav(samples, metasequoia::voice::sample_rate, MaxFrames);
    std::filesystem::create_directories(root);
    const auto stamp =
        std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch())
            .count();
    for (unsigned suffix = 0; suffix < 100; ++suffix)
    {
        const auto path = root / (std::to_string(stamp) + "-" + std::to_string(suffix));
        if (!std::filesystem::create_directory(path))
            continue;
        WriteAtomically(path / RecordingName, reinterpret_cast<const char *>(wav.data()), wav.size());
        return path;
    }
    throw std::runtime_error("Cannot create a voice history entry");
}

inline void SaveTranscript(const std::filesystem::path &entry, const std::string &text)
{
    WriteAtomically(entry / TranscriptName, text.data(), text.size());
}

inline std::filesystem::path LatestUntranscribed(const std::filesystem::path &root)
{
    if (!std::filesystem::is_directory(root))
        return {};
    std::filesystem::path latest;
    auto latest_time = (std::filesystem::file_time_type::min)();
    for (const auto &entry : std::filesystem::directory_iterator(root))
    {
        if (!entry.is_directory() || entry.is_symlink())
            continue;
        const auto audio = entry.path() / RecordingName;
        if (!std::filesystem::is_regular_file(audio) || std::filesystem::exists(entry.path() / TranscriptName))
            continue;
        const auto time = std::filesystem::last_write_time(audio);
        if (latest.empty() || time > latest_time || (time == latest_time && entry.path() > latest))
        {
            latest = entry.path();
            latest_time = time;
        }
    }
    return latest;
}

// Retry only reads the canonical mono PCM files emitted by this history writer.
inline std::vector<float> ReadRecording(const std::filesystem::path &entry)
{
    const auto path = entry / RecordingName;
    const auto size = std::filesystem::file_size(path);
    if (size < 44 || size > 44 + 2 * MaxFrames || (size - 44) % 2 != 0)
        throw std::runtime_error("Invalid voice history audio size");
    std::ifstream input(path, std::ios::binary);
    input.exceptions(std::ios::badbit | std::ios::failbit);
    std::array<char, 44> header{};
    input.read(header.data(), header.size());
    const auto expected = metasequoia::voice::WavWriter::create_wav({});
    // The generated fields are fixed except the RIFF and data sizes.
    for (std::size_t i = 0; i < header.size(); ++i)
    {
        if ((i < 4 || (i >= 8 && i < 40)) && static_cast<unsigned char>(header[i]) != expected[i])
            throw std::runtime_error("Unsupported voice history WAV format");
    }
    const auto frames = (size - 44) / 2;
    std::vector<unsigned char> pcm(static_cast<std::size_t>(2 * frames));
    input.read(reinterpret_cast<char *>(pcm.data()), static_cast<std::streamsize>(pcm.size()));
    std::vector<float> result(static_cast<std::size_t>(frames));
    for (std::size_t i = 0; i < result.size(); ++i)
    {
        const unsigned sample = pcm[2 * i] | (unsigned(pcm[2 * i + 1]) << 8);
        result[i] = static_cast<float>(sample < 32768 ? int(sample) : int(sample) - 65536) / 32767.0f;
    }
    return result;
}
} // namespace VoiceHistory
} // namespace VoiceInput
