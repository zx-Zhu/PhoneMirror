#include "sample_callback.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arpa/inet.h>
#include <atomic>
#include <condition_variable>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <ifaddrs.h>
#include <mutex>
#include <napi/native_api.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <queue>
#include <signal.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>

namespace {
constexpr uint32_t MAGIC = 0x484D434D; // HMCM
constexpr uint16_t DEFAULT_PORT = 39876;
constexpr int32_t VIDEO_WIDTH = 720;
constexpr int32_t VIDEO_HEIGHT = 1552;
constexpr int32_t VIDEO_FPS = 60;
constexpr int64_t VIDEO_BITRATE = 8'000'000;
constexpr const char *INBOX_PATH = "/data/storage/el2/base/files/inbox";

enum PacketType : uint8_t {
    VIDEO = 1,
    FILE_TO_PHONE_BEGIN = 10,
    FILE_TO_PHONE_CHUNK = 11,
    FILE_TO_PHONE_END = 12,
    POINTER_CONTROL = 20,
    TEXT_CONTROL = 21,
    FILE_TO_MAC_BEGIN = 30,
    FILE_TO_MAC_CHUNK = 31,
    FILE_TO_MAC_END = 32,
};

std::atomic<bool> serverRunning{false};
std::atomic<bool> captureRunning{false};
int listenFd = -1;
int clientFd = -1;
std::mutex clientMutex;
std::mutex sendMutex;
std::thread acceptThread;
std::thread encoderThread;

std::mutex controlMutex;
std::queue<std::string> controlQueue;
std::mutex codecConfigMutex;
std::vector<uint8_t> codecConfig;
std::atomic<uint64_t> encodedFrameCount{0};


int incomingFileFd = -1;
std::mutex incomingFileMutex;

OH_AVScreenCapture *screenCapture = nullptr;
OH_AVCodec *videoEncoder = nullptr;
OHNativeWindow *encoderSurface = nullptr;
EncoderContext encoderContext;

uint64_t HostToNetwork64(uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return (static_cast<uint64_t>(htonl(static_cast<uint32_t>(value))) << 32) |
           htonl(static_cast<uint32_t>(value >> 32));
#else
    return value;
#endif
}

bool WriteAll(int fd, const uint8_t *data, size_t size)
{
    size_t sent = 0;
    while (sent < size) {
        ssize_t result = send(fd, data + sent, size - sent, MSG_NOSIGNAL);
        if (result <= 0) {
            return false;
        }
        sent += static_cast<size_t>(result);
    }
    return true;
}

bool ReadAll(int fd, uint8_t *data, size_t size)
{
    size_t received = 0;
    while (received < size) {
        ssize_t result = recv(fd, data + received, size - received, 0);
        if (result <= 0) {
            return false;
        }
        received += static_cast<size_t>(result);
    }
    return true;
}

void CloseClient()
{
    std::lock_guard<std::mutex> lock(clientMutex);
    if (clientFd >= 0) {
        shutdown(clientFd, SHUT_RDWR);
        close(clientFd);
        clientFd = -1;
    }
}

bool SendPacket(uint8_t type, uint16_t flags, int64_t pts, const uint8_t *payload, uint32_t length)
{
    std::lock_guard<std::mutex> sendLock(sendMutex);
    int fd;
    {
        std::lock_guard<std::mutex> lock(clientMutex);
        fd = clientFd;
    }
    if (fd < 0) {
        return false;
    }

    uint8_t header[20] = {};
    uint32_t magic = htonl(MAGIC);
    uint16_t networkFlags = htons(flags);
    uint32_t networkLength = htonl(length);
    uint64_t networkPts = HostToNetwork64(static_cast<uint64_t>(pts));
    memcpy(header, &magic, 4);
    header[4] = 1;
    header[5] = type;
    memcpy(header + 6, &networkFlags, 2);
    memcpy(header + 8, &networkLength, 4);
    memcpy(header + 12, &networkPts, 8);

    if (!WriteAll(fd, header, sizeof(header)) || (length > 0 && !WriteAll(fd, payload, length))) {
        CloseClient();
        return false;
    }
    return true;
}

std::string SanitizeFileName(const std::string &name)
{
    std::string result;
    for (char ch : name) {
        if (ch == '/' || ch == '\\' || ch == '\0') {
            result.push_back('_');
        } else {
            result.push_back(ch);
        }
    }
    if (result.empty() || result == "." || result == "..") {
        return "received-file";
    }
    return result.substr(0, 200);
}

void PushControl(uint8_t type, const std::vector<uint8_t> &payload)
{
    std::string value(reinterpret_cast<const char *>(payload.data()), payload.size());
    std::string envelope = type == POINTER_CONTROL ? "P:" + value : "T:" + value;
    std::lock_guard<std::mutex> lock(controlMutex);
    if (controlQueue.size() > 256) {
        controlQueue.pop();
    }
    controlQueue.push(std::move(envelope));
}

void HandleClient(int fd)
{
    while (serverRunning.load()) {
        uint8_t header[20];
        if (!ReadAll(fd, header, sizeof(header))) {
            break;
        }
        uint32_t magic;
        uint32_t length;
        memcpy(&magic, header, 4);
        memcpy(&length, header + 8, 4);
        magic = ntohl(magic);
        length = ntohl(length);
        if (magic != MAGIC || length > 64 * 1024 * 1024) {
            break;
        }
        std::vector<uint8_t> payload(length);
        if (length > 0 && !ReadAll(fd, payload.data(), length)) {
            break;
        }

        uint8_t type = header[5];
        if (type == POINTER_CONTROL || type == TEXT_CONTROL) {
            PushControl(type, payload);
        } else if (type == FILE_TO_PHONE_BEGIN) {
            mkdir(INBOX_PATH, 0770);
            std::string name = SanitizeFileName(std::string(payload.begin(), payload.end()));
            std::lock_guard<std::mutex> lock(incomingFileMutex);
            if (incomingFileFd >= 0) {
                close(incomingFileFd);
            }
            std::string path = std::string(INBOX_PATH) + "/" + name;
            incomingFileFd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0660);
        } else if (type == FILE_TO_PHONE_CHUNK) {
            std::lock_guard<std::mutex> lock(incomingFileMutex);
            if (incomingFileFd >= 0 && !payload.empty()) {
                (void)write(incomingFileFd, payload.data(), payload.size());
            }
        } else if (type == FILE_TO_PHONE_END) {
            std::lock_guard<std::mutex> lock(incomingFileMutex);
            if (incomingFileFd >= 0) {
                fsync(incomingFileFd);
                close(incomingFileFd);
                incomingFileFd = -1;
            }
        }
    }
}

