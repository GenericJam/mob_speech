/* mob_speech_nif — iOS speech-to-text plugin NIF (Objective-C).
 *
 * SFSpeechRecognizer fed by an AVAudioEngine input tap through an
 * SFSpeechAudioBufferRecognitionRequest. Registered as the Erlang module
 * mob_speech_nif via ERL_NIF_INIT; compiled as ObjC (-fobjc-arc) by the plugin
 * C-NIF path because the manifest entry is lang: :objc.
 *
 * Raw events go to the session pid passed to speech_start/5 (see
 * MobSpeech.Engine):
 *   {speech, state, listening | idle}
 *   {speech, partial | final, Binary}
 *   {speech, error, {ios, DomainBinary, Code}}   an NSError from Speech/AVFAudio
 *   {speech, error, <<"permission">> | <<"language">> | <<"unavailable">> | <<"audio">>}
 * Reason mapping, the last-partial fallback, the stop watchdog and the single
 * idle live in Elixir (MobSpeech.Session / MobSpeech.Reason).
 *
 * All recogniser state is touched only on the main queue. g_session is bumped
 * per start, so a result handler from an older task can't act on a newer one.
 *
 * The NIF's load callback registers the :speech permission handler with core's
 * runtime permission registry (mob_register_permission_handler, exported by
 * core's ios/mob_nif.m), so Mob.Permissions.request(socket, :speech) asks for
 * speech-recognition authorisation AND the microphone, and reports
 * {permission, speech, granted} only when both are granted.
 */
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <Speech/Speech.h>
#include <erl_nif.h>
#include <string.h>

/* Defined in core mob's ios/mob_nif.m, linked into the same static binary. */
extern void mob_register_permission_handler(const char *cap, void (*fn)(ErlNifPid));

// ── delivery (raw enif; core's mob_send* helpers are private) ────────────
static ERL_NIF_TERM make_bin(ErlNifEnv *env, const char *bytes, size_t len) {
    ERL_NIF_TERM term;
    unsigned char *dst = enif_make_new_binary(env, len, &term);
    if (len > 0)
        memcpy(dst, bytes, len);
    return term;
}

static ERL_NIF_TERM make_nsstring(ErlNifEnv *env, NSString *s) {
    const char *utf8 = s ? s.UTF8String : "";
    return make_bin(env, utf8, strlen(utf8));
}

static void send_speech(ErlNifPid pid, ERL_NIF_TERM (^build)(ErlNifEnv *env)) {
    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM msg = build(env);
    enif_send(NULL, &pid, env, msg);
    enif_free_env(env);
}

static void send_state(ErlNifPid pid, const char *state) {
    send_speech(pid, ^ERL_NIF_TERM(ErlNifEnv *env) {
      return enif_make_tuple3(env, enif_make_atom(env, "speech"), enif_make_atom(env, "state"),
                              enif_make_atom(env, state));
    });
}

static void send_text(ErlNifPid pid, const char *kind, NSString *text) {
    send_speech(pid, ^ERL_NIF_TERM(ErlNifEnv *env) {
      return enif_make_tuple3(env, enif_make_atom(env, "speech"), enif_make_atom(env, kind),
                              make_nsstring(env, text));
    });
}

static void send_error_tag(ErlNifPid pid, const char *tag) {
    send_speech(pid, ^ERL_NIF_TERM(ErlNifEnv *env) {
      return enif_make_tuple3(env, enif_make_atom(env, "speech"), enif_make_atom(env, "error"),
                              make_bin(env, tag, strlen(tag)));
    });
}

static void send_error_ns(ErlNifPid pid, NSError *err, const char *fallback_tag) {
    if (!err) {
        send_error_tag(pid, fallback_tag);
        return;
    }
    NSString *domain = err.domain;
    long code = (long)err.code;
    send_speech(pid, ^ERL_NIF_TERM(ErlNifEnv *env) {
      ERL_NIF_TERM raw = enif_make_tuple3(env, enif_make_atom(env, "ios"),
                                          make_nsstring(env, domain), enif_make_long(env, code));
      return enif_make_tuple3(env, enif_make_atom(env, "speech"), enif_make_atom(env, "error"),
                              raw);
    });
}

