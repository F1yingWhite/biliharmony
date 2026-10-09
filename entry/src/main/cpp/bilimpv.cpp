// ArkTS/N-API boundary for the native libmpv session: validate arguments,
// marshal observed state and deliver asynchronous lifecycle completion.
#include <napi/native_api.h>
#include "mpv_session.h"

#include <atomic>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using bilimpv::BuildSession;
using bilimpv::CloseNative;
using bilimpv::Control;
using bilimpv::ControlKind;
using bilimpv::EnqueueControl;
using bilimpv::OpenNative;
using bilimpv::Session;
using bilimpv::TakeSnapshot;

struct Runtime {
    std::atomic<bool> alive{true};
    std::mutex mutex;
    std::unordered_map<uint32_t, std::shared_ptr<Session>> sessions;
    // A repeated release must wait for the same destruction barrier, rather
    // than resolve early while the native surface is still in use.
    std::unordered_map<uint32_t, std::shared_ptr<Session>> retiring;
};

std::mutex runtimesMutex;
std::unordered_map<napi_env, std::shared_ptr<Runtime>> runtimes;
std::atomic<uint32_t> nextId{1};

std::shared_ptr<Runtime> GetRuntime(napi_env env)
{
    std::lock_guard<std::mutex> lock(runtimesMutex);
    const auto it = runtimes.find(env);
    return it == runtimes.end() ? nullptr : it->second;
}

std::shared_ptr<Session> GetSession(napi_env env, uint32_t id)
{
    const auto runtime = GetRuntime(env);
    if (!runtime || !runtime->alive.load()) return nullptr;
    std::lock_guard<std::mutex> lock(runtime->mutex);
    const auto it = runtime->sessions.find(id);
    return it == runtime->sessions.end() ? nullptr : it->second;
}

void Cleanup(void *data)
{
    const auto env = static_cast<napi_env>(data);
    std::shared_ptr<Runtime> runtime;
    {
        std::lock_guard<std::mutex> lock(runtimesMutex);
        auto it = runtimes.find(env);
        if (it == runtimes.end()) return;
        runtime = it->second;
        runtimes.erase(it);
    }
    runtime->alive.store(false);
    std::vector<std::shared_ptr<Session>> sessions;
    {
        std::lock_guard<std::mutex> lock(runtime->mutex);
        for (const auto &item : runtime->sessions) {
            item.second->closing.store(true);
            sessions.push_back(item.second);
        }
        for (const auto &item : runtime->retiring) sessions.push_back(item.second);
        runtime->sessions.clear();
        runtime->retiring.clear();
    }
    // Environment teardown cannot retain an ArkTS callback or block its thread.
    std::thread([sessions = std::move(sessions)]() {
        for (const auto &session : sessions) CloseNative(session);
    }).detach();
}

enum class WorkKind { Create, Open, Release };

struct Work {
    WorkKind kind;
    napi_env env;
    napi_deferred deferred = nullptr;
    napi_async_work async = nullptr;
    std::shared_ptr<Runtime> runtime;
    std::shared_ptr<Session> session;
    uint32_t id = 0;
    uint64_t surface = 0;
    std::string caFile;
    std::string video;
    std::string audio;
    std::vector<std::string> headers;
    std::string error;
};

void Execute(napi_env, void *data)
{
    auto &work = *static_cast<Work *>(data);
    try {
        if (work.kind == WorkKind::Create) {
            if (!work.runtime->alive.load()) throw std::runtime_error("播放器会话已失效");
            work.session = BuildSession(work.surface, work.caFile);
            {
                std::lock_guard<std::mutex> lock(work.runtime->mutex);
                if (work.runtime->alive.load()) work.runtime->sessions.emplace(work.id, work.session);
            }
            if (!work.runtime->alive.load()) CloseNative(work.session);
        } else if (work.kind == WorkKind::Open) {
            OpenNative(work.session, work.video, work.audio, work.headers);
        } else {
            CloseNative(work.session);
        }
    } catch (const std::exception &error) {
        work.error = error.what();
    } catch (...) {
        work.error = "播放器内核操作失败";
    }
}

