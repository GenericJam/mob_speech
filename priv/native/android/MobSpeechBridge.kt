// mob_speech plugin — Android bridge (android.speech.SpeechRecognizer).
//
// MobPluginBootstrap.registerAll() calls register() at startup, hands it the
// Activity (MobActivityAware) and records it as a permission provider
// (MobPermissionProvider: :speech -> RECORD_AUDIO, so core's
// MobBridge.request_permission routes Mob.Permissions.request(socket, :speech)
// here).
//
// The bridge forwards RAW recogniser events to the session pid; it decides
// nothing about reasons or fallbacks. MobSpeech.Session (Elixir) maps error
// codes (MobSpeech.Reason), substitutes the last partial for an empty final,
// runs the stop watchdog and guarantees the single idle.
//
// Threading: SpeechRecognizer must be created and driven on the main thread,
// and its listener is called there too. Every entry point posts to the main
// looper, and activePid is only read/written on it.
//
// The native thunks (nativeRegister + nativeDeliver*) are exported from the
// sibling zig NIF mob_speech_nif.zig.
package io.mob.speech

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import java.lang.ref.WeakReference

object MobSpeechBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    private var activityRef: WeakReference<Activity>? = null
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null

    // The session whose recognition is running natively; 0 = none. Main thread only.
    private var activePid: Long = 0

    // When the last recogniser was released (uptimeMillis); see start().
    private var lastReleaseAt: Long = 0
    private const val SETTLE_MS = 400L

    // nativeDeliverState codes.
    private const val STATE_LISTENING = 0
    private const val STATE_IDLE = 1

    // Bridge pre-check error codes (negative so they never collide with
    // SpeechRecognizer.ERROR_*); MobSpeech.Reason maps them.
    private const val ERR_NO_PERMISSION = -1
    private const val ERR_NO_RECOGNIZER = -2
    private const val ERR_NO_CONTEXT = -3

    // speech_available() codes, read by nif_speech_available in
    // mob_speech_nif.zig. 0 is reserved: it is what JNI yields when the call threw.
    private const val AVAIL_NO = 1
    private const val AVAIL_YES = 2
    private const val AVAIL_NO_ACTIVITY = 3

    @JvmStatic external fun nativeRegister()

    // {:speech, :state, :listening | :idle}
    @JvmStatic external fun nativeDeliverState(pid: Long, state: Int)

    // {:speech, :partial | :final, text}; text is UTF-8 bytes (JNI's
    // modified-UTF-8 strings would mangle characters outside the BMP).
    @JvmStatic external fun nativeDeliverText(pid: Long, isFinal: Boolean, text: ByteArray)

    // {:speech, :error, {:android, code, appHasMic}}
    @JvmStatic external fun nativeDeliverError(pid: Long, code: Int, appHasMic: Boolean)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    override fun permissionsFor(cap: String): Array<String>? =
        if (cap == "speech") arrayOf(Manifest.permission.RECORD_AUDIO) else null

    private fun context(): Context? = activityRef?.get()

    private fun hasMic(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    @JvmStatic
    fun speech_available(): Int {
        val ctx = context() ?: return AVAIL_NO_ACTIVITY
        return if (SpeechRecognizer.isRecognitionAvailable(ctx)) AVAIL_YES else AVAIL_NO
    }

    @JvmStatic
    fun speech_start(pid: Long, language: String, preferOffline: Boolean, partialResults: Boolean, silenceMs: Int) {
        val opts = StartOptions(language, preferOffline, partialResults, silenceMs)
        main.post { start(pid, opts) }
    }

    private class StartOptions(
        val language: String,
        val preferOffline: Boolean,
        val partialResults: Boolean,
        // End-of-utterance silence; 0 = the recogniser's default.
        val silenceMs: Int,
    )

    @JvmStatic
    fun speech_stop(pid: Long) {
        main.post {
            if (pid != activePid) return@post
            val r = recognizer
            if (r != null) {
                r.stopListening()
            } else {
                // Stopped while the start was still waiting out SETTLE_MS:
                // nothing was recorded.
                activePid = 0
                nativeDeliverError(pid, SpeechRecognizer.ERROR_NO_MATCH, true)
            }
        }
    }

    @JvmStatic
    fun speech_cancel(pid: Long) {
        main.post {
            if (pid == activePid) {
                activePid = 0
                destroyRecognizer()
            }
        }
    }

    private fun start(pid: Long, opts: StartOptions) {
        val ctx = context() ?: return nativeDeliverError(pid, ERR_NO_CONTEXT, false)
        if (!hasMic(ctx)) return nativeDeliverError(pid, ERR_NO_PERMISSION, false)
        if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
            return nativeDeliverError(pid, ERR_NO_RECOGNIZER, true)
        }

        // One recognition at a time: a new session preempts the running one,
        // whose session gets an idle (same as a cancel).
        val previous = activePid
        activePid = 0
        if (previous != 0L) nativeDeliverState(previous, STATE_IDLE)

        // A fresh recogniser per session: reusing one right after cancel()
        // made the next startListening fail with ERROR_CLIENT. And the Google
        // service tears the old client down asynchronously: a new session
        // started within ~0.3 s of a release fails with ERROR_SERVER ("Client
        // has existing session"; API 35 emulator). So wait out SETTLE_MS since
        // the last release. The session is active (cancellable) meanwhile.
        destroyRecognizer()
        activePid = pid
        val wait = lastReleaseAt + SETTLE_MS - SystemClock.uptimeMillis()
        val launch = Runnable { if (activePid == pid) begin(ctx, pid, opts) }
        if (wait > 0) main.postDelayed(launch, wait) else launch.run()
    }

    private fun begin(ctx: Context, pid: Long, opts: StartOptions) {
        val r = SpeechRecognizer.createSpeechRecognizer(ctx).also { recognizer = it }
        r.setRecognitionListener(Listener(pid, ctx))
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, opts.partialResults)
            // Never true unless asked: a device without the on-device pack for
            // the locale fails at once with ERROR_LANGUAGE_UNAVAILABLE.
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, opts.preferOffline)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, ctx.packageName)
            if (opts.language.isNotEmpty()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, opts.language)
            // Hold-to-talk: a pause while the button is held mustn't end the
            // recognition. Some recogniser versions ignore these.
            if (opts.silenceMs > 0) {
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, opts.silenceMs.toLong())
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                    opts.silenceMs.toLong(),
                )
            }
        }
        r.startListening(intent)
    }

    private fun destroyRecognizer() {
        val r = recognizer ?: return
        recognizer = null
        r.cancel()
        r.destroy()
        lastReleaseAt = SystemClock.uptimeMillis()
    }

    private fun firstResult(bundle: Bundle?): String =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    /** Bound to one session: events for a session that is no longer active are dropped. */
    private class Listener(private val pid: Long, private val ctx: Context) : RecognitionListener {
        private fun current() = pid == activePid

        override fun onReadyForSpeech(params: Bundle?) {
            if (current()) nativeDeliverState(pid, STATE_LISTENING)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (!current()) return
            val text = firstResult(partialResults)
            if (text.isNotEmpty()) nativeDeliverText(pid, false, text.toByteArray(Charsets.UTF_8))
        }

        override fun onResults(results: Bundle?) {
            if (!current()) return
            activePid = 0
            // May be empty (the Google recogniser often ends that way after
            // streaming partials); the session substitutes the last partial.
            nativeDeliverText(pid, true, firstResult(results).toByteArray(Charsets.UTF_8))
            releaseWhenIdle()
        }

        override fun onError(error: Int) {
            if (!current()) return
            activePid = 0
            nativeDeliverError(pid, error, hasMic(ctx))
            releaseWhenIdle()
        }

        // Destroy outside the callback, unless a new session already took over.
        private fun releaseWhenIdle() {
            main.post { if (activePid == 0L) destroyRecognizer() }
        }

        // The recogniser's own end-of-speech is NOT :processing: during
        // hold-to-talk the button is still held. The session emits
        // :processing when the app calls stop.
        override fun onEndOfSpeech() {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}