static void send_permission(ErlNifPid pid, BOOL granted) {
    send_speech(pid, ^ERL_NIF_TERM(ErlNifEnv *env) {
      return enif_make_tuple3(env, enif_make_atom(env, "permission"), enif_make_atom(env, "speech"),
                              enif_make_atom(env, granted ? "granted" : "denied"));
    });
}

// ── :speech permission (speech recognition + microphone) ──────────────────
// Mob's iOS floor is 17.0, so AVAudioApplication (17+) is always there.
static BOOL mic_granted(void) {
    return [AVAudioApplication sharedInstance].recordPermission ==
           AVAudioApplicationRecordPermissionGranted;
}

static void request_mic(void (^done)(BOOL granted)) {
    [AVAudioApplication requestRecordPermissionWithCompletionHandler:done];
}

static void mob_speech_request_permission(ErlNifPid pid) {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
      if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
          send_permission(pid, NO);
          return;
      }
      request_mic(^(BOOL granted) {
        send_permission(pid, granted);
      });
    }];
}

// ── recogniser state (main queue only) ────────────────────────────────────
static SFSpeechRecognizer *g_recognizer = nil;
static AVAudioEngine *g_engine = nil;
static SFSpeechAudioBufferRecognitionRequest *g_request = nil;
static SFSpeechRecognitionTask *g_task = nil;
static ErlNifPid g_pid;
static BOOL g_active = NO;
static unsigned long long g_session = 0;

static BOOL is_current(ErlNifPid pid) {
    return g_active && enif_compare_pids(&pid, &g_pid) == 0;
}

static void stop_audio(void) {
    if (g_engine) {
        [g_engine stop];
        [g_engine.inputNode removeTapOnBus:0];
        g_engine = nil;
    }
    [g_request endAudio];
}

static void teardown(void) {
    stop_audio();
    g_request = nil;
    g_task = nil;
    g_recognizer = nil;
    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];
}

static void start_on_main(ErlNifPid pid, NSString *lang, BOOL prefer_offline, BOOL partial) {
    // One recognition at a time: a new session preempts the running one, whose
    // screen gets a bare idle (same as a cancel).
    if (g_active) {
        ErlNifPid old = g_pid;
        g_active = NO;
        [g_task cancel];
        teardown();
        send_state(old, "idle");
    }

    if ([SFSpeechRecognizer authorizationStatus] !=
            SFSpeechRecognizerAuthorizationStatusAuthorized ||
        !mic_granted()) {
        send_error_tag(pid, "permission");
        return;
    }

    NSLocale *locale =
        lang.length > 0 ? [NSLocale localeWithLocaleIdentifier:lang] : [NSLocale currentLocale];
    SFSpeechRecognizer *rec = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!rec) {
        send_error_tag(pid, "language");
        return;
    }
    if (!rec.isAvailable) {
        send_error_tag(pid, "unavailable");
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeMeasurement
                      options:AVAudioSessionCategoryOptionDuckOthers |
                              AVAudioSessionCategoryOptionDefaultToSpeaker
                        error:&err] ||
        ![session setActive:YES
                withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                      error:&err]) {
        send_error_ns(pid, err, "audio");
        return;
    }

    SFSpeechAudioBufferRecognitionRequest *req =
        [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    req.shouldReportPartialResults = partial;
    // On-device only when asked AND supported: a missing on-device model would
    // otherwise fail every request.
    if (prefer_offline && rec.supportsOnDeviceRecognition)
        req.requiresOnDeviceRecognition = YES;

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0 || format.channelCount == 0) {
        // No usable input route (e.g. a simulator without a microphone).
        [session setActive:NO
               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                     error:nil];
        send_error_tag(pid, "audio");
        return;
    }
    [input installTapOnBus:0
                bufferSize:1024
                    format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                       [req appendAudioPCMBuffer:buffer];
                     }];
    [engine prepare];
    if (![engine startAndReturnError:&err]) {
        [input removeTapOnBus:0];
        [session setActive:NO
               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                     error:nil];
        send_error_ns(pid, err, "audio");
        return;
    }

    unsigned long long mine = ++g_session;
    g_recognizer = rec;
    g_engine = engine;
    g_request = req;
    g_pid = pid;
    g_active = YES;
    g_task = [rec recognitionTaskWithRequest:req
                               resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                                 NSString *text =
                                     result ? result.bestTranscription.formattedString : nil;
                                 BOOL final = result != nil && result.isFinal;
                                 dispatch_async(dispatch_get_main_queue(), ^{
                                   if (!g_active || g_session != mine)
                                       return;
                                   if (final) {
                                       // May be empty; the session substitutes the last partial.
                                       g_active = NO;
                                       teardown();
                                       send_text(pid, "final", text);
                                   } else if (error) {
                                       g_active = NO;
                                       teardown();
                                       send_error_ns(pid, error, "client");
                                   } else if (text.length > 0) {
                                       send_text(pid, "partial", text);
                                   }
                                 });
                               }];
    send_state(pid, "listening");
}