void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Work> work(static_cast<Work *>(data));
    if (!work->runtime->alive.load()) return;
    if (status != napi_ok && work->error.empty()) work->error = "播放器异步操作取消";
    if (work->kind == WorkKind::Release) {
        std::lock_guard<std::mutex> lock(work->runtime->mutex);
        work->runtime->retiring.erase(work->id);
    } else if (work->kind == WorkKind::Create && !work->error.empty() && work->session) {
        {
            std::lock_guard<std::mutex> lock(work->runtime->mutex);
            work->runtime->sessions.erase(work->id);
        }
        std::thread([session = work->session]() { CloseNative(session); }).detach();
    }
    napi_value value;
    if (work->error.empty()) {
        if (work->kind == WorkKind::Create) napi_create_uint32(env, work->id, &value);
        else napi_get_undefined(env, &value);
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->async);
}

void RejectWork(napi_env env, const Work &work, const char *text)
{
    napi_value message, error;
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, work.deferred, error);
}

void FinalizeFallback(napi_env, void *data, void *)
{
    delete static_cast<Work *>(data);
}

void CompleteFallback(napi_env env, napi_value, void *context, void *)
{
    auto &work = *static_cast<Work *>(context);
    if (!env || !work.runtime->alive.load()) return;
    {
        std::lock_guard<std::mutex> lock(work.runtime->mutex);
        work.runtime->retiring.erase(work.id);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_resolve_deferred(env, work.deferred, undefined);
}

napi_value FallbackRelease(std::unique_ptr<Work> work, napi_value promise, napi_value name)
{
    // If the shared async-work pool rejects scheduling, shutdown still has to
    // provide a real completion barrier. A single TSFN completion owns no user
    // callback and resolves only after joining and destroying the native core.
    napi_threadsafe_function completion = nullptr;
    const napi_env env = work->env;
    if (napi_create_threadsafe_function(env, nullptr, nullptr, name, 1, 1,
        work.get(), FinalizeFallback, work.get(), CompleteFallback, &completion) != napi_ok) {
        // Keep Runtime.retiring alive, and reject. A caller must preserve this
        // failed barrier and cannot assume the surface is available for reuse.
        RejectWork(env, *work, "播放器释放任务未能启动，请重试");
        return promise;
    }
    Work *owned = work.release();
    try {
        std::thread([session = owned->session, completion]() {
            CloseNative(session);
            napi_call_threadsafe_function(completion, nullptr, napi_tsfn_nonblocking);
            napi_release_threadsafe_function(completion, napi_tsfn_release);
        }).detach();
    } catch (...) {
        RejectWork(env, *owned, "播放器释放任务未能启动，请重试");
        napi_release_threadsafe_function(completion, napi_tsfn_abort);
    }
    return promise;
}

napi_value StartWork(std::unique_ptr<Work> work)
{
    napi_value promise;
    napi_value name;
    const napi_env env = work->env;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "BiliMpvWork", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->async) != napi_ok ||
        napi_queue_async_work(env, work->async) != napi_ok) {
        if (work->async) napi_delete_async_work(env, work->async);
        work->async = nullptr;
        if (work->kind == WorkKind::Release && work->session) {
            return FallbackRelease(std::move(work), promise, name);
        }
        RejectWork(env, *work, "播放器异步任务启动失败");
        return promise;
    }
    work.release();
    return promise;
}

bool ReadString(napi_env env, napi_value value, std::string &out, size_t limit = 32768)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > limit) return false;
    std::vector<char> bytes(length + 1);
    if (napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &length) != napi_ok) return false;
    out.assign(bytes.data(), length);
    return out.find('\0') == std::string::npos && out.find('\r') == std::string::npos && out.find('\n') == std::string::npos;
}

bool ReadNumber(napi_env env, napi_value value, double &out)
{
    return napi_get_value_double(env, value, &out) == napi_ok && std::isfinite(out);
}

bool ReadId(napi_env env, napi_value value, uint32_t &id)
{
    double number;
    if (!ReadNumber(env, value, number) || number < 1 || number > std::numeric_limits<uint32_t>::max() || std::floor(number) != number) return false;
    id = static_cast<uint32_t>(number);
    return true;
}

napi_value Invalid(napi_env env)
{
    napi_throw_type_error(env, nullptr, "播放器参数无效或会话已释放");
    return nullptr;
}

