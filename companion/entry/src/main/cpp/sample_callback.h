#ifndef PHONE_MIRROR_COMPANION_SAMPLE_CALLBACK_H
#define PHONE_MIRROR_COMPANION_SAMPLE_CALLBACK_H

#include "sample_info.h"
#include <multimedia/player_framework/native_avcodec_videoencoder.h>


class EncoderCallback final {
public:
    static void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData);
    static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
    static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
};

#endif
