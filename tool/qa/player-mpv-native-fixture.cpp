// Compile both real production translation units against host boundary mocks.
// Native media decoding and OHOS N-API execution are not simulated acceptance;
// these tests exercise bridge ownership, event ordering and exact API payloads.
#include "mpv_session.cpp"
#include "bilimpv.cpp"
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <iostream>

using namespace bilimpv;

struct FakeValue {
    std::string text;
    double number = 0;
    bool boolean = false;
    bool array = false;
    int settled = 0; // 0 pending, 1 resolved, 2 rejected
    std::vector<napi_value> elements;
    std::unordered_map<std::string, napi_value> properties;
};
struct FakeAsync {
    napi_async_execute_callback execute;
    napi_async_complete_callback complete;
    void *data;
};
struct FakeTsfn {
    napi_env env;
    void *finalizeData;
    napi_finalize finalize;
    void *context;
    napi_threadsafe_function_call_js callJs;
    std::mutex mutex;
    bool pending = false;
    bool released = false;
    bool aborted = false;
};
struct FakeEnv {
    bool failAsyncCreate = false;
    bool failAsyncQueue = false;
    bool failTsfn = false;
    std::vector<std::unique_ptr<FakeValue>> values;
    std::mutex mutex;
    std::vector<FakeTsfn *> completions;
    std::vector<FakeAsync *> work;
};
struct FakeArgs { std::vector<napi_value> values; };

FakeValue *Value(FakeEnv *env)
{
    env->values.push_back(std::make_unique<FakeValue>());
    return env->values.back().get();
}
napi_status napi_create_promise(napi_env e, napi_deferred *d, napi_value *p) { *d = *p = Value(e); return napi_ok; }
napi_status napi_create_string_utf8(napi_env e, const char *s, size_t n, napi_value *v)
{ *v = Value(e); (*v)->text.assign(s, n == NAPI_AUTO_LENGTH ? std::strlen(s) : n); return napi_ok; }
napi_status napi_create_error(napi_env, napi_value, napi_value message, napi_value *value) { *value = message; return napi_ok; }
napi_status napi_get_undefined(napi_env e, napi_value *v) { *v = Value(e); return napi_ok; }
napi_status napi_create_uint32(napi_env e, uint32_t n, napi_value *v) { *v = Value(e); (*v)->number = n; return napi_ok; }
napi_status napi_create_double(napi_env e, double n, napi_value *v) { *v = Value(e); (*v)->number = n; return napi_ok; }
napi_status napi_get_boolean(napi_env e, bool b, napi_value *v) { *v = Value(e); (*v)->boolean = b; return napi_ok; }
napi_status napi_create_object(napi_env e, napi_value *v) { *v = Value(e); return napi_ok; }
napi_status napi_create_array_with_length(napi_env e, size_t n, napi_value *v)
{ *v = Value(e); (*v)->array = true; (*v)->elements.resize(n); return napi_ok; }
napi_status napi_set_named_property(napi_env, napi_value v, const char *name, napi_value child)
{ v->properties[name] = child; return napi_ok; }
napi_status napi_set_element(napi_env, napi_value v, uint32_t n, napi_value child)
{ if (n >= v->elements.size()) v->elements.resize(n + 1); v->elements[n] = child; return napi_ok; }
napi_status napi_get_element(napi_env, napi_value v, uint32_t n, napi_value *child)
{ if (n >= v->elements.size()) return napi_invalid_arg; *child = v->elements[n]; return napi_ok; }
napi_status napi_get_array_length(napi_env, napi_value v, uint32_t *n) { *n = static_cast<uint32_t>(v->elements.size()); return napi_ok; }
napi_status napi_is_array(napi_env, napi_value v, bool *b) { *b = v->array; return napi_ok; }
napi_status napi_get_value_string_utf8(napi_env, napi_value v, char *out, size_t size, size_t *length)
{
    *length = v->text.size();
    if (out && size) { const size_t n = std::min(size - 1, v->text.size()); std::memcpy(out, v->text.data(), n); out[n] = 0; *length = n; }
    return napi_ok;
}
napi_status napi_get_value_double(napi_env, napi_value v, double *n) { *n = v->number; return napi_ok; }
napi_status napi_get_value_bool(napi_env, napi_value v, bool *b) { *b = v->boolean; return napi_ok; }
napi_status napi_get_cb_info(napi_env, napi_callback_info info, size_t *n, napi_value *values, napi_value *, void **)
{
    const auto &args = static_cast<FakeArgs *>(info)->values;
    const size_t available = std::min(*n, args.size());
    for (size_t i = 0; i < available; ++i) values[i] = args[i];
    *n = available; return napi_ok;
}
napi_status napi_throw_type_error(napi_env, const char *, const char *) { return napi_ok; }
napi_status napi_define_properties(napi_env, napi_value, size_t, const napi_property_descriptor *) { return napi_ok; }
napi_status napi_add_env_cleanup_hook(napi_env, void (*)(void *), void *) { return napi_ok; }
void napi_module_register(napi_module *) {}
napi_status napi_resolve_deferred(napi_env, napi_deferred d, napi_value) { assert(d->settled == 0); d->settled = 1; return napi_ok; }
napi_status napi_reject_deferred(napi_env, napi_deferred d, napi_value) { assert(d->settled == 0); d->settled = 2; return napi_ok; }
napi_status napi_create_async_work(napi_env e, napi_value, napi_value, napi_async_execute_callback x,
    napi_async_complete_callback c, void *data, napi_async_work *out)
{ if (e->failAsyncCreate) return napi_generic_failure; *out = new FakeAsync{x, c, data}; return napi_ok; }
napi_status napi_queue_async_work(napi_env e, napi_async_work work)
{ if (e->failAsyncQueue) return napi_generic_failure; e->work.push_back(work); return napi_ok; }
napi_status napi_delete_async_work(napi_env, napi_async_work work) { delete work; return napi_ok; }
napi_status napi_create_threadsafe_function(napi_env e, napi_value, napi_value, napi_value, size_t, size_t,
    void *finalizeData, napi_finalize finalize, void *context, napi_threadsafe_function_call_js js, napi_threadsafe_function *out)
{
    if (e->failTsfn) return napi_generic_failure;
    *out = new FakeTsfn{e, finalizeData, finalize, context, js, {}, false, false, false};
    std::lock_guard<std::mutex> lock(e->mutex); e->completions.push_back(*out); return napi_ok;
}
napi_status napi_call_threadsafe_function(napi_threadsafe_function t, void *, napi_threadsafe_function_call_mode)
{ std::lock_guard<std::mutex> lock(t->mutex); if (t->aborted) return napi_closing; t->pending = true; return napi_ok; }
napi_status napi_release_threadsafe_function(napi_threadsafe_function t, napi_threadsafe_function_release_mode mode)
{ std::lock_guard<std::mutex> lock(t->mutex); t->released = true; t->aborted = mode == napi_tsfn_abort; return napi_ok; }

