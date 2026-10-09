// libmpv owns decoding, audio/video clocks, seeking, buffering and rendering.
// This native session dispatches controls, observes the core and closes its
// resources away from the ArkTS thread.
#include "mpv_session.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <utility>

namespace bilimpv {
namespace {

void CheckMpv(int result)
{
    if (result < 0) {
        // Never include mpv/FFmpeg diagnostic strings: these can contain URLs.
        throw std::runtime_error("播放器内核操作失败 (" + std::to_string(result) + ")");
    }
}

void PushEvent(Session &s, Event event)
{
    std::lock_guard<std::mutex> lock(s.stateMutex);
    if (s.events.size() >= 256) {
        s.events.clear();
        s.events.push_back({"error", -1, s.state.position, MPV_ERROR_EVENT_QUEUE_FULL});
    }
    event.position = s.state.position;
    s.events.push_back(std::move(event));
}

void ProcessProperty(Session &s, const mpv_event_property &property)
{
    if (!property.name) return;
    std::lock_guard<std::mutex> lock(s.stateMutex);
    const std::string name(property.name);
    std::string *color = nullptr;
    if (name == "video-params/primaries") color = &s.state.sourcePrimaries;
    else if (name == "video-params/gamma") color = &s.state.sourceTransfer;
    else if (name == "video-params/pixelformat") color = &s.state.sourceFormat;
    else if (name == "video-target-params/primaries") color = &s.state.targetPrimaries;
    else if (name == "video-target-params/gamma") color = &s.state.targetTransfer;
    else if (name == "current-vo") color = &s.state.vo;
    if (color) {
        const char *value = property.data && property.format == MPV_FORMAT_STRING ?
            *static_cast<char **>(property.data) : nullptr;
        *color = value && value[0] ? value : "unknown";
        return;
    }
    if (name == "audio-pts" &&
        (!property.data || property.format == MPV_FORMAT_NONE)) {
        s.state.audioPts = -1;
        return;
    }
    if (!property.data || property.format == MPV_FORMAT_NONE) return;
    if (property.format == MPV_FORMAT_DOUBLE) {
        const double value = *static_cast<double *>(property.data);
        if (!std::isfinite(value)) return;
        if (name == "time-pos") s.state.position = std::max(0.0, value);
        else if (name == "audio-pts") s.state.audioPts = value;
        else if (name == "duration") s.state.duration = std::max(0.0, value);
        else if (name == "speed") s.state.speed = value;
        else if (name == "volume") s.state.volume = value / 100.0;
        else if (name == "avsync") s.state.avSync = value;
    } else if (property.format == MPV_FORMAT_FLAG) {
        const bool value = *static_cast<int *>(property.data) != 0;
        if (name == "pause") s.state.paused = value;
        else if (name == "paused-for-cache") s.state.buffering = value;
        else if (name == "eof-reached") s.state.eof = value;
    } else if (property.format == MPV_FORMAT_INT64) {
        const int64_t value = std::max<int64_t>(0, *static_cast<int64_t *>(property.data));
        if (name == "video-params/w") s.state.width = value;
        else if (name == "video-params/h") s.state.height = value;
        else if (name == "frame-drop-count") s.state.droppedFrames = value;
        else if (name == "decoder-frame-drop-count") s.state.decoderDroppedFrames = value;
    } else if (property.format == MPV_FORMAT_STRING && name == "hwdec-current") {
        const char *value = *static_cast<char **>(property.data);
        s.state.hwdec = value ? value : "";
    }
}

const mpv_node *MapValue(const mpv_node &node, const char *key)
{
    if (node.format != MPV_FORMAT_NODE_MAP || !node.u.list || !node.u.list->keys || !node.u.list->values) return nullptr;
    for (int i = 0; i < node.u.list->num; ++i) {
        if (node.u.list->keys[i] && std::strcmp(node.u.list->keys[i], key) == 0) return &node.u.list->values[i];
    }
    return nullptr;
}

struct SelectedTracks {
    bool video = false;
    bool externalAudio = false;
};

SelectedTracks GetSelectedTracks(mpv_handle *handle)
{
    mpv_node tracks{};
    SelectedTracks selected;
    if (mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &tracks) < 0) return selected;
    if (tracks.format == MPV_FORMAT_NODE_ARRAY && tracks.u.list && tracks.u.list->values) {
        for (int i = 0; i < tracks.u.list->num; ++i) {
            const mpv_node &track = tracks.u.list->values[i];
            const mpv_node *type = MapValue(track, "type");
            const mpv_node *external = MapValue(track, "external");
            const mpv_node *active = MapValue(track, "selected");
            if (!type || type->format != MPV_FORMAT_STRING || !type->u.string ||
                !active || active->format != MPV_FORMAT_FLAG || !active->u.flag) continue;
            if (std::strcmp(type->u.string, "video") == 0) selected.video = true;
            if (std::strcmp(type->u.string, "audio") == 0 &&
                external && external->format == MPV_FORMAT_FLAG && external->u.flag) selected.externalAudio = true;
        }
    }
    mpv_free_node_contents(&tracks);
    return selected;
}

bool HasGpuVideoOutput(mpv_handle *handle)
{
    char *output = nullptr;
    const int result = mpv_get_property(handle, "current-vo", MPV_FORMAT_STRING, &output);
    const bool ready = result >= 0 && output && std::strcmp(output, "gpu") == 0;
    mpv_free(output);
    return ready;
}

void ProcessEvent(Session &s, const mpv_event &event)
{
    switch (event.event_id) {
    case MPV_EVENT_PROPERTY_CHANGE:
        if (event.data) ProcessProperty(s, *static_cast<mpv_event_property *>(event.data));
        break;
    case MPV_EVENT_START_FILE: {
        {
            std::lock_guard<std::mutex> lock(s.stateMutex);
            s.state.position = 0;
            s.state.audioPts = -1;
            s.state.sourcePrimaries = "unknown";
            s.state.sourceTransfer = "unknown";
            s.state.sourceFormat = "unknown";
            s.state.targetPrimaries = "unknown";
            s.state.targetTransfer = "unknown";
            s.state.vo = "unknown";
            s.state.loaded = false;
            s.state.eof = false;
            s.state.buffering = false;
        }
        PushEvent(s, {"start-file"});
        break;
    }
    case MPV_EVENT_FILE_LOADED: {
        // mpv can finish loading the main video after rejecting an external
        // audio URL. Preparing such a source would silently produce no sound.
        // Query on this native event thread, never on the ArkTS/UI thread, and
        // require the external audio to be selected before signalling ready.
        const SelectedTracks tracks = GetSelectedTracks(s.handle);
        if (s.requiresExternalAudio.load() && !tracks.externalAudio) {
            {
                std::lock_guard<std::mutex> lock(s.stateMutex);
                s.state.loaded = false;
                s.state.buffering = false;
            }
            PushEvent(s, {"audio-error", -1, 0, MPV_ERROR_LOADING_FAILED});
            break;
        }
        // FILE_LOADED also occurs when VO initialization failed but audio can
        // continue. The core initializes the VO before this event, unlike
        // video-out-params which requires a decoded frame. Reject audio-only
        // readiness rather than hiding a failed EGL surface behind playback.
        if (!tracks.video || !HasGpuVideoOutput(s.handle)) {
            {
                std::lock_guard<std::mutex> lock(s.stateMutex);
                s.state.loaded = false;
                s.state.buffering = false;
            }
            PushEvent(s, {"error", -1, 0, MPV_ERROR_VO_INIT_FAILED});
            break;
        }
        {
            std::lock_guard<std::mutex> lock(s.stateMutex);
            s.state.loaded = true;
        }
        PushEvent(s, {"file-loaded"});
        break;
    }
    case MPV_EVENT_SEEK:
        // A queued initial restart is not completion of a newly submitted seek.
        // cmd_seek replies after queuing; the playback loop emits SEEK when it
        // actually executes that seek. Require this ordered acknowledgement.
        if (s.activeSeek >= 0 && s.activeSeekAccepted) s.activeSeekStarted = true;
        PushEvent(s, {"seek", s.activeSeekStarted ? s.activeSeek : -1});
        break;
    case MPV_EVENT_PLAYBACK_RESTART:
        if (s.activeSeekStarted) {
            // PROPERTY_CHANGE delivery can be coalesced behind this event.
            // Read the actual landing position on the native event thread so
            // seek completion cannot expose a pre-seek cached position.
            double position = -1;
            if (mpv_get_property(s.handle, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 &&
                std::isfinite(position) && position >= 0) {
                std::lock_guard<std::mutex> lock(s.stateMutex);
                s.state.position = position;
            }
        }
        PushEvent(s, {"playback-restart", s.activeSeekStarted ? s.activeSeek : -1});
        if (s.activeSeekStarted) {
            s.activeSeek = -1;
            s.activeSeekAccepted = false;
            s.activeSeekStarted = false;
        }
        break;
    case MPV_EVENT_END_FILE: {
        const auto *end = static_cast<mpv_event_end_file *>(event.data);
        if (!end) break;
        {
            std::lock_guard<std::mutex> lock(s.stateMutex);
            s.state.loaded = false;
            s.state.buffering = false;
            s.state.eof = end->reason == MPV_END_FILE_REASON_EOF;
        }
        if (end->reason == MPV_END_FILE_REASON_ERROR) PushEvent(s, {"error", -1, 0, end->error});
        else if (end->reason == MPV_END_FILE_REASON_EOF) PushEvent(s, {"end-file"});
        else if (end->reason == MPV_END_FILE_REASON_STOP && !s.closing.load()) {
            // Each session opens one source and exposes no stop command. The
            // OHOS output stops after bounded, unrecoverable surface failures;
            // report that failure instead of leaving the UI looking paused.
            PushEvent(s, {"error", -1, 0, MPV_ERROR_VO_INIT_FAILED});
        }
        // stop/quit caused by release have no user-facing failure/completion.
        s.activeSeek = -1;
        s.activeSeekAccepted = false;
        s.activeSeekStarted = false;
        break;
    }
    case MPV_EVENT_COMMAND_REPLY:
    case MPV_EVENT_SET_PROPERTY_REPLY: {
        auto reply = s.replies.find(event.reply_userdata);
        if (reply == s.replies.end()) break;
        const Reply value = reply->second;
        s.replies.erase(reply);
        if (event.error < 0) {
            if (value.kind == ControlKind::Seek && s.activeSeek == value.request) {
                s.activeSeek = -1;
                s.activeSeekAccepted = false;
                s.activeSeekStarted = false;
            }
            PushEvent(s, {"error", value.request, 0, event.error});
        } else if (value.kind == ControlKind::Seek && s.activeSeek == value.request) {
            s.activeSeekAccepted = true;
        } else if (value.kind == ControlKind::Pause) {
            bool loaded;
            {
                std::lock_guard<std::mutex> lock(s.stateMutex);
                loaded = s.state.loaded;
            }
            // Preserve acknowledgements even when mpv coalesces pause's observed
            // value for pause -> play in one poll interval.
            if (loaded) PushEvent(s, {value.value != 0 ? "paused" : "playing", value.value});
        }
        break;
    }
    case MPV_EVENT_QUEUE_OVERFLOW:
        PushEvent(s, {"error", -1, 0, MPV_ERROR_EVENT_QUEUE_FULL});
        break;
    case MPV_EVENT_SHUTDOWN:
        if (!s.closing.load()) PushEvent(s, {"error", -1, 0, MPV_ERROR_UNINITIALIZED});
        break;
    default:
        break;
    }
}

void ProcessControl(Session &s, const Control &control)
{
    const uint64_t cookie = s.nextReply++;
    s.replies.emplace(cookie, Reply{control.kind, control.request, control.value});
    int result = 0;
    switch (control.kind) {
    case ControlKind::Pause: {
        int paused = control.value != 0;
        result = mpv_set_property_async(s.handle, cookie, "pause", MPV_FORMAT_FLAG, &paused);
        break;
    }
    case ControlKind::Seek: {
        const std::string seconds = std::to_string(control.value);
        const char *args[] = {"seek", seconds.c_str(), control.precise ? "absolute+exact" : "absolute+keyframes", nullptr};
        // SEEK/PLAYBACK_RESTART, rather than command acceptance, complete a seek.
        s.activeSeek = control.request;
        s.activeSeekAccepted = false;
        s.activeSeekStarted = false;
        result = mpv_command_async(s.handle, cookie, args);
        break;
    }
    case ControlKind::Rate: {
        double rate = control.value;
        result = mpv_set_property_async(s.handle, cookie, "speed", MPV_FORMAT_DOUBLE, &rate);
        break;
    }
    case ControlKind::Volume: {
        double volume = control.value * 100.0;
        result = mpv_set_property_async(s.handle, cookie, "volume", MPV_FORMAT_DOUBLE, &volume);
        break;
    }
    case ControlKind::Resize: {
        const std::string size = std::to_string(control.width) + "x" + std::to_string(control.height);
        char *value = const_cast<char *>(size.c_str());
        // The OHOS fork routes this option to VOCTRL_EXTERNAL_RESIZE. No media
        // reload, audio clock reset or corrective seek is required.
        result = mpv_set_property_async(s.handle, cookie, "ohos-surface-size", MPV_FORMAT_STRING, &value);
        break;
    }
    }
    if (result < 0) {
        s.replies.erase(cookie);
        if (control.kind == ControlKind::Seek) {
            s.activeSeek = -1;
            s.activeSeekAccepted = false;
            s.activeSeekStarted = false;
        }
        PushEvent(s, {"error", control.request, 0, result});
    }
}

void EventLoop(const std::shared_ptr<Session> &session)
{
    Session &s = *session;
    while (!s.closing.load()) {
        // Retire queued events before assigning a new seek's ownership.
        mpv_event *previous = mpv_wait_event(s.handle, 0);
        for (size_t i = 0; previous && previous->event_id != MPV_EVENT_NONE && i < 512; ++i) {
            ProcessEvent(s, *previous);
            previous = mpv_wait_event(s.handle, 0);
        }
        std::deque<Control> controls;
        {
            std::lock_guard<std::mutex> lock(s.queueMutex);
            controls.swap(s.controls);
        }
        for (const auto &control : controls) {
            if (s.closing.load()) break;
            ProcessControl(s, control);
        }
        // The wait runs solely on this native event thread. UI calls only read
        // the cached snapshot or enqueue controls, never call into the core.
        mpv_event *event = mpv_wait_event(s.handle, 0.015);
        for (size_t i = 0; event && event->event_id != MPV_EVENT_NONE && i < 512; ++i) {
            ProcessEvent(s, *event);
            event = mpv_wait_event(s.handle, 0);
        }
    }
}

void SetOption(mpv_handle *handle, const char *name, const char *value)
{
    CheckMpv(mpv_set_option_string(handle, name, value));
}

void SetList(mpv_handle *handle, const char *name, const std::vector<std::string> &values)
{
    std::vector<mpv_node> nodes(values.size());
    for (size_t i = 0; i < values.size(); ++i) {
        nodes[i].format = MPV_FORMAT_STRING;
        nodes[i].u.string = const_cast<char *>(values[i].c_str());
    }
    mpv_node_list list{};
    list.num = static_cast<int>(nodes.size());
    list.values = nodes.data();
    mpv_node node{};
    node.format = MPV_FORMAT_NODE_ARRAY;
    node.u.list = &list;
    // Typed arrays preserve URLs/header values containing commas or colons.
    CheckMpv(mpv_set_property(handle, name, MPV_FORMAT_NODE, &node));
}

std::string Lower(std::string value)
{
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}

} // namespace

void CloseNative(const std::shared_ptr<Session> &session)
{
    session->closing.store(true);
    std::call_once(session->closeOnce, [&]() {
        std::lock_guard<std::mutex> lock(session->openMutex);
        if (session->eventThread.joinable()) session->eventThread.join();
        if (session->handle) {
            mpv_terminate_destroy(session->handle);
            session->handle = nullptr;
        }
    });
}

std::shared_ptr<Session> BuildSession(uint64_t surface, const std::string &caFile)
{
    auto session = std::make_shared<Session>();
    session->handle = mpv_create();
    if (!session->handle) throw std::runtime_error("播放器内核初始化失败");
    try {
        auto *handle = session->handle;
        int64_t wid;
        static_assert(sizeof(wid) == sizeof(surface));
        std::memcpy(&wid, &surface, sizeof(wid));
        CheckMpv(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid));
        SetOption(handle, "config", "no");
        SetOption(handle, "load-scripts", "no");
        SetOption(handle, "ytdl", "no");
        SetOption(handle, "terminal", "no");
        SetOption(handle, "msg-level", "all=no");
        SetOption(handle, "input-default-bindings", "no");
        SetOption(handle, "vo", "gpu");
        SetOption(handle, "gpu-context", "ohos");
        SetOption(handle, "gpu-api", "opengl");
        // The OHOS context negotiates matching EGL/NativeWindow formats:
        // 10-bit for capable HDR displays, otherwise explicit RGBA8888 SDR.
        // Keep this context for its lifetime, including hold-rate changes.
        SetOption(handle, "opengl-es", "yes");
        SetOption(handle, "egl-output-format", "auto");
        SetOption(handle, "ao", "ohaudio");
        // Keep pitch correction resident at 1x. mpv's automatic speed filter
        // otherwise drains and rebuilds the audio chain on each hold/release.
        SetOption(handle, "af", "scaletempo2");
        // ohcodec is in this fork's auto-safe whitelist. If unavailable or
        // decoding fails, libmpv's decoder fallback handles software decoding.
        SetOption(handle, "hwdec", "auto-safe");
        SetOption(handle, "video-sync", "audio");
        SetOption(handle, "pause", "yes");
        SetOption(handle, "idle", "yes");
        // Keep the selected source at EOF so replay is a native seek, rather
        // than a second network reload. eof-reached still marks completion.
        SetOption(handle, "keep-open", "yes");
        SetOption(handle, "cache", "yes");
        SetOption(handle, "demuxer-readahead-secs", "12");
        SetOption(handle, "demuxer-max-bytes", "64MiB");
        SetOption(handle, "network-timeout", "20");
        SetOption(handle, "tls-verify", "yes");
        if (!caFile.empty()) CheckMpv(mpv_set_option_string(handle, "tls-ca-file", caFile.c_str()));
        CheckMpv(mpv_initialize(handle));
        const std::pair<const char *, mpv_format> properties[] = {
            {"time-pos", MPV_FORMAT_DOUBLE}, {"duration", MPV_FORMAT_DOUBLE},
            {"audio-pts", MPV_FORMAT_DOUBLE},
            {"video-params/w", MPV_FORMAT_INT64}, {"video-params/h", MPV_FORMAT_INT64},
            {"pause", MPV_FORMAT_FLAG}, {"paused-for-cache", MPV_FORMAT_FLAG},
            {"eof-reached", MPV_FORMAT_FLAG}, {"speed", MPV_FORMAT_DOUBLE},
            {"volume", MPV_FORMAT_DOUBLE}, {"hwdec-current", MPV_FORMAT_STRING},
            {"video-params/primaries", MPV_FORMAT_STRING}, {"video-params/gamma", MPV_FORMAT_STRING},
            {"video-params/pixelformat", MPV_FORMAT_STRING}, {"video-target-params/primaries", MPV_FORMAT_STRING},
            {"video-target-params/gamma", MPV_FORMAT_STRING}, {"current-vo", MPV_FORMAT_STRING},
            {"avsync", MPV_FORMAT_DOUBLE}, {"frame-drop-count", MPV_FORMAT_INT64},
            {"decoder-frame-drop-count", MPV_FORMAT_INT64},
        };
        uint64_t cookie = 1;
        for (const auto &property : properties) CheckMpv(mpv_observe_property(handle, cookie++, property.first, property.second));
        session->eventThread = std::thread(EventLoop, session);
        return session;
    } catch (...) {
        CloseNative(session);
        throw;
    }
}