void AcceptLoop()
{
    while (serverRunning.load()) {
        sockaddr_in address{};
        socklen_t addressLength = sizeof(address);
        int fd = accept(listenFd, reinterpret_cast<sockaddr *>(&address), &addressLength);
        if (fd < 0) {
            if (serverRunning.load()) {
                usleep(100'000);
            }
            continue;
        }
        int keepAlive = 1;
        int keepIdle = 10;
        int keepInterval = 3;
        int keepCount = 3;
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, sizeof(keepAlive));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &keepIdle, sizeof(keepIdle));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepInterval, sizeof(keepInterval));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepCount, sizeof(keepCount));
        CloseClient();
        {
            std::lock_guard<std::mutex> lock(clientMutex);
            clientFd = fd;
        }
        {
            std::lock_guard<std::mutex> lock(codecConfigMutex);
            if (!codecConfig.empty()) {
                SendPacket(VIDEO, static_cast<uint16_t>(AVCODEC_BUFFER_FLAGS_CODEC_DATA), 0,
                           codecConfig.data(), static_cast<uint32_t>(codecConfig.size()));
            }
        }
        if (videoEncoder != nullptr) {
            OH_AVFormat *request = OH_AVFormat_Create();
            OH_AVFormat_SetIntValue(request, OH_MD_KEY_REQUEST_I_FRAME, 1);
            OH_VideoEncoder_SetParameter(videoEncoder, request);
            OH_AVFormat_Destroy(request);
        }
        HandleClient(fd);
        CloseClient();
    }
}

int StartTcpServer(uint16_t port)
{
    if (serverRunning.exchange(true)) {
        return 0;
    }
    signal(SIGPIPE, SIG_IGN);
    mkdir(INBOX_PATH, 0770);
    listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) {
        serverRunning.store(false);
        return -1;
    }
    int reuse = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(port);
    if (bind(listenFd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 || listen(listenFd, 1) != 0) {
        close(listenFd);
        listenFd = -1;
        serverRunning.store(false);
        return -2;
    }
    acceptThread = std::thread(AcceptLoop);
    return 0;
}

