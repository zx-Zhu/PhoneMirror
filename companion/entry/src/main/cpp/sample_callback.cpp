#include "sample_callback.h"
#include <hilog/log.h>

void EncoderCallback::OnError(OH_AVCodec *, int32_t errorCode, void *)
{
    OH_LOG_ERROR(LOG_APP, "PhoneMirror encoder error: %{public}d", errorCode);
}

void EncoderCallback::OnStreamChanged(OH_AVCodec *, OH_AVFormat *, void *) {}
void EncoderCallback::OnNeedInputBuffer(OH_AVCodec *, uint32_t, OH_AVBuffer *, void *) {}

void EncoderCallback::OnNewOutputBuffer(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    if (userData == nullptr || buffer == nullptr) {
        return;
    }
    auto *context = static_cast<EncoderContext *>(userData);
    EncodedBuffer item;
    item.index = index;
    item.buffer = buffer;
    OH_AVBuffer_GetBufferAttr(buffer, &item.attr);
    {
        std::lock_guard<std::mutex> lock(context->mutex);
        context->output.push(item);
    }
    context->condition.notify_one();
}
