// Host-only N-API boundary declarations. Production includes the OHOS SDK's
// native_api.h; the regression fixture supplies these APIs without an SDK.
#pragma once
#include <cstddef>
#include <cstdint>

struct FakeEnv;
struct FakeValue;
struct FakeAsync;
struct FakeTsfn;
using napi_env = FakeEnv *;
using napi_value = FakeValue *;
using napi_deferred = FakeValue *;
using napi_async_work = FakeAsync *;
using napi_threadsafe_function = FakeTsfn *;
using napi_callback_info = void *;
enum napi_status { napi_ok, napi_invalid_arg, napi_generic_failure, napi_closing };
enum napi_property_attributes { napi_default = 0 };
enum napi_threadsafe_function_call_mode { napi_tsfn_nonblocking, napi_tsfn_blocking };
enum napi_threadsafe_function_release_mode { napi_tsfn_release, napi_tsfn_abort };
using napi_callback = napi_value (*)(napi_env, napi_callback_info);
using napi_async_execute_callback = void (*)(napi_env, void *);
using napi_async_complete_callback = void (*)(napi_env, napi_status, void *);
using napi_finalize = void (*)(napi_env, void *, void *);
using napi_threadsafe_function_call_js = void (*)(napi_env, napi_value, void *, void *);
struct napi_property_descriptor {
    const char *utf8name;
    napi_value name;
    napi_callback method;
    napi_callback getter;
    napi_callback setter;
    napi_value value;
    napi_property_attributes attributes;
    void *data;
};
struct napi_module {
    int nm_version;
    unsigned int nm_flags;
    const char *nm_filename;
    napi_value (*nm_register_func)(napi_env, napi_value);
    const char *nm_modname;
    void *nm_priv;
    void *reserved[4];
};
constexpr size_t NAPI_AUTO_LENGTH = static_cast<size_t>(-1);

napi_status napi_create_promise(napi_env, napi_deferred *, napi_value *);
napi_status napi_create_async_work(napi_env, napi_value, napi_value, napi_async_execute_callback,
    napi_async_complete_callback, void *, napi_async_work *);
napi_status napi_queue_async_work(napi_env, napi_async_work);
napi_status napi_delete_async_work(napi_env, napi_async_work);
napi_status napi_create_threadsafe_function(napi_env, napi_value, napi_value, napi_value, size_t, size_t,
    void *, napi_finalize, void *, napi_threadsafe_function_call_js, napi_threadsafe_function *);
napi_status napi_call_threadsafe_function(napi_threadsafe_function, void *, napi_threadsafe_function_call_mode);
napi_status napi_release_threadsafe_function(napi_threadsafe_function, napi_threadsafe_function_release_mode);
napi_status napi_resolve_deferred(napi_env, napi_deferred, napi_value);
napi_status napi_reject_deferred(napi_env, napi_deferred, napi_value);
napi_status napi_get_undefined(napi_env, napi_value *);
napi_status napi_create_string_utf8(napi_env, const char *, size_t, napi_value *);
napi_status napi_create_error(napi_env, napi_value, napi_value, napi_value *);
napi_status napi_create_uint32(napi_env, uint32_t, napi_value *);
napi_status napi_create_double(napi_env, double, napi_value *);
napi_status napi_get_boolean(napi_env, bool, napi_value *);
napi_status napi_create_object(napi_env, napi_value *);
napi_status napi_create_array_with_length(napi_env, size_t, napi_value *);
napi_status napi_set_named_property(napi_env, napi_value, const char *, napi_value);
napi_status napi_set_element(napi_env, napi_value, uint32_t, napi_value);
napi_status napi_get_element(napi_env, napi_value, uint32_t, napi_value *);
napi_status napi_get_array_length(napi_env, napi_value, uint32_t *);
napi_status napi_is_array(napi_env, napi_value, bool *);
napi_status napi_get_value_string_utf8(napi_env, napi_value, char *, size_t, size_t *);
napi_status napi_get_value_double(napi_env, napi_value, double *);
napi_status napi_get_value_bool(napi_env, napi_value, bool *);
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t *, napi_value *, napi_value *, void **);
napi_status napi_throw_type_error(napi_env, const char *, const char *);
napi_status napi_define_properties(napi_env, napi_value, size_t, const napi_property_descriptor *);
napi_status napi_add_env_cleanup_hook(napi_env, void (*)(void *), void *);
void napi_module_register(napi_module *);
