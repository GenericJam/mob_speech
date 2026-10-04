//! mob_speech_nif — Android speech-to-text tier-1 ZIG plugin NIF.
//!
//! The Kotlin side is the plugin-owned bridge class
//! `io.mob.speech.MobSpeechBridge` (android.speech.SpeechRecognizer). The NIFs
//! hand the session pid to the bridge; the bridge's recogniser callbacks come
//! back through the exported `nativeDeliver*` thunks, which send RAW events to
//! that pid:
//!
//!   nativeDeliverState(pid, 0|1)          -> {:speech, :state, :listening | :idle}
//!   nativeDeliverText(pid, final, bytes)  -> {:speech, :partial | :final, binary}
//!   nativeDeliverError(pid, code, hasMic) -> {:speech, :error, {:android, code, bool}}
//!
//! Reason mapping, the last-partial fallback, the stop watchdog and the single
//! idle all live in Elixir (MobSpeech.Session / MobSpeech.Reason).
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const SpeechMethods = struct {
    start: jni.JMethodID = null,
    stop: jni.JMethodID = null,
    cancel: jni.JMethodID = null,
    available: jni.JMethodID = null,
};

var g_speech: SpeechMethods = .{};
var g_speech_cls: jni.JClass = null;

// A missing method leaves a `NoSuchMethodError` pending on the JNIEnv; clear
// it so later lookups aren't shadowed by a stale pending exception.
inline fn cacheMethod(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    name: [*:0]const u8,
    sig: [*:0]const u8,
) jni.JMethodID {
    const m = jni.getStaticMethodID(jenv, cls, name, sig);
    if (m == null) jni.exceptionClear(jenv);
    return m;
}

export fn Java_io_mob_speech_MobSpeechBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_speech_cls = jni.newGlobalRef(jenv, cls);
    if (g_speech_cls == null) return;
    g_speech.start = cacheMethod(jenv, cls, "speech_start", "(JLjava/lang/String;ZZI)V");
    g_speech.stop = cacheMethod(jenv, cls, "speech_stop", "(J)V");
    g_speech.cancel = cacheMethod(jenv, cls, "speech_cancel", "(J)V");
    g_speech.available = cacheMethod(jenv, cls, "speech_available", "()Z");
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core) ──────────────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

// ── Inbound delivery thunks ───────────────────────────────────────────────
fn sendTo(pid_long: jni.JLong, env: *erts.ErlNifEnv, msg: erts.ERL_NIF_TERM) void {
    var pid = pidFromLong(pid_long);
    _ = erts.enif_send(null, &pid, env, msg);
}

export fn Java_io_mob_speech_MobSpeechBridge_nativeDeliverState(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, state: jni.JInt) callconv(.c) void {
    _ = jenv;
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const st = if (state == 0) erts.atom(env, "listening") else erts.atom(env, "idle");
    sendTo(pid_long, env, erts.makeTuple(env, .{ erts.atom(env, "speech"), erts.atom(env, "state"), st }));
}

export fn Java_io_mob_speech_MobSpeechBridge_nativeDeliverText(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, is_final: jni.JBoolean, text: jni.JByteArray) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const len: usize = if (text == null) 0 else @intCast(jni.getArrayLength(jenv, text));
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(len, &bin) == 0) return;
    if (len > 0) jni.getByteArrayRegion(jenv, text, 0, @intCast(len), @ptrCast(bin.data));
    const kind = if (is_final != 0) erts.atom(env, "final") else erts.atom(env, "partial");
    sendTo(pid_long, env, erts.makeTuple(env, .{ erts.atom(env, "speech"), kind, erts.enif_make_binary(env, &bin) }));
}

export fn Java_io_mob_speech_MobSpeechBridge_nativeDeliverError(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, code: jni.JInt, app_has_mic: jni.JBoolean) callconv(.c) void {
    _ = jenv;
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const has_mic = if (app_has_mic != 0) erts.atom(env, "true") else erts.atom(env, "false");
    const raw = erts.makeTuple(env, .{ erts.atom(env, "android"), erts.enif_make_int(env, code), has_mic });
    sendTo(pid_long, env, erts.makeTuple(env, .{ erts.atom(env, "speech"), erts.atom(env, "error"), raw }));
}