napi_value Create(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string surface;
    std::string caFile;
    uint64_t wid = 0;
    if (argc < 1 || !ReadString(env, args[0], surface, 32) || surface.empty()) return Invalid(env);
    const auto parsed = std::from_chars(surface.data(), surface.data() + surface.size(), wid);
    if (parsed.ec != std::errc{} || parsed.ptr != surface.data() + surface.size() || wid == 0 || wid == UINT64_MAX) return Invalid(env);
    if (argc < 2 || !ReadString(env, args[1], caFile) || caFile.empty() || caFile[0] != '/') return Invalid(env);
    auto work = std::make_unique<Work>();
    work->kind = WorkKind::Create;
    work->env = env;
    work->runtime = GetRuntime(env);
    if (!work->runtime) return Invalid(env);
    work->surface = wid;
    work->caFile = caFile;
    work->id = nextId.fetch_add(1);
    if (work->id == 0) return Invalid(env);
    return StartWork(std::move(work));
}

napi_value Open(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t id;
    auto work = std::make_unique<Work>();
    if (argc < 4 || !ReadId(env, args[0], id) || !ReadString(env, args[1], work->video) || work->video.empty() ||
        !ReadString(env, args[2], work->audio)) return Invalid(env);
    bool array = false;
    uint32_t count = 0;
    napi_is_array(env, args[3], &array);
    if (!array || napi_get_array_length(env, args[3], &count) != napi_ok || count > 32) return Invalid(env);
    for (uint32_t i = 0; i < count; ++i) {
        napi_value header;
        std::string text;
        napi_get_element(env, args[3], i, &header);
        if (!ReadString(env, header, text, 8192)) return Invalid(env);
        work->headers.push_back(std::move(text));
    }
    work->session = GetSession(env, id);
    if (!work->session || work->session->closing.load()) return Invalid(env);
    work->kind = WorkKind::Open;
    work->env = env;
    work->runtime = GetRuntime(env);
    return StartWork(std::move(work));
}

void PutNumber(napi_env env, napi_value object, const char *name, double number)
{
    napi_value value;
    napi_create_double(env, number, &value);
    napi_set_named_property(env, object, name, value);
}

void PutBoolean(napi_env env, napi_value object, const char *name, bool boolean)
{
    napi_value value;
    napi_get_boolean(env, boolean, &value);
    napi_set_named_property(env, object, name, value);
}

void PutString(napi_env env, napi_value object, const char *name, const std::string &text)
{
    napi_value value;
    napi_create_string_utf8(env, text.c_str(), text.size(), &value);
    napi_set_named_property(env, object, name, value);
}

napi_value Poll(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    uint32_t id;
    if (argc < 1 || !ReadId(env, arg, id)) return Invalid(env);
    auto session = GetSession(env, id);
    if (!session || session->closing.load()) return Invalid(env);
    const auto snapshot = TakeSnapshot(session);
    const auto &state = snapshot.state;
    const auto &events = snapshot.events;
    napi_value result;
    napi_create_object(env, &result);
    PutNumber(env, result, "position", state.position);
    PutNumber(env, result, "audioPts", state.audioPts);
    PutNumber(env, result, "duration", state.duration);
    PutNumber(env, result, "width", static_cast<double>(state.width));
    PutNumber(env, result, "height", static_cast<double>(state.height));
    PutBoolean(env, result, "paused", state.paused);
    PutBoolean(env, result, "buffering", state.buffering);
    PutBoolean(env, result, "eof", state.eof);
    PutBoolean(env, result, "loaded", state.loaded);
    PutNumber(env, result, "speed", state.speed);
    PutNumber(env, result, "volume", state.volume);
    PutString(env, result, "hwdec", state.hwdec);
    PutString(env, result, "sourcePrimaries", state.sourcePrimaries);
    PutString(env, result, "sourceTransfer", state.sourceTransfer);
    PutString(env, result, "sourceFormat", state.sourceFormat);
    PutString(env, result, "targetPrimaries", state.targetPrimaries);
    PutString(env, result, "targetTransfer", state.targetTransfer);
    PutString(env, result, "vo", state.vo);
    PutNumber(env, result, "avSync", state.avSync);
    PutNumber(env, result, "droppedFrames", static_cast<double>(state.droppedFrames));
    PutNumber(env, result, "decoderDroppedFrames", static_cast<double>(state.decoderDroppedFrames));
    napi_value list;
    napi_create_array_with_length(env, events.size(), &list);
    uint32_t index = 0;
    for (const auto &event : events) {
        napi_value item;
        napi_create_object(env, &item);
        PutString(env, item, "kind", event.kind);
        PutNumber(env, item, "request", event.request);
        // Use the last actually observed native position after the drained
        // batch, including property updates coalesced behind playback-restart.
        PutNumber(env, item, "position", state.position);
        PutNumber(env, item, "errorCode", event.errorCode);
        napi_set_element(env, list, index++, item);
    }
    napi_set_named_property(env, result, "events", list);
    return result;
}

