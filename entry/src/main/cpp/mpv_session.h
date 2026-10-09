// Native libmpv session state and ownership. This layer has no N-API values
// or callbacks; its media positions are observed from the playback core.
#pragma once
#include <mpv/client.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace bilimpv {

struct Event {
    std::string kind;
    double request = -1;
    double position = 0;
    int errorCode = 0;
};

struct Snapshot {
    double position = 0;
    double audioPts = -1;
    double duration = 0;
    int64_t width = 0;
    int64_t height = 0;
    bool paused = true;
    bool buffering = false;
    bool eof = false;
    bool loaded = false;
    double speed = 1;
    double volume = 1;
    std::string hwdec;
    std::string sourcePrimaries = "unknown";
    std::string sourceTransfer = "unknown";
    std::string sourceFormat = "unknown";
    std::string targetPrimaries = "unknown";
    std::string targetTransfer = "unknown";
    std::string vo = "unknown";
    double avSync = 0;
    int64_t droppedFrames = 0;
    int64_t decoderDroppedFrames = 0;
};

enum class ControlKind { Pause, Seek, Rate, Volume, Resize };

struct Control {
    ControlKind kind = ControlKind::Pause;
    double value = 0;
    double request = -1;
    bool precise = true;
    int64_t width = 0;
    int64_t height = 0;
};

struct Reply {
    ControlKind kind;
    double request;
    double value;
};

struct Session {
    mpv_handle *handle = nullptr;
    std::atomic<bool> closing{false};
    std::once_flag closeOnce;
    std::mutex openMutex;
    bool opened = false;
    std::atomic<bool> requiresExternalAudio{false};
    std::mutex queueMutex;
    std::deque<Control> controls;
    std::mutex stateMutex;
    Snapshot state;
    std::deque<Event> events;
    std::thread eventThread;
    // Owned by eventThread only. No application playback clock is maintained.
    uint64_t nextReply = 1;
    std::unordered_map<uint64_t, Reply> replies;
    double activeSeek = -1;
    bool activeSeekAccepted = false;
    bool activeSeekStarted = false;
};

struct PolledState {
    Snapshot state;
    std::deque<Event> events;
};

std::shared_ptr<Session> BuildSession(uint64_t surface, const std::string &caFile);
void OpenNative(const std::shared_ptr<Session> &session, const std::string &video,
                const std::string &audio, const std::vector<std::string> &headers);
void CloseNative(const std::shared_ptr<Session> &session);
bool EnqueueControl(const std::shared_ptr<Session> &session, const Control &control);
PolledState TakeSnapshot(const std::shared_ptr<Session> &session);

} // namespace bilimpv
