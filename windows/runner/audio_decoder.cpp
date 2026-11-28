#include "audio_decoder.h"

#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kAudioDecoderChannelName[] = "com.livecall.studio/audio_decoder";

struct DecodedPcmResult {
  std::vector<uint8_t> pcm16_bytes;
  int32_t sample_rate = 0;
  int32_t decoded_samples = 0;
  int32_t duration_ms = 0;
  int32_t decode_ms = 0;
  std::string error_code;
  std::string error_message;
};

struct ComScopeGuard {
  bool should_uninit = false;
  ~ComScopeGuard() {
    if (should_uninit) {
      CoUninitialize();
    }
  }
};

struct MfScopeGuard {
  bool started = false;
  ~MfScopeGuard() {
    if (started) {
      MFShutdown();
    }
  }
};

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), needed);
  return wide;
}

DecodedPcmResult DecodeFileWithMediaFoundation(
    const std::string& file_path,
    int64_t max_duration_ms,
    const std::atomic<bool>& alive) {
  DecodedPcmResult out;
  const auto start_tp = std::chrono::steady_clock::now();

  const std::wstring wide_path = Utf8ToWide(file_path);
  if (wide_path.empty()) {
    out.error_code = "INVALID_PATH";
    out.error_message = "Failed to convert file path to UTF-16";
    return out;
  }

  ComScopeGuard com_guard;
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (SUCCEEDED(hr)) {
    com_guard.should_uninit = true;
  } else if (hr != RPC_E_CHANGED_MODE) {
    out.error_code = "COM_INIT_FAILED";
    out.error_message = "CoInitializeEx failed";
    return out;
  }

  MfScopeGuard mf_guard;
  hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
  if (FAILED(hr)) {
    out.error_code = "MF_INIT_FAILED";
    out.error_message = "MFStartup failed";
    return out;
  }
  mf_guard.started = true;

  Microsoft::WRL::ComPtr<IMFSourceReader> reader;
  hr = MFCreateSourceReaderFromURL(wide_path.c_str(), nullptr, &reader);
  if (FAILED(hr) || !reader) {
    out.error_code = "OPEN_FAILED";
    out.error_message = "MFCreateSourceReaderFromURL failed";
    return out;
  }

  hr = reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  if (FAILED(hr)) {
    out.error_code = "STREAM_SELECT_FAILED";
    out.error_message = "Failed to clear stream selection";
    return out;
  }
  hr = reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);
  if (FAILED(hr)) {
    out.error_code = "NO_AUDIO_STREAM";
    out.error_message = "No audio stream found";
    return out;
  }

  Microsoft::WRL::ComPtr<IMFMediaType> partial_type;
  hr = MFCreateMediaType(&partial_type);
  if (FAILED(hr)) {
    out.error_code = "MEDIA_TYPE_FAILED";
    out.error_message = "MFCreateMediaType failed";
    return out;
  }
  partial_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  partial_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  partial_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);

  hr = reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
      partial_type.Get());
  if (FAILED(hr)) {
    out.error_code = "UNSUPPORTED_FORMAT";
    out.error_message = "Failed to configure PCM16 output media type";
    return out;
  }

  Microsoft::WRL::ComPtr<IMFMediaType> output_type;
  hr = reader->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &output_type);
  if (FAILED(hr) || !output_type) {
    out.error_code = "MEDIA_TYPE_QUERY_FAILED";
    out.error_message = "Failed to query output media type";
    return out;
  }

  uint32_t sample_rate = (std::max)(
      8000u,
      MFGetAttributeUINT32(output_type.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND,
                           44100));
  uint32_t channels = (std::max)(
      1u,
      MFGetAttributeUINT32(output_type.Get(), MF_MT_AUDIO_NUM_CHANNELS, 2));
  const uint32_t bits_per_sample =
      MFGetAttributeUINT32(output_type.Get(), MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (bits_per_sample != 16) {
    out.error_code = "PCM_BIT_DEPTH_UNSUPPORTED";
    out.error_message = "Expected 16-bit PCM output from Media Foundation";
    return out;
  }

  int64_t max_samples =
      (max_duration_ms * static_cast<int64_t>(sample_rate)) / 1000;
  int64_t total_samples = 0;
  int null_sample_streak = 0;

  while (alive.load() && total_samples < max_samples) {
    DWORD flags = 0;
    Microsoft::WRL::ComPtr<IMFSample> sample;
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
        &flags, nullptr, &sample);
    if (FAILED(hr)) {
      if (total_samples > 0) {
        break;
      }
      out.error_code = "READ_SAMPLE_FAILED";
      out.error_message = "IMFSourceReader::ReadSample failed";
      return out;
    }
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      break;
    }
    if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
      Microsoft::WRL::ComPtr<IMFMediaType> updated_type;
      if (SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
              &updated_type)) &&
          updated_type) {
        sample_rate = (std::max)(
            8000u,
            MFGetAttributeUINT32(updated_type.Get(),
                                 MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate));
        channels = (std::max)(
            1u,
            MFGetAttributeUINT32(updated_type.Get(), MF_MT_AUDIO_NUM_CHANNELS,
                                 channels));
        max_samples =
            (max_duration_ms * static_cast<int64_t>(sample_rate)) / 1000;
      }
    }
    if (!sample) {
      if (++null_sample_streak >= 32) {
        break;
      }
      continue;
    }
    null_sample_streak = 0;

    Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr) || !buffer) {
      continue;
    }

    BYTE* data = nullptr;
    DWORD byte_len = 0;
    hr = buffer->Lock(&data, nullptr, &byte_len);
    if (SUCCEEDED(hr) && data != nullptr && byte_len > 0) {
      const size_t frame_bytes = static_cast<size_t>(channels) * sizeof(int16_t);
      const size_t available_frames = static_cast<size_t>(byte_len) / frame_bytes;
      const size_t remaining_frames =
          static_cast<size_t>(max_samples - total_samples);
      const size_t frames_to_copy =
          (std::min)(available_frames, remaining_frames);

      const int16_t* pcm16 = reinterpret_cast<const int16_t*>(data);
      const size_t prev_size = out.pcm16_bytes.size();
      out.pcm16_bytes.resize(prev_size + frames_to_copy * 2);
      for (size_t f = 0; f < frames_to_copy; ++f) {
        int32_t sum = 0;
        for (uint32_t ch = 0; ch < channels; ++ch) {
          sum += pcm16[f * channels + ch];
        }
        const int32_t averaged = sum / static_cast<int32_t>(channels);
        const int16_t mono = static_cast<int16_t>(
            (std::max)(-32768, (std::min)(32767, averaged)));
        out.pcm16_bytes[prev_size + f * 2] = static_cast<uint8_t>(mono & 0xFF);
        out.pcm16_bytes[prev_size + f * 2 + 1] =
            static_cast<uint8_t>((mono >> 8) & 0xFF);
      }
      total_samples += static_cast<int64_t>(frames_to_copy);
      buffer->Unlock();
    } else if (SUCCEEDED(hr)) {
      buffer->Unlock();
    }
  }

  const auto end_tp = std::chrono::steady_clock::now();
  out.decode_ms = static_cast<int32_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(end_tp - start_tp)
          .count());
  out.sample_rate = static_cast<int32_t>(sample_rate);
  out.decoded_samples = static_cast<int32_t>(total_samples);
  out.duration_ms = static_cast<int32_t>(
      (total_samples * 1000) / static_cast<int64_t>(sample_rate));
  return out;
}

}  // namespace

