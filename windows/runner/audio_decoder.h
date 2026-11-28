#ifndef RUNNER_AUDIO_DECODER_H_
#define RUNNER_AUDIO_DECODER_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

struct AudioDecoderState {
  std::atomic<bool> alive{true};
  std::mutex workers_mutex;
  std::vector<std::thread> workers;
};

class AudioDecoderChannel {
 public:
  static std::unique_ptr<AudioDecoderChannel> Register(
      flutter::FlutterEngine* engine);

  ~AudioDecoderChannel();

  void Shutdown();

 private:
  AudioDecoderChannel(
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel,
      std::shared_ptr<AudioDecoderState> state);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<AudioDecoderState> state_;
};

#endif  // RUNNER_AUDIO_DECODER_H_