void StopTcpServer()
{
    serverRunning.store(false);
    CloseClient();
    if (listenFd >= 0) {
        shutdown(listenFd, SHUT_RDWR);
        close(listenFd);
        listenFd = -1;
    }
    if (acceptThread.joinable()) {
        acceptThread.join();
    }
    std::lock_guard<std::mutex> lock(incomingFileMutex);
    if (incomingFileFd >= 0) {
        close(incomingFileFd);
        incomingFileFd = -1;
    }
}

void OnCaptureError(OH_AVScreenCapture *, int32_t errorCode, void *)
{
    OH_LOG_ERROR(LOG_APP, "PhoneMirror screen capture error: %{public}d", errorCode);
}

void OnCaptureState(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode state, void *)
{
    if (state == OH_SCREEN_CAPTURE_STATE_STARTED) {
        OH_AVScreenCapture_SetCanvasRotation(capture, true);
        OH_AVScreenCapture_ResizeCanvas(capture, VIDEO_WIDTH, VIDEO_HEIGHT);
        OH_AVScreenCapture_ShowCursor(capture, true);
        OH_AVScreenCapture_SetMaxVideoFrameRate(capture, VIDEO_FPS);
    }
}

void OnCaptureData(OH_AVScreenCapture *, OH_AVBuffer *, OH_AVScreenCaptureBufferType, int64_t, void *) {}

void OnDisplaySelected(OH_AVScreenCapture *, uint64_t, void *) {}

void ConfigureCapture(OH_AVScreenCaptureConfig &config)
{
    OH_AudioCaptureInfo mic = {.audioSampleRate = 48000, .audioChannels = 2, .audioSource = OH_MIC};
    OH_AudioCaptureInfo inner = {.audioSampleRate = 48000, .audioChannels = 2, .audioSource = OH_ALL_PLAYBACK};
    OH_AudioEncInfo audioEnc = {.audioBitrate = 48000, .audioCodecformat = OH_AudioCodecFormat::OH_AAC_LC};
    OH_AudioInfo audio = {.micCapInfo = mic, .innerCapInfo = inner, .audioEncInfo = audioEnc};
    OH_VideoCaptureInfo videoCapture = {
        .videoFrameWidth = VIDEO_WIDTH,
        .videoFrameHeight = VIDEO_HEIGHT,
        .videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA,
    };
    OH_VideoEncInfo videoEnc = {
        .videoCodec = OH_VideoCodecFormat::OH_H264,
        .videoBitrate = VIDEO_BITRATE,
        .videoFrameRate = VIDEO_FPS,
    };
    OH_VideoInfo video = {.videoCapInfo = videoCapture, .videoEncInfo = videoEnc};
    config = {
        .captureMode = OH_CAPTURE_HOME_SCREEN,
        .dataType = OH_ORIGINAL_STREAM,
        .audioInfo = audio,
        .videoInfo = video,
    };
}

int ConfigureEncoder()
{
    OH_AVCapability *capability = OH_AVCodec_GetCapability(OH_AVCODEC_MIMETYPE_VIDEO_AVC, true);
    if (capability == nullptr) {
        return -10;
    }
    const char *name = OH_AVCapability_GetName(capability);
    videoEncoder = OH_VideoEncoder_CreateByName(name);
    if (videoEncoder == nullptr) {
        return -11;
    }
    OH_AVCodecCallback callback = {
        EncoderCallback::OnError,
        EncoderCallback::OnStreamChanged,
        EncoderCallback::OnNeedInputBuffer,
        EncoderCallback::OnNewOutputBuffer,
    };
    int result = OH_VideoEncoder_RegisterCallback(videoEncoder, callback, &encoderContext);
    if (result != AV_ERR_OK) {
        return result;
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, VIDEO_WIDTH);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, VIDEO_HEIGHT);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, VIDEO_FPS);
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, VIDEO_BITRATE);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, 2000);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, static_cast<int32_t>(OH_AVCProfile::AVC_PROFILE_BASELINE));
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE,
                            static_cast<int32_t>(OH_VideoEncodeBitrateMode::CBR));
    result = OH_VideoEncoder_Configure(videoEncoder, format);
    OH_AVFormat_Destroy(format);
    if (result != AV_ERR_OK) {
        return result;
    }
    result = OH_VideoEncoder_GetSurface(videoEncoder, &encoderSurface);
    if (result != AV_ERR_OK) {
        return result;
    }
    result = OH_VideoEncoder_Prepare(videoEncoder);
    if (result != AV_ERR_OK) {
        return result;
    }
    result = OH_VideoEncoder_Start(videoEncoder);
    return result;
}

