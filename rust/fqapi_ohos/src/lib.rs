//! fqapi_core 的手写 Node-API 绑定(最小符号集)。
//!
//! 为什么不用 napi-rs:商用 HarmonyOS(6.1.0)的 NAPI 运行时既缺
//! napi_reject_deferred(async 路线),napi-rs 2.16 的模块注册也无法生效
//! (exports 为空)。手写只依赖 6 个自 API 8 就存在的基础符号:
//! napi_get_cb_info / napi_get_value_string_utf8 / napi_get_value_uint32 /
//! napi_create_string_utf8 / napi_get_undefined / napi_set_named_property。
//!
//! 全同步接口 + 状态轮询(见 BackendService.ets)。

use std::ffi::{c_char, c_void, CString};
use std::ptr;

type napi_env = *mut c_void;
type napi_value = *mut c_void;
type napi_callback_info = *mut c_void;

extern "C" {
    fn napi_get_cb_info(env: napi_env, cbinfo: napi_callback_info, argc: *mut usize,
        argv: *mut napi_value, this_arg: *mut napi_value, data: *mut *mut c_void) -> u32;
    fn napi_create_string_utf8(env: napi_env, s: *const c_char, length: usize, result: *mut napi_value) -> u32;
    fn napi_get_value_string_utf8(env: napi_env, value: napi_value, buf: *mut c_char, bufsize: usize, result: *mut usize) -> u32;
    fn napi_get_value_uint32(env: napi_env, value: napi_value, result: *mut u32) -> u32;
    fn napi_get_undefined(env: napi_env, result: *mut napi_value) -> u32;
    fn napi_set_named_property(env: napi_env, obj: napi_value, name: *const c_char, value: napi_value) -> u32;
}

fn take_args(env: napi_env, info: napi_callback_info, max: usize) -> Vec<napi_value> {
    unsafe {
        let mut argc: usize = max;
        let mut argv: Vec<napi_value> = vec![ptr::null_mut(); max];
        napi_get_cb_info(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut());
        argv.truncate(argc);
        argv
    }
}

fn arg_to_string(env: napi_env, v: napi_value) -> String {
    unsafe {
        if v.is_null() {
            return String::new();
        }
        let mut len: usize = 0;
        if napi_get_value_string_utf8(env, v, ptr::null_mut(), 0, &mut len) != 0 {
            return String::new();
        }
        let mut buf: Vec<u8> = vec![0; len + 1];
        if napi_get_value_string_utf8(env, v, buf.as_mut_ptr() as *mut c_char, buf.len(), ptr::null_mut()) != 0 {
            return String::new();
        }
        buf.truncate(len);
        String::from_utf8_lossy(&buf).into_owned()
    }
}

fn arg_to_u32(env: napi_env, v: napi_value) -> u32 {
    unsafe {
        let mut out: u32 = 0;
        if !v.is_null() {
            napi_get_value_uint32(env, v, &mut out);
        }
        out
    }
}

fn ret_string(env: napi_env, s: &str) -> napi_value {
    unsafe {
        let mut result: napi_value = ptr::null_mut();
        let c = CString::new(s).unwrap_or_default();
        napi_create_string_utf8(env, c.as_ptr(), s.len(), &mut result);
        result
    }
}

fn ret_undefined(env: napi_env) -> napi_value {
    unsafe {
        let mut result: napi_value = ptr::null_mut();
        napi_get_undefined(env, &mut result);
        result
    }
}

// ---------- 核心状态(与之前 napi-rs 版相同) ----------

use once_cell::sync::{Lazy, OnceCell};
use std::sync::Mutex;
use tokio::runtime::Runtime;

static RT: OnceCell<Runtime> = OnceCell::new();

fn rt() -> &'static Runtime {
    RT.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

#[derive(Clone)]
struct Snapshot {
    status: String,
    error: String,
    base_url: String,
    capability: String,
}

fn new_snapshot(status: &str) -> Snapshot {
    Snapshot {
        status: status.to_string(),
        error: String::new(),
        base_url: String::new(),
        capability: String::new(),
    }
}

static STATE: Lazy<Mutex<Snapshot>> = Lazy::new(|| Mutex::new(new_snapshot("idle")));

fn init_start(config_path: String, pool_path: String, filter_path: String, runtime_dir: String, port: u32) {
    {
        let mut st = STATE.lock().unwrap();
        if st.status == "starting" || st.status == "running" {
            return;
        }
        *st = new_snapshot("starting");
    }
    rt().spawn(async move {
        let result = fqapi_core::api::init(
            config_path, pool_path, filter_path, runtime_dir, port as u16, String::new(),
        )
        .await;
        let (base_url, capability) = match result {
            Ok(_) => (
                fqapi_core::api::base_url().await,
                fqapi_core::api::session_capability().await,
            ),
            Err(_) => (String::new(), String::new()),
        };
        let mut st = STATE.lock().unwrap();
        match result {
            Ok(_) => {
                st.status = "running".to_string();
                st.base_url = base_url;
                st.capability = capability;
            }
            Err(e) => {
                st.status = "error".to_string();
                st.error = e;
            }
        }
    });
}