void DrainCompletions(FakeEnv &env)
{
    std::vector<FakeTsfn *> calls;
    { std::lock_guard<std::mutex> lock(env.mutex); calls = env.completions; }
    for (FakeTsfn *call : calls) {
        bool pending, released;
        {
            std::lock_guard<std::mutex> lock(call->mutex);
            pending = call->pending && !call->aborted;
            call->pending = false;
            released = call->released;
        }
        if (pending) call->callJs(call->env, nullptr, call->context, nullptr);
        if (released) {
            { std::lock_guard<std::mutex> lock(env.mutex);
              env.completions.erase(std::remove(env.completions.begin(), env.completions.end(), call), env.completions.end()); }
            call->finalize(call->env, call->finalizeData, nullptr);
            delete call;
        }
    }
}

struct FakeMedia {
    std::mutex mutex;
    std::unordered_map<std::string, std::string> options;
    std::unordered_map<std::string, std::vector<std::string>> lists;
    std::vector<std::vector<std::string>> commands;
    std::vector<std::pair<std::string, mpv_format>> observed;
    struct Track { std::string type; bool external; bool selected; };
    std::vector<Track> tracks;
    int trackQueries = 0;
    std::string videoOutput = "gpu";
    int videoOutputError = 0;
    int videoOutputQueries = 0;
    double position = 0;
    int positionQueries = 0;
};
std::atomic<int> destroyed{0};
std::atomic<int> freedTrackNodes{0};
std::mutex destructionMutex;
std::condition_variable destructionCondition;
bool blockDestruction = false;
FakeMedia &Media(mpv_handle *handle) { return *reinterpret_cast<FakeMedia *>(handle); }
extern "C" mpv_handle *mpv_create() { return reinterpret_cast<mpv_handle *>(new FakeMedia()); }
extern "C" int mpv_initialize(mpv_handle *) { return 0; }
extern "C" int mpv_set_option_string(mpv_handle *h, const char *name, const char *value)
{ Media(h).options[name] = value; return 0; }
extern "C" int mpv_set_option(mpv_handle *h, const char *name, mpv_format format, void *value)
{ assert(format == MPV_FORMAT_INT64); Media(h).options[name] = std::to_string(*static_cast<int64_t *>(value)); return 0; }
extern "C" int mpv_set_property(mpv_handle *h, const char *name, mpv_format format, void *data)
{
    auto &media = Media(h); std::lock_guard<std::mutex> lock(media.mutex);
    if (format == MPV_FORMAT_STRING) media.options[name] = *static_cast<char **>(data);
    else {
        assert(format == MPV_FORMAT_NODE);
        const auto &node = *static_cast<mpv_node *>(data);
        assert(node.format == MPV_FORMAT_NODE_ARRAY);
        std::vector<std::string> exact;
        for (int i = 0; i < node.u.list->num; ++i) {
            assert(node.u.list->values[i].format == MPV_FORMAT_STRING);
            exact.emplace_back(node.u.list->values[i].u.string);
        }
        media.lists[name] = std::move(exact);
    }
    return 0;
}
extern "C" int mpv_set_property_async(mpv_handle *, uint64_t, const char *, mpv_format, void *) { return 0; }
char *OwnedString(const std::string &value)
{ auto *copy = new char[value.size() + 1]; std::memcpy(copy, value.c_str(), value.size() + 1); return copy; }
extern "C" int mpv_get_property(mpv_handle *h, const char *name, mpv_format format, void *data)
{
    if (std::strcmp(name, "current-vo") == 0) {
        assert(format == MPV_FORMAT_STRING);
        auto &media = Media(h); ++media.videoOutputQueries;
        if (media.videoOutputError < 0) return media.videoOutputError;
        *static_cast<char **>(data) = OwnedString(media.videoOutput); return 0;
    }
    if (std::strcmp(name, "time-pos") == 0) {
        assert(format == MPV_FORMAT_DOUBLE);
        ++Media(h).positionQueries; *static_cast<double *>(data) = Media(h).position; return 0;
    }
    assert(std::strcmp(name, "track-list") == 0 && format == MPV_FORMAT_NODE);
    auto &media = Media(h); ++media.trackQueries;
    auto &result = *static_cast<mpv_node *>(data);
    result.format = MPV_FORMAT_NODE_ARRAY;
    result.u.list = new mpv_node_list{};
    result.u.list->num = static_cast<int>(media.tracks.size());
    result.u.list->values = new mpv_node[media.tracks.size()]{};
    for (size_t i = 0; i < media.tracks.size(); ++i) {
        auto &entry = result.u.list->values[i]; const auto &track = media.tracks[i];
        entry.format = MPV_FORMAT_NODE_MAP; entry.u.list = new mpv_node_list{};
        entry.u.list->num = 3; entry.u.list->values = new mpv_node[3]{};
        entry.u.list->keys = new char *[3]{OwnedString("type"), OwnedString("external"), OwnedString("selected")};
        entry.u.list->values[0].format = MPV_FORMAT_STRING; entry.u.list->values[0].u.string = OwnedString(track.type);
        entry.u.list->values[1].format = MPV_FORMAT_FLAG; entry.u.list->values[1].u.flag = track.external;
        entry.u.list->values[2].format = MPV_FORMAT_FLAG; entry.u.list->values[2].u.flag = track.selected;
    }
    return 0;
}
extern "C" void mpv_free(void *data) { delete[] static_cast<char *>(data); }
void FreeNode(mpv_node &node)
{
    if (node.format == MPV_FORMAT_STRING) delete[] node.u.string;
    else if (node.format == MPV_FORMAT_NODE_ARRAY || node.format == MPV_FORMAT_NODE_MAP) {
        auto *list = node.u.list;
        for (int i = 0; i < list->num; ++i) {
            FreeNode(list->values[i]);
            if (list->keys) delete[] list->keys[i];
        }
        delete[] list->values; delete[] list->keys; delete list;
    }
    node = {};
}
extern "C" void mpv_free_node_contents(mpv_node *node) { FreeNode(*node); ++freedTrackNodes; }
extern "C" int mpv_command(mpv_handle *h, const char **args)
{
    std::vector<std::string> exact;
    for (size_t i = 0; args[i]; ++i) exact.emplace_back(args[i]);
    auto &media = Media(h); std::lock_guard<std::mutex> lock(media.mutex); media.commands.push_back(std::move(exact)); return 0;
}
extern "C" int mpv_command_async(mpv_handle *, uint64_t, const char **) { return 0; }
extern "C" int mpv_observe_property(mpv_handle *h, uint64_t, const char *name, mpv_format format)
{ Media(h).observed.emplace_back(name, format); return 0; }
extern "C" mpv_event *mpv_wait_event(mpv_handle *, double timeout)
{
    if (timeout > 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    static thread_local mpv_event event{}; return &event;
}
extern "C" void mpv_terminate_destroy(mpv_handle *h)
{
    std::unique_lock<std::mutex> lock(destructionMutex);
    destructionCondition.wait(lock, [] { return !blockDestruction; });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    ++destroyed;
    delete reinterpret_cast<FakeMedia *>(h);
}

void EventFor(Session &session, mpv_event_id kind, uint64_t reply = 0, int error = 0)
{ mpv_event event{}; event.event_id = kind; event.reply_userdata = reply; event.error = error; ProcessEvent(session, event); }
void Position(Session &session, double value)
{ Media(session.handle).position = value; mpv_event_property property{"time-pos", MPV_FORMAT_DOUBLE, &value}; ProcessProperty(session, property); }
void AcceptedSeek(Session &session, double target, double request)
{
    Control control; control.kind = ControlKind::Seek; control.value = target; control.request = request;
    ProcessControl(session, control);
    EventFor(session, MPV_EVENT_COMMAND_REPLY, session.nextReply - 1);
    EventFor(session, MPV_EVENT_SEEK);
}
template<class Check> void WaitFor(Check check)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!check()) {
        assert(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
std::shared_ptr<Session> BareSession()
{ auto session = std::make_shared<Session>(); session->handle = mpv_create(); return session; }

void SeekOrder()
{
    auto session = BareSession(); auto &s = *session;
    Control control; control.kind = ControlKind::Seek; control.value = 12; control.request = 12000;
    ProcessControl(s, control); EventFor(s, MPV_EVENT_PLAYBACK_RESTART);
    assert(s.events.back().request == -1 && s.activeSeek == 12000);
    EventFor(s, MPV_EVENT_SEEK); EventFor(s, MPV_EVENT_PLAYBACK_RESTART);
    assert(s.events.back().request == -1 && s.activeSeek == 12000);
    EventFor(s, MPV_EVENT_COMMAND_REPLY, 1); EventFor(s, MPV_EVENT_SEEK);
    Position(s, 12.25); EventFor(s, MPV_EVENT_PLAYBACK_RESTART);
    assert(s.events.back().request == 12000 && s.state.position == 12.25 && s.activeSeek == -1);
    CloseNative(session);
}
void ZeroSerialSeek()
{
    auto session = BareSession(); auto &s = *session;
    AcceptedSeek(s, 0, 0); Position(s, 0); EventFor(s, MPV_EVENT_PLAYBACK_RESTART);
    assert(s.events.back().request == 0 && s.activeSeek == -1);
    AcceptedSeek(s, 7, 7000); Position(s, 6.91); EventFor(s, MPV_EVENT_PLAYBACK_RESTART);
    assert(s.events.back().request == 7000 && s.state.position == 6.91 && s.replies.empty());
    CloseNative(session);
}
void SeekCommandError()
{
    auto session = BareSession(); auto &s = *session;
    Control control; control.kind = ControlKind::Seek; control.value = 8; control.request = 8000;
    ProcessControl(s, control); EventFor(s, MPV_EVENT_COMMAND_REPLY, 1, MPV_ERROR_COMMAND);
    assert(s.events.back().kind == "error" && s.events.back().request == 8000 && s.events.back().errorCode == MPV_ERROR_COMMAND);
    EventFor(s, MPV_EVENT_PLAYBACK_RESTART); assert(s.events.back().request == -1);
    CloseNative(session);
}
void PausePlayAcks()
{
    auto session = BareSession(); auto &s = *session; s.state.loaded = true;
    Control pause; pause.kind = ControlKind::Pause; pause.value = 1; ProcessControl(s, pause);
    pause.value = 0; ProcessControl(s, pause);
    EventFor(s, MPV_EVENT_SET_PROPERTY_REPLY, 1); EventFor(s, MPV_EVENT_SET_PROPERTY_REPLY, 2);
    int finalPause = 0; mpv_event_property property{"pause", MPV_FORMAT_FLAG, &finalPause}; ProcessProperty(s, property);
    assert(s.events.size() == 2 && s.events.front().kind == "paused" && s.events.front().request == 1);
    assert(s.events.back().kind == "playing" && s.events.back().request == 0 && !s.state.paused);
    CloseNative(session);
}
void NativeReleaseBarrier()
{
    auto session = BareSession(); std::atomic<bool> eventStopped{false}; std::atomic<int> returned{0};
    session->eventThread = std::thread([&] { while (!session->closing.load()) std::this_thread::yield(); eventStopped = true; });
    auto release = [&] { CloseNative(session); assert(destroyed == 1 && eventStopped); ++returned; };
    std::thread first(release), second(release); first.join(); second.join();
    assert(returned == 2 && destroyed == 1 && session->handle == nullptr);
}
void ReleaseFallback(bool available)
{
    FakeEnv env; env.failAsyncCreate = !available; env.failAsyncQueue = true; env.failTsfn = !available;
    napi_value exports; napi_create_object(&env, &exports); Init(&env, exports);
    auto runtime = GetRuntime(&env); auto session = BareSession(); runtime->sessions.emplace(1, session);
    napi_value id; napi_create_uint32(&env, 1, &id); FakeArgs args{{id}};
    if (available) { std::lock_guard<std::mutex> lock(destructionMutex); blockDestruction = true; }
    napi_value first = Release(&env, &args);
    assert(runtime->sessions.empty() && runtime->retiring.size() == 1 && session->closing);
    if (available) {
        napi_value second = Release(&env, &args);
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        DrainCompletions(env);
        assert(first->settled == 0 && second->settled == 0 && destroyed == 0 && runtime->retiring.size() == 1);
        { std::lock_guard<std::mutex> lock(destructionMutex); blockDestruction = false; }
        destructionCondition.notify_all();
        WaitFor([&] { DrainCompletions(env); return first->settled && second->settled; });
        assert(first->settled == 1 && second->settled == 1 && destroyed == 1 && runtime->retiring.empty());
        WaitFor([&] { DrainCompletions(env); std::lock_guard<std::mutex> lock(env.mutex); return env.completions.empty(); });
    } else {
        assert(first->settled == 2 && destroyed == 0 && runtime->retiring.size() == 1);
        // Ownership remains retained after notification failure, preventing a
        // caller from mistaking it for a successful surface-reuse barrier.
        CloseNative(session); assert(destroyed == 1);
    }
    Cleanup(&env);
}
void ExactSourceOptions()
{
    auto session = BuildSession(123, "/private/cache/mozilla-ca.pem"); auto &media = Media(session->handle);
    assert(media.options.at("wid") == "123" && media.options.at("tls-verify") == "yes");
    assert(media.options.at("tls-ca-file") == "/private/cache/mozilla-ca.pem" && media.options.at("hwdec") == "auto-safe");
    assert(media.options.at("vo") == "gpu" && media.options.at("gpu-context") == "ohos" && media.options.at("ao") == "ohaudio");
    assert(media.options.at("egl-output-format") == "rgba8" && media.options.at("opengl-es") == "yes");
    assert(media.options.at("keep-open") == "yes" && media.options.at("video-sync") == "audio");
    const std::string video = "https://cdn.example/video:a,b.m4s?token=x%2Fy,a:b&v=1";
    const std::string audio = "https://cdn.example/audio:c,d.m4s?token=audio,a:b";
    OpenNative(session, video, audio, {"User-Agent: Bili,Player:1", "Referer: https://www.bilibili.com/", "X-Test: v,a:b"});
    assert(session->requiresExternalAudio.load());
    assert(media.lists.at("audio-files") == std::vector<std::string>{audio});
    assert((media.lists.at("http-header-fields") == std::vector<std::string>{"Referer: https://www.bilibili.com/", "X-Test: v,a:b"}));
    assert(media.options.at("user-agent") == "Bili,Player:1");
    assert((media.commands.back() == std::vector<std::string>{"loadfile", video, "replace", "-1"}));
    assert(std::find(media.observed.begin(), media.observed.end(), std::make_pair(std::string("time-pos"), MPV_FORMAT_DOUBLE)) != media.observed.end());
    CloseNative(session);
}

void ExternalAudio(bool present, bool selected)
{
    auto session = BareSession(); session->requiresExternalAudio.store(true);
    auto &media = Media(session->handle);
    media.tracks.push_back({"video", false, true});
    if (present) media.tracks.push_back({"audio", true, selected});
    if (!selected) media.tracks.push_back({"audio", false, true});
    EventFor(*session, MPV_EVENT_FILE_LOADED);
    assert(media.trackQueries == 1 && freedTrackNodes == 1);
    if (present && selected) {
        assert(session->state.loaded && session->events.size() == 1 && session->events.back().kind == "file-loaded");
    } else {
        assert(!session->state.loaded && session->events.size() == 1 && session->events.back().kind == "audio-error");
        assert(session->events.back().errorCode == MPV_ERROR_LOADING_FAILED);
    }
    CloseNative(session);
}

void VideoOutput(bool selected, const std::string &output, int outputError = 0)
{
    auto session = BareSession(); auto &media = Media(session->handle);
    media.tracks.push_back({"video", false, selected});
    media.tracks.push_back({"audio", false, true});
    media.videoOutput = output;
    media.videoOutputError = outputError;
    EventFor(*session, MPV_EVENT_FILE_LOADED);
    assert(media.trackQueries == 1 && media.videoOutputQueries == (selected ? 1 : 0));
    assert(session->events.size() == 1);
    if (selected && output == "gpu" && outputError >= 0) {
        assert(session->state.loaded && session->events.back().kind == "file-loaded");
    } else {
        assert(!session->state.loaded && !session->state.buffering && session->events.back().kind == "error");
        assert(session->events.back().errorCode == MPV_ERROR_VO_INIT_FAILED);
    }
    CloseNative(session);
}

void ActualSeekLanding()
{
    auto session = BareSession(); Position(*session, 5.25);
    AcceptedSeek(*session, 57, 57000);
    // The core has landed, but its coalesced observer notification has not yet
    // reached the bridge. Only the native completion query can see this value.
    Media(session->handle).position = 57.125;
    EventFor(*session, MPV_EVENT_PLAYBACK_RESTART);
    assert(Media(session->handle).positionQueries == 1);
    assert(session->state.position == 57.125 && session->events.back().position == 57.125);
    assert(session->events.back().request == 57000 && session->activeSeek == -1);
    CloseNative(session);
}

int main(int argc, char **argv)
{
    assert(argc == 2); const std::string name = argv[1];
    if (name == "seek-order") SeekOrder();
    else if (name == "zero-serial-seek") ZeroSerialSeek();
    else if (name == "seek-command-error") SeekCommandError();
    else if (name == "pause-play-acks") PausePlayAcks();
    else if (name == "native-release-barrier") NativeReleaseBarrier();
    else if (name == "async-release-fallback") ReleaseFallback(true);
    else if (name == "release-fallback-unavailable") ReleaseFallback(false);
    else if (name == "exact-source-options") ExactSourceOptions();
    else if (name == "selected-external-audio") ExternalAudio(true, true);
    else if (name == "missing-external-audio") ExternalAudio(false, false);
    else if (name == "unselected-external-audio") ExternalAudio(true, false);
    else if (name == "selected-video-output") VideoOutput(true, "gpu");
    else if (name == "failed-video-output") {
        VideoOutput(true, "", MPV_ERROR_PROPERTY_UNAVAILABLE);
        VideoOutput(true, "");
        VideoOutput(true, "null");
    }
    else if (name == "unselected-video-track") VideoOutput(false, "gpu");
    else if (name == "actual-seek-landing") ActualSeekLanding();
    else assert(false && "unknown native fixture case");
    std::cout << "PASS " << name << '\n';
}