// ── NIFs ──────────────────────────────────────────────────────────────────

// A boolean atom as a JNI vararg: jboolean is promoted to int through `...`.
fn boolArg(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM) ?c_int {
    var buf: [8]u8 = @splat(0);
    if (erts.enif_get_atom(env, term, &buf, buf.len, erts.ERL_NIF_LATIN1) == 0) return null;
    const name = std.mem.sliceTo(&buf, 0);
    if (std.mem.eql(u8, name, "true")) return 1;
    if (std.mem.eql(u8, name, "false")) return 0;
    return null;
}

fn pidArg(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM) ?erts.ErlNifPid {
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_get_local_pid(env, term, &pid) == 0) return null;
    return pid;
}

/// Call a `(J)V` bridge method with the session pid. Async on the Kotlin side.
fn callPidOnly(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid) erts.ERL_NIF_TERM {
    if (g_speech_cls == null or method == null) return erts.ok(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.ok(env);
    jenv.*.CallStaticVoidMethod.?(jenv, g_speech_cls, method, pidToJlong(pid));
    jni.exceptionClear(jenv);
    detachIfAttached(attached);
    return erts.ok(env);
}

// speech_start(Pid, Language :: binary, PreferOffline :: boolean, Partial :: boolean,
//              SilenceMs :: non_neg_integer)
fn nif_speech_start(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const pid = pidArg(env, argv[0]) orelse return erts.badarg(env);
    var lang_bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[1], &lang_bin) == 0) return erts.badarg(env);
    const offline = boolArg(env, argv[2]) orelse return erts.badarg(env);
    const partial = boolArg(env, argv[3]) orelse return erts.badarg(env);
    var silence_ms: c_int = 0;
    if (erts.enif_get_int(env, argv[4], &silence_ms) == 0 or silence_ms < 0) return erts.badarg(env);

    var lang_buf: [64]u8 = @splat(0);
    if (lang_bin.size >= lang_buf.len) return erts.badarg(env);
    @memcpy(lang_buf[0..lang_bin.size], lang_bin.data[0..lang_bin.size]);

    if (g_speech_cls == null or g_speech.start == null) {
        return erts.errorTuple(env, erts.atom(env, "unavailable"));
    }
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.errorTuple(env, erts.atom(env, "unavailable"));
    const jlang = jni.newStringUTF(jenv, jni.asCStr(&lang_buf));
    jenv.*.CallStaticVoidMethod.?(jenv, g_speech_cls, g_speech.start, pidToJlong(pid), jlang, offline, partial, silence_ms);
    jni.exceptionClear(jenv);
    if (jlang != null) jni.deleteLocalRef(jenv, jlang);
    detachIfAttached(attached);
    return erts.ok(env);
}

fn nif_speech_stop(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const pid = pidArg(env, argv[0]) orelse return erts.badarg(env);
    return callPidOnly(env, g_speech.stop, pid);
}

fn nif_speech_cancel(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const pid = pidArg(env, argv[0]) orelse return erts.badarg(env);
    return callPidOnly(env, g_speech.cancel, pid);
}

fn nif_speech_available(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_speech_cls == null or g_speech.available == null) return erts.atom(env, "false");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "false");
    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, g_speech_cls, g_speech.available);
    jni.exceptionClear(jenv);
    detachIfAttached(attached);
    return if (ok != 0) erts.atom(env, "true") else erts.atom(env, "false");
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "speech_start", .arity = 5, .fptr = nif_speech_start, .flags = 0 },
    .{ .name = "speech_stop", .arity = 1, .fptr = nif_speech_stop, .flags = 0 },
    .{ .name = "speech_cancel", .arity = 1, .fptr = nif_speech_cancel, .flags = 0 },
    .{ .name = "speech_available", .arity = 0, .fptr = nif_speech_available, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_speech_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_speech_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