fn shutdown() {
    {
        let mut st = STATE.lock().unwrap();
        if st.status != "running" && st.status != "starting" {
            return;
        }
        st.status = "idle".to_string();
        st.base_url.clear();
        st.capability.clear();
    }
    let _ = rt().spawn(async {
        let _ = fqapi_core::api::shutdown().await;
    });
}

// ---------- NAPI 导出 ----------

unsafe extern "C" fn js_version(env: napi_env, _info: napi_callback_info) -> napi_value {
    ret_string(env, &fqapi_core::api::version())
}

unsafe extern "C" fn js_status(env: napi_env, _info: napi_callback_info) -> napi_value {
    ret_string(env, &STATE.lock().unwrap().status)
}

unsafe extern "C" fn js_last_error(env: napi_env, _info: napi_callback_info) -> napi_value {
    ret_string(env, &STATE.lock().unwrap().error)
}

unsafe extern "C" fn js_base_url(env: napi_env, _info: napi_callback_info) -> napi_value {
    ret_string(env, &STATE.lock().unwrap().base_url)
}

unsafe extern "C" fn js_capability(env: napi_env, _info: napi_callback_info) -> napi_value {
    ret_string(env, &STATE.lock().unwrap().capability)
}

unsafe extern "C" fn js_init_start(env: napi_env, info: napi_callback_info) -> napi_value {
    let args = take_args(env, info, 5);
    if args.len() < 5 {
        return ret_undefined(env);
    }
    init_start(
        arg_to_string(env, args[0]),
        arg_to_string(env, args[1]),
        arg_to_string(env, args[2]),
        arg_to_string(env, args[3]),
        arg_to_u32(env, args[4]),
    );
    ret_undefined(env)
}

unsafe extern "C" fn js_shutdown(env: napi_env, _info: napi_callback_info) -> napi_value {
    shutdown();
    ret_undefined(env)
}

fn register(env: napi_env, exports: napi_value, name: &str, f: unsafe extern "C" fn(napi_env, napi_callback_info) -> napi_value) {
    unsafe {
        // napi_create_function 也在最小集之外?不,它是基础;但为再省一个符号,
        // 这里用函数指针包装:直接 create_function 仍是最常见路径,保留它。
        let mut fn_val: napi_value = ptr::null_mut();
        extern "C" {
            fn napi_create_function(env: napi_env, name: *const c_char, len: usize, cb: Option<unsafe extern "C" fn(napi_env, napi_callback_info) -> napi_value>, data: *mut c_void, result: *mut napi_value) -> u32;
        }
        let cname = CString::new(name).unwrap();
        let st = napi_create_function(env, cname.as_ptr(), name.len(), Some(f), ptr::null_mut(), &mut fn_val);
        if st != 0 || fn_val.is_null() {
            return;
        }
        napi_set_named_property(env, exports, cname.as_ptr(), fn_val);
    }
}

#[no_mangle]
pub unsafe extern "C" fn napi_register_module_v1(env: napi_env, exports: napi_value) -> napi_value {
    module_init(env, exports)
}

unsafe extern "C" fn module_init(env: napi_env, exports: napi_value) -> napi_value {
    register(env, exports, "fqVersion", js_version);
    register(env, exports, "fqStatus", js_status);
    register(env, exports, "fqLastError", js_last_error);
    register(env, exports, "fqBaseUrl", js_base_url);
    register(env, exports, "fqCapability", js_capability);
    register(env, exports, "fqInitStart", js_init_start);
    register(env, exports, "fqShutdown", js_shutdown);
    exports
}

// ---------- 鸿蒙原生注册链:napi_module_register + .init_array constructor ----------
// ArkCompiler 通过模块名(libfqapi_ohos.so → "fqapi_ohos")在注册表里找 Init 函数,
// 不走 Node 的 napi_register_module_v1 自动发现。

#[repr(C)]
struct NapiModule {
    nm_version: i32,
    nm_flags: u32,
    nm_filename: *const c_char,
    nm_register_func: Option<unsafe extern "C" fn(napi_env, napi_value) -> napi_value>,
    nm_modname: *const c_char,
    nm_priv: *mut c_void,
    reserved: [*mut c_void; 4],
}

unsafe extern "C" {
    fn napi_module_register(module: *mut NapiModule);
}

unsafe impl Sync for NapiModule {}

static MODULE: NapiModule = NapiModule {
    nm_version: 1,
    nm_flags: 0,
    nm_filename: ptr::null(),
    nm_register_func: Some(module_init),
    nm_modname: b"fqapi_ohos\0".as_ptr() as *const c_char,
    nm_priv: ptr::null_mut(),
    reserved: [ptr::null_mut(); 4],
};

extern "C" fn register_module_ctor() {
    unsafe {
        napi_module_register(&MODULE as *const NapiModule as *mut NapiModule);
    }
}

#[used]
#[link_section = ".init_array"]
static CTOR: extern "C" fn() = register_module_ctor;
