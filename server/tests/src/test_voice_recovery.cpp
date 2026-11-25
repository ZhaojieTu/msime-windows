#include "voice-input/voice_batch_limits.h"
#include "voice-input/voice_history.h"

#include <cmath>
#include <iostream>
#include <stdexcept>

#define CHECK(condition)                                                                                               \
    do                                                                                                                 \
    {                                                                                                                  \
        if (!(condition))                                                                                              \
            throw std::runtime_error(#condition);                                                                      \
    } while (false)

namespace
{
constexpr std::size_t Rate = 16000;
constexpr std::size_t UploadLimit = 20 * 1024 * 1024;

void TestVoiceBatching()
{
    const auto limit =
        VoiceInput::BatchSampleLimit("custom", "https://api.deepseek.com/v1/tools/asr", Rate, UploadLimit);
    CHECK(limit == 110 * Rate);
    CHECK(VoiceInput::BatchSampleLimit("minimax", "https://api.minimaxi.com/v1/speech_to_text", Rate, UploadLimit) ==
          480 * Rate);

    // Long enough to exceed both the provider's duration and the Server's upload limits.
    std::vector<float> samples(710 * Rate, 0.25f);
    samples.front() = 0.9f;
    samples.back() = -0.9f;
    std::size_t offset = 0;
    int requests = 0;
    const auto complete = VoiceInput::TranscribeVoiceBatches(samples, limit, Rate, [&](const auto &part) {
        CHECK(!part.empty() && part.size() <= limit);
        CHECK(std::equal(part.begin(), part.end(), samples.begin() + offset));
        offset += part.size();
        return VoiceInput::VoiceRecognition{std::to_string(++requests), {}};
    });
    CHECK(offset == samples.size() && requests == 7);
    CHECK(complete.text == "1\n2\n3\n4\n5\n6\n7" && complete.error.empty());

    requests = 0;
    const auto failed = VoiceInput::TranscribeVoiceBatches(samples, limit, Rate, [&](const auto &) {
        return ++requests == 2 ? VoiceInput::VoiceRecognition{{}, "simulated provider error"}
                               : VoiceInput::VoiceRecognition{"first part", {}};
    });
    CHECK(requests == 2 && failed.text.empty() && failed.error == "simulated provider error");
}

void TestHistoryRetry(const std::filesystem::path &root)
{
    using namespace VoiceInput::VoiceHistory;
    const std::vector<float> source{0.0f, 0.5f, -0.5f, 1.0f, -1.0f};
    const auto first = SaveRecording(root, source);
    CHECK(LatestUntranscribed(root) == first);
    const auto saved = ReadRecording(first);
    CHECK(saved.size() == source.size());
    for (std::size_t i = 0; i < saved.size(); ++i)
        CHECK(std::abs(saved[i] - source[i]) < 1.0f / 32767);

    // The retry recognizes the same recovered WAV and writes the unpolished response.
    const auto retry = VoiceInput::TranscribeVoiceBatches(saved, saved.size(), Rate, [&](const auto &audio) {
        CHECK(audio == saved);
        return VoiceInput::VoiceRecognition{"原始转写", {}};
    });
    SaveTranscript(first, retry.text);
    CHECK(LatestUntranscribed(root).empty());
    CHECK(std::filesystem::is_regular_file(first / RecordingName));
    std::ifstream output(first / TranscriptName, std::ios::binary);
    CHECK(std::string(std::istreambuf_iterator<char>(output), {}) == retry.text);

    const auto second = SaveRecording(root, source);
    CHECK(second != first && LatestUntranscribed(root) == second);
}
} // namespace

int main()
{
    namespace fs = std::filesystem;
    try
    {
        const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
        const auto root = fs::temp_directory_path() / ("msime-voice-history-test-" + std::to_string(now));
        CHECK(fs::create_directory(root));
        struct Cleanup
        {
            fs::path path;
            ~Cleanup()
            {
                std::error_code ignored;
                fs::remove_all(path, ignored);
            }
        } cleanup{root};
        TestVoiceBatching();
        TestHistoryRetry(root);
        std::cout << "BATCH_DATA_PRESERVED=1 ORDERED_TEXT=1 PARTIAL_FAILURE_BLOCKED=1 HISTORY_RETRY=1\n";
        return 0;
    }
    catch (const std::exception &error)
    {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
