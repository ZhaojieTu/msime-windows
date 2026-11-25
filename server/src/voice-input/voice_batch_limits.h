#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace VoiceInput
{
inline constexpr std::size_t VoiceWavHeaderBytes = 44;

inline std::size_t BatchSampleLimit(const std::string &provider, const std::string &endpoint, std::size_t rate,
                                    std::size_t upload_bytes)
{
    if (upload_bytes <= VoiceWavHeaderBytes)
        return 0;
    const auto wav_frames = (upload_bytes - VoiceWavHeaderBytes) / 2;
    if (endpoint == "https://api.deepseek.com/v1/tools/asr")
        return (std::min)(wav_frames, rate * 110);
    if (provider == "minimax" || endpoint == "https://api.minimax.cn/v1/speech_to_text" ||
        endpoint == "https://api.minimaxi.com/v1/speech_to_text")
        return (std::min)(wav_frames, rate * 480);
    // The batch request encoder may pad SiliconFlow audio by 0.4 seconds.
    const auto padding = provider == "siliconflow" ? 2 * (rate / 5) : 0;
    return wav_frames > padding ? wav_frames - padding : 0;
}

struct VoiceSampleRange
{
    std::size_t begin;
    std::size_t end;
};

inline std::vector<VoiceSampleRange> PlanVoiceBatches(const std::vector<float> &samples, std::size_t limit,
                                                      std::size_t rate)
{
    std::vector<VoiceSampleRange> ranges;
    if (samples.empty() || limit == 0)
        return ranges;
    const auto frames = samples.size();
    auto remaining = 1 + (frames - 1) / limit;
    std::size_t begin = 0;
    const auto window = (std::max)(std::size_t{1}, rate / 20);
    while (remaining > 1)
    {
        const auto target = begin + 1 + (frames - begin - 1) / remaining;
        const auto earliest =
            (std::max)({begin + 1, frames - (remaining - 1) * limit, target - (std::min)(target, rate * 5)});
        auto cut = target;
        double lowest = 0;
        for (auto at = target;; at -= window)
        {
            double energy = 0;
            for (auto frame = at; frame < (std::min)(at + window, frames); ++frame)
                energy += std::abs(samples[frame]);
            if (at == target || energy < lowest)
            {
                lowest = energy;
                cut = at;
            }
            if (at - earliest < window)
                break;
        }
        ranges.push_back({begin, cut});
        begin = cut;
        --remaining;
    }
    ranges.push_back({begin, frames});
    return ranges;
}
struct VoiceRecognition
{
    std::string text;
    std::string error;
};

template <class Recognize>
VoiceRecognition TranscribeVoiceBatches(const std::vector<float> &samples, std::size_t limit, std::size_t rate,
                                        Recognize recognize)
{
    if (limit == 0)
        return {{}, "Invalid ASR upload size limit"};
    if (samples.size() <= limit)
        return recognize(samples);

    VoiceRecognition joined;
    for (const auto &range : PlanVoiceBatches(samples, limit, rate))
    {
        const std::vector<float> chunk(samples.begin() + range.begin, samples.begin() + range.end);
        auto part = recognize(chunk);
        if (!part.error.empty())
            return {{}, std::move(part.error)};
        if (!part.text.empty())
        {
            if (!joined.text.empty())
                joined.text += '\n';
            joined.text += part.text;
        }
    }
    return joined;
}
} // namespace VoiceInput