void EncoderOutputLoop()
{
    while (captureRunning.load()) {
        EncodedBuffer item;
        {
            std::unique_lock<std::mutex> lock(encoderContext.mutex);
            encoderContext.condition.wait_for(lock, std::chrono::milliseconds(500), [] {
                return !captureRunning.load() || !encoderContext.output.empty();
            });
            if (encoderContext.output.empty()) {
                continue;
            }
            item = encoderContext.output.front();
            encoderContext.output.pop();
        }
        uint8_t *address = OH_AVBuffer_GetAddr(item.buffer);
        if (address != nullptr && item.attr.size > 0) {
            auto *payload = address + item.attr.offset;
            if ((item.attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0) {
                std::lock_guard<std::mutex> lock(codecConfigMutex);
                codecConfig.assign(payload, payload + item.attr.size);
            }
            int64_t pts = (item.attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0
                              ? 0
                              : static_cast<int64_t>(encodedFrameCount.fetch_add(1) * 1'000'000 / VIDEO_FPS);
            SendPacket(VIDEO, static_cast<uint16_t>(item.attr.flags), pts, payload,
                       static_cast<uint32_t>(item.attr.size));
        }
        OH_VideoEncoder_FreeOutputBuffer(videoEncoder, item.index);
        if ((item.attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
            break;
        }
    }
}

int StartCapture()
{
    if (captureRunning.load()) {
        return 0;
    }
    {
        std::lock_guard<std::mutex> lock(codecConfigMutex);
        codecConfig.clear();
    }
    encodedFrameCount.store(0);
    screenCapture = OH_AVScreenCapture_Create();
    if (screenCapture == nullptr) {
        return -20;
    }
    OH_AVScreenCaptureConfig config{};
    ConfigureCapture(config);
    OH_AVScreenCapture_SetMicrophoneEnabled(screenCapture, false);
    OH_AVScreenCapture_SetErrorCallback(screenCapture, OnCaptureError, nullptr);
    OH_AVScreenCapture_SetStateCallback(screenCapture, OnCaptureState, nullptr);
    OH_AVScreenCapture_SetDataCallback(screenCapture, OnCaptureData, nullptr);
    OH_AVScreenCapture_SetDisplayCallback(screenCapture, OnDisplaySelected, nullptr);
    int result = OH_AVScreenCapture_Init(screenCapture, config);
    if (result != AV_SCREEN_CAPTURE_ERR_OK) {
        return result;
    }
    result = ConfigureEncoder();
    if (result != AV_ERR_OK) {
        return result;
    }
    captureRunning.store(true);
    encoderThread = std::thread(EncoderOutputLoop);
    result = OH_AVScreenCapture_StartScreenCaptureWithSurface(screenCapture, encoderSurface);
    if (result != AV_SCREEN_CAPTURE_ERR_OK) {
        captureRunning.store(false);
        encoderContext.condition.notify_all();
        if (encoderThread.joinable()) {
            encoderThread.join();
        }
        return result;
    }
    return 0;
}

void StopCapture()
{
    if (!captureRunning.exchange(false)) {
        return;
    }
    if (screenCapture != nullptr) {
        OH_AVScreenCapture_StopScreenCapture(screenCapture);
    }
    encoderContext.condition.notify_all();
    if (encoderThread.joinable()) {
        encoderThread.join();
    }
    if (videoEncoder != nullptr) {
        OH_VideoEncoder_Stop(videoEncoder);
        OH_VideoEncoder_Destroy(videoEncoder);
        videoEncoder = nullptr;
    }
    if (screenCapture != nullptr) {
        OH_AVScreenCapture_Release(screenCapture);
        screenCapture = nullptr;
    }
}

std::string GetLocalIpAddress()
{
    ifaddrs *addresses = nullptr;
    if (getifaddrs(&addresses) != 0) {
        return "0.0.0.0";
    }
    std::string result = "0.0.0.0";
    for (ifaddrs *item = addresses; item != nullptr; item = item->ifa_next) {
        if (item->ifa_addr == nullptr || item->ifa_addr->sa_family != AF_INET ||
            (item->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        char buffer[INET_ADDRSTRLEN] = {};
        auto *address = reinterpret_cast<sockaddr_in *>(item->ifa_addr);
        if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer)) != nullptr) {
            result = buffer;
            if (std::string(item->ifa_name) == "wlan0") {
                break;
            }
        }
    }
    freeifaddrs(addresses);
    return result;
}

std::string ReadNapiString(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1);
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

napi_value NapiStartServer(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t port = DEFAULT_PORT;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &port);
    }
    int result = StartTcpServer(static_cast<uint16_t>(port));
    napi_value value;
    napi_create_int32(env, result, &value);
    return value;
}