// ── NIF argument helpers ──────────────────────────────────────────────────
static int get_bool(ErlNifEnv *env, ERL_NIF_TERM term, BOOL *out) {
    char buf[8];
    if (!enif_get_atom(env, term, buf, sizeof(buf), ERL_NIF_LATIN1))
        return 0;
    if (strcmp(buf, "true") == 0) {
        *out = YES;
        return 1;
    }
    if (strcmp(buf, "false") == 0) {
        *out = NO;
        return 1;
    }
    return 0;
}

// ── NIFs ──────────────────────────────────────────────────────────────────
// speech_start(Pid, Language, PreferOffline, PartialResults, SilenceMs). SilenceMs
// is Android-only (SFSpeechAudioBufferRecognitionRequest has no end-of-utterance
// silence setting); it is validated and ignored here.
static ERL_NIF_TERM nif_speech_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid pid;
    ErlNifBinary lang_bin;
    BOOL offline, partial;
    int silence_ms;
    if (!enif_get_local_pid(env, argv[0], &pid) || !enif_inspect_binary(env, argv[1], &lang_bin) ||
        !get_bool(env, argv[2], &offline) || !get_bool(env, argv[3], &partial) ||
        !enif_get_int(env, argv[4], &silence_ms) || silence_ms < 0)
        return enif_make_badarg(env);
    NSString *lang = [[NSString alloc] initWithBytes:lang_bin.data
                                              length:lang_bin.size
                                            encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      start_on_main(pid, lang ?: @"", offline, partial);
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_speech_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid))
        return enif_make_badarg(env);
    dispatch_async(dispatch_get_main_queue(), ^{
      // Stop capturing; the task then delivers its final (or an error).
      if (is_current(pid))
          stop_audio();
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_speech_cancel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid))
        return enif_make_badarg(env);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (is_current(pid)) {
          g_active = NO;
          [g_task cancel];
          teardown();
      }
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_speech_available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    SFSpeechRecognizer *rec = [[SFSpeechRecognizer alloc] init];
    return enif_make_atom(env, (rec && rec.isAvailable) ? "true" : "false");
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)env;
    (void)priv_data;
    (void)load_info;
    mob_register_permission_handler("speech", mob_speech_request_permission);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"speech_start", 5, nif_speech_start, 0},
    {"speech_stop", 1, nif_speech_stop, 0},
    {"speech_cancel", 1, nif_speech_cancel, 0},
    {"speech_available", 0, nif_speech_available, 0},
};

ERL_NIF_INIT(mob_speech_nif, nif_funcs, load, NULL, NULL, NULL)
