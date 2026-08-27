#ifndef HARMONY_MAC_MVP_SAMPLE_INFO_H
#define HARMONY_MAC_MVP_SAMPLE_INFO_H

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <queue>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcodec_base.h>

struct EncodedBuffer {
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
    OH_AVCodecBufferAttr attr = {0, 0, 0, AVCODEC_BUFFER_FLAGS_NONE};
};

struct EncoderContext {
    std::mutex mutex;
    std::condition_variable condition;
    std::queue<EncodedBuffer> output;
};

#endif