napi_value QueueControl(napi_env env, napi_callback_info info, ControlKind kind, bool paused = false)
{
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t id;
    if (argc < 1 || !ReadId(env, args[0], id)) return Invalid(env);
    auto session = GetSession(env, id);
    if (!session || session->closing.load()) return Invalid(env);
    Control control;
    control.kind = kind;
    if (kind == ControlKind::Pause) control.value = paused ? 1 : 0;
    else if (kind == ControlKind::Seek) {
        if (argc < 4 || !ReadNumber(env, args[1], control.value) || control.value < 0 ||
            !ReadNumber(env, args[2], control.request) || control.request < 0 || std::floor(control.request) != control.request ||
            control.request > 9007199254740991.0 || napi_get_value_bool(env, args[3], &control.precise) != napi_ok) return Invalid(env);
    } else if (kind == ControlKind::Resize) {
        double width, height;
        if (argc < 3 || !ReadNumber(env, args[1], width) || !ReadNumber(env, args[2], height) || width <= 0 || height <= 0 ||
            width > 16384 || height > 16384) return Invalid(env);
        control.width = static_cast<int64_t>(std::round(width));
        control.height = static_cast<int64_t>(std::round(height));
    } else {
        if (argc < 2 || !ReadNumber(env, args[1], control.value)) return Invalid(env);
        if (kind == ControlKind::Rate && (control.value < 0.25 || control.value > 4)) return Invalid(env);
        if (kind == ControlKind::Volume && (control.value < 0 || control.value > 1)) return Invalid(env);
    }
    if (!EnqueueControl(session, control)) return Invalid(env);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value Play(napi_env env, napi_callback_info info) { return QueueControl(env, info, ControlKind::Pause, false); }
napi_value Pause(napi_env env, napi_callback_info info) { return QueueControl(env, info, ControlKind::Pause, true); }
napi_value Seek(napi_env env, napi_callback_info info) { return QueueControl(env, info, ControlKind::Seek); }
napi_value Rate(napi_env env, napi_callback_info info) { return QueueControl(env, info, ControlKind::Rate); }
napi_value Volume(napi_env env, napi_callback_info info) { return QueueControl(env, info, ControlKind::Volume); }
napi_value Resize(napi_env env, napi_callback_info info) { return QueueControl(env, info, ControlKind::Resize); }

napi_value Release(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    uint32_t id;
    if (argc < 1 || !ReadId(env, arg, id)) return Invalid(env);
    auto runtime = GetRuntime(env);
    if (!runtime) return Invalid(env);
    auto work = std::make_unique<Work>();
    work->kind = WorkKind::Release;
    work->env = env;
    work->runtime = runtime;
    work->id = id;
    {
        std::lock_guard<std::mutex> lock(runtime->mutex);
        auto item = runtime->sessions.find(id);
        if (item == runtime->sessions.end()) {
            auto retiring = runtime->retiring.find(id);
            if (retiring != runtime->retiring.end()) work->session = retiring->second;
        } else {
            work->session = item->second;
            work->session->closing.store(true);
            runtime->retiring.emplace(id, work->session);
            runtime->sessions.erase(item);
        }
    }
    if (!work->session) {
        // Idempotent release permits cleanup after a cancelled open. The ID is
        // absent from both maps only when native destruction already completed.
        napi_value promise, undefined;
        napi_deferred deferred;
        napi_create_promise(env, &deferred, &promise);
        napi_get_undefined(env, &undefined);
        napi_resolve_deferred(env, deferred, undefined);
        return promise;
    }
    return StartWork(std::move(work));
}

napi_value Init(napi_env env, napi_value exports)
{
    {
        std::lock_guard<std::mutex> lock(runtimesMutex);
        runtimes.emplace(env, std::make_shared<Runtime>());
    }
    napi_add_env_cleanup_hook(env, Cleanup, env);
    const napi_property_descriptor methods[] = {
        {"create", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"open", nullptr, Open, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"poll", nullptr, Poll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"play", nullptr, Play, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seek", nullptr, Seek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rate", nullptr, Rate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"volume", nullptr, Volume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resize", nullptr, Resize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}

napi_module module = {1, 0, nullptr, Init, "bilimpv", nullptr, {nullptr, nullptr, nullptr, nullptr}};

} // namespace

extern "C" __attribute__((constructor)) void RegisterBiliMpv()
{
    napi_module_register(&module);
}