void OpenNative(const std::shared_ptr<Session> &session, const std::string &video,
                const std::string &audio, const std::vector<std::string> &headers)
{
    std::lock_guard<std::mutex> lock(session->openMutex);
    if (session->closing.load() || session->opened) throw std::runtime_error("播放器播放源已失效");
    std::vector<std::string> fields;
    for (const auto &header : headers) {
        const size_t colon = header.find(':');
        if (colon == std::string::npos || colon == 0) throw std::runtime_error("播放请求头无效");
        const std::string name = Lower(header.substr(0, colon));
        if (name == "user-agent") {
            const size_t start = header.find_first_not_of(" \t", colon + 1);
            const std::string agent = start == std::string::npos ? "" : header.substr(start);
            char *value = const_cast<char *>(agent.c_str());
            CheckMpv(mpv_set_property(session->handle, "user-agent", MPV_FORMAT_STRING, &value));
        } else {
            fields.push_back(header);
        }
    }
    SetList(session->handle, "http-header-fields", fields);
    SetList(session->handle, "audio-files", audio.empty() ? std::vector<std::string>{} : std::vector<std::string>{audio});
    session->requiresExternalAudio.store(!audio.empty());
    const char *command[] = {"loadfile", video.c_str(), "replace", "-1", nullptr};
    CheckMpv(mpv_command(session->handle, command));
    session->opened = true;
}

bool EnqueueControl(const std::shared_ptr<Session> &session, const Control &control)
{
    std::lock_guard<std::mutex> lock(session->queueMutex);
    if (session->closing.load() || session->controls.size() >= 128) return false;
    session->controls.push_back(control);
    return true;
}

PolledState TakeSnapshot(const std::shared_ptr<Session> &session)
{
    PolledState result;
    std::lock_guard<std::mutex> lock(session->stateMutex);
    result.state = session->state;
    result.events.swap(session->events);
    return result;
}

} // namespace bilimpv