std::unique_ptr<AudioDecoderChannel> AudioDecoderChannel::Register(
    flutter::FlutterEngine* engine) {
  auto state = std::make_shared<AudioDecoderState>();
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kAudioDecoderChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [engine, state](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() != "decodeToMonoPcm16") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("INVALID_ARGS", "Expected map arguments");
          return;
        }
        auto path_it = args->find(flutter::EncodableValue("filePath"));
        if (path_it == args->end() ||
            !std::holds_alternative<std::string>(path_it->second)) {
          result->Error("INVALID_ARGS", "Missing filePath");
          return;
        }
        const std::string file_path = std::get<std::string>(path_it->second);
        int64_t max_duration_ms = 45000;
        auto dur_it = args->find(flutter::EncodableValue("maxDurationMs"));
        if (dur_it != args->end()) {
          if (const auto* v32 = std::get_if<int32_t>(&dur_it->second)) {
            max_duration_ms = *v32;
          } else if (const auto* v64 = std::get_if<int64_t>(&dur_it->second)) {
            max_duration_ms = *v64;
          }
        }
        max_duration_ms =
            (std::max)(int64_t{1000}, (std::min)(int64_t{180000}, max_duration_ms));

        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>
            shared_result(result.release());

        std::lock_guard<std::mutex> lock(state->workers_mutex);
        if (!state->alive.load()) {
          shared_result->Error("DISPOSED", "Audio decoder shutting down");
          return;
        }
        state->workers.emplace_back([engine, state, file_path, max_duration_ms,
                                     shared_result]() {
          DecodedPcmResult decoded = DecodeFileWithMediaFoundation(
              file_path, max_duration_ms, state->alive);
          if (!state->alive.load()) return;
          auto shared_decoded =
              std::make_shared<DecodedPcmResult>(std::move(decoded));
          engine->PostPlatformThreadTask([state, shared_result, shared_decoded]() {
            if (!state->alive.load()) return;
            if (!shared_decoded->error_code.empty()) {
              shared_result->Error(shared_decoded->error_code,
                                   shared_decoded->error_message);
              return;
            }
            flutter::EncodableMap payload;
            payload[flutter::EncodableValue("pcm16Bytes")] =
                flutter::EncodableValue(std::move(shared_decoded->pcm16_bytes));
            payload[flutter::EncodableValue("sampleRate")] =
                flutter::EncodableValue(shared_decoded->sample_rate);
            payload[flutter::EncodableValue("channels")] =
                flutter::EncodableValue(1);
            payload[flutter::EncodableValue("decodedSamples")] =
                flutter::EncodableValue(shared_decoded->decoded_samples);
            payload[flutter::EncodableValue("durationMs")] =
                flutter::EncodableValue(shared_decoded->duration_ms);
            payload[flutter::EncodableValue("decodeMs")] =
                flutter::EncodableValue(shared_decoded->decode_ms);
            shared_result->Success(flutter::EncodableValue(std::move(payload)));
          });
        });
      });

  return std::unique_ptr<AudioDecoderChannel>(
      new AudioDecoderChannel(std::move(channel), std::move(state)));
}

AudioDecoderChannel::AudioDecoderChannel(
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel,
    std::shared_ptr<AudioDecoderState> state)
    : channel_(std::move(channel)), state_(std::move(state)) {}

AudioDecoderChannel::~AudioDecoderChannel() {
  Shutdown();
}

void AudioDecoderChannel::Shutdown() {
  if (!state_) return;
  state_->alive.store(false);
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  std::vector<std::thread> to_join;
  {
    std::lock_guard<std::mutex> lock(state_->workers_mutex);
    to_join.swap(state_->workers);
  }
  for (auto& t : to_join) {
    if (t.joinable()) {
      t.join();
    }
  }
}