napi_value NapiStopServer(napi_env env, napi_callback_info)
{
    StopCapture();
    StopTcpServer();
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

napi_value NapiStartCapture(napi_env env, napi_callback_info)
{
    int result = StartCapture();
    napi_value value;
    napi_create_int32(env, result, &value);
    return value;
}

napi_value NapiStopCapture(napi_env env, napi_callback_info)
{
    StopCapture();
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

napi_value NapiGetStatus(napi_env env, napi_callback_info)
{
    napi_value object;
    napi_create_object(env, &object);
    napi_value connected;
    napi_get_boolean(env, clientFd >= 0, &connected);
    napi_set_named_property(env, object, "connected", connected);
    napi_value capturing;
    napi_get_boolean(env, captureRunning.load(), &capturing);
    napi_set_named_property(env, object, "capturing", capturing);
    std::string ip = GetLocalIpAddress();
    napi_value ipValue;
    napi_create_string_utf8(env, ip.c_str(), ip.size(), &ipValue);
    napi_set_named_property(env, object, "ip", ipValue);
    return object;
}

napi_value NapiPollControl(napi_env env, napi_callback_info)
{
    std::string value;
    {
        std::lock_guard<std::mutex> lock(controlMutex);
        if (!controlQueue.empty()) {
            value = std::move(controlQueue.front());
            controlQueue.pop();
        }
    }
    napi_value result;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value NapiListInbox(napi_env env, napi_callback_info)
{
    napi_value array;
    napi_create_array(env, &array);
    DIR *directory = opendir(INBOX_PATH);
    if (directory == nullptr) {
        return array;
    }
    uint32_t index = 0;
    dirent *entry;
    while ((entry = readdir(directory)) != nullptr) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        napi_value name;
        napi_create_string_utf8(env, entry->d_name, NAPI_AUTO_LENGTH, &name);
        napi_set_element(env, array, index++, name);
    }
    closedir(directory);
    return array;
}

napi_value NapiSendFile(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t originalFd = -1;
    napi_get_value_int32(env, args[0], &originalFd);
    std::string name = SanitizeFileName(ReadNapiString(env, args[1]));
    int fd = dup(originalFd);
    std::thread([fd, name] {
        if (fd < 0) {
            return;
        }
        SendPacket(FILE_TO_MAC_BEGIN, 0, 0, reinterpret_cast<const uint8_t *>(name.data()), name.size());
        std::vector<uint8_t> buffer(256 * 1024);
        ssize_t count;
        while ((count = read(fd, buffer.data(), buffer.size())) > 0) {
            if (!SendPacket(FILE_TO_MAC_CHUNK, 0, 0, buffer.data(), static_cast<uint32_t>(count))) {
                break;
            }
        }
        close(fd);
        SendPacket(FILE_TO_MAC_END, 0, 0, nullptr, 0);
    }).detach();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"startServer", nullptr, NapiStartServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopServer", nullptr, NapiStopServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCapture", nullptr, NapiStartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture", nullptr, NapiStopCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, NapiGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollControl", nullptr, NapiPollControl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"listInbox", nullptr, NapiListInbox, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendFile", nullptr, NapiSendFile, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterPhoneMirrorModule() { napi_module_register(&module); }
