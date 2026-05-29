// allstak_crash.c — Async-signal-safe NDK crash capture for AllStak Flutter.
//
// The Kotlin AllStakPlugin only installs Thread.setDefaultUncaughtExceptionHandler,
// which catches uncaught JVM Throwables but NEVER native/NDK signal crashes
// (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP). Those are the dominant class of
// hard Android crashes from native code. This file installs sigaction handlers
// for them, mirroring the iOS plugin + the sibling allstak-apple SignalCrashHandler.
//
// THE HANDLER RUNS INSIDE A DYING PROCESS. It is allowed to call ONLY
// async-signal-safe functions (man 7 signal-safety). It therefore:
//   * touches NO heap (no malloc, no JNI, no Kotlin, no Java) — JNI calls from a
//     signal handler are explicitly unsafe;
//   * uses ONLY pre-allocated buffers + a pre-opened file descriptor (set up in
//     allstak_install_signal_handlers(), in normal context, from JNI);
//   * formats a tiny fixed ASCII "ASKC1" record into a fixed byte buffer and emits
//     it with a single write(2);
//   * guards re-entrancy with a sig_atomic_t flag, restores the previous
//     disposition, and re-raises so the OS / debuggerd still produces its report.
//
// The record is read back on the NEXT launch (normal context) on the Dart side
// (see lib/src/native_crash.dart) and shipped to /ingest/v1/errors.

#include <jni.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <stdint.h>
#include <string.h>

#if defined(__ANDROID__)
#include <android/log.h>
#endif

// unwind.h ships with the NDK and its _Unwind_Backtrace is async-signal-safe
// (it walks the stack without allocating). We use it instead of execinfo's
// backtrace() (not available on Android).
#include <unwind.h>

#define ALLSTAK_MAX_FRAMES 128
#define ALLSTAK_RECORD_CAPACITY 8192

// Signals we intercept, in install order (parallel to g_prev_actions).
static const int g_allstak_signals[] = {
    SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
static const int g_allstak_signal_count =
    (int)(sizeof(g_allstak_signals) / sizeof(g_allstak_signals[0]));

// Pre-allocated, file-scope state the handler reaches (a C signal handler
// cannot capture context). All of it is set up in normal context at install.
static struct sigaction g_prev_actions[6]; // sized to g_allstak_signal_count
static int g_installed_count = 0;
static int g_signal_fd = -1;                 // pre-opened crash file fd
static char g_record_buf[ALLSTAK_RECORD_CAPACITY]; // pre-allocated scratch
static volatile sig_atomic_t g_in_handler = 0;
static stack_t g_alt_stack;                  // alternate signal stack
static char g_alt_stack_mem[SIGSTKSZ > 65536 ? SIGSTKSZ : 65536];

// ── Async-signal-safe formatting (no allocation, no libc string formatting) ──

// Append a fixed literal. Returns the new offset (bounded by capacity).
static int allstak_append_literal(const char *s, char *buf, int off, int cap) {
  while (*s) {
    if (off >= cap) return off;
    buf[off++] = *s++;
  }
  return off;
}

// Append lowercase hex of `value` (no "0x"). Returns the new offset.
static int allstak_append_hex(uint64_t value, char *buf, int off, int cap) {
  static const char digits[] = "0123456789abcdef";
  if (value == 0) {
    if (off >= cap) return off;
    buf[off++] = digits[0];
    return off;
  }
  int n = 0;
  uint64_t v = value;
  while (v != 0) { n++; v >>= 4; }
  if (off + n > cap) return off;
  v = value;
  int i = off + n - 1;
  while (v != 0) {
    buf[i--] = digits[v & 0xF];
    v >>= 4;
  }
  return off + n;
}

// Append decimal of a non-negative `value`. Returns the new offset.
static int allstak_append_dec(int64_t value, char *buf, int off, int cap) {
  static const char digits[] = "0123456789";
  if (value <= 0) {
    if (off >= cap) return off;
    buf[off++] = digits[0];
    return off;
  }
  int n = 0;
  int64_t v = value;
  while (v != 0) { n++; v /= 10; }
  if (off + n > cap) return off;
  v = value;
  int i = off + n - 1;
  while (v != 0) {
    buf[i--] = digits[v % 10];
    v /= 10;
  }
  return off + n;
}

// ── Async-signal-safe stack unwind via libunwind's _Unwind_Backtrace ──

typedef struct {
  uintptr_t frames[ALLSTAK_MAX_FRAMES];
  int count;
} allstak_backtrace_state;

static _Unwind_Reason_Code allstak_unwind_cb(struct _Unwind_Context *ctx,
                                             void *arg) {
  allstak_backtrace_state *state = (allstak_backtrace_state *)arg;
  uintptr_t pc = _Unwind_GetIP(ctx);
  if (pc != 0) {
    if (state->count >= ALLSTAK_MAX_FRAMES) return _URC_END_OF_STACK;
    state->frames[state->count++] = pc;
  }
  return _URC_NO_REASON;
}

// ── The handler (async-signal-safe) ──

static void allstak_chain_previous(int signum) {
  // Restore the previously-installed action for this signal (or SIG_DFL) and
  // re-raise. Only fixed-buffer reads + sigaction/raise — all safe.
  int restored = 0;
  for (int i = 0; i < g_installed_count; i++) {
    if (g_allstak_signals[i] == signum) {
      sigaction(signum, &g_prev_actions[i], NULL);
      restored = 1;
      break;
    }
  }
  if (!restored) {
    struct sigaction def;
    memset(&def, 0, sizeof(def));
    def.sa_handler = SIG_DFL;
    sigemptyset(&def.sa_mask);
    def.sa_flags = 0;
    sigaction(signum, &def, NULL);
  }
  raise(signum);
}

static void allstak_signal_handler(int signum, siginfo_t *info, void *ucontext) {
  (void)ucontext;
  if (g_in_handler != 0) {
    allstak_chain_previous(signum);
    return;
  }
  g_in_handler = 1;

  if (g_signal_fd >= 0) {
    int off = 0;
    off = allstak_append_literal("ASKC1\nplat=android\nsig=", g_record_buf, off,
                                 ALLSTAK_RECORD_CAPACITY);
    off = allstak_append_dec((int64_t)signum, g_record_buf, off,
                             ALLSTAK_RECORD_CAPACITY);
    off = allstak_append_literal("\naddr=", g_record_buf, off,
                                 ALLSTAK_RECORD_CAPACITY);
    uint64_t fault = 0;
    if (info != NULL) {
      fault = (uint64_t)(uintptr_t)info->si_addr;
    }
    off = allstak_append_hex(fault, g_record_buf, off, ALLSTAK_RECORD_CAPACITY);
    off = allstak_append_literal("\ntime=", g_record_buf, off,
                                 ALLSTAK_RECORD_CAPACITY);
    off = allstak_append_dec((int64_t)time(NULL), g_record_buf, off,
                             ALLSTAK_RECORD_CAPACITY);
    off = allstak_append_literal("\n", g_record_buf, off,
                                 ALLSTAK_RECORD_CAPACITY);

    allstak_backtrace_state state;
    state.count = 0;
    _Unwind_Backtrace(allstak_unwind_cb, &state);
    for (int i = 0; i < state.count; i++) {
      off = allstak_append_literal("frame=", g_record_buf, off,
                                   ALLSTAK_RECORD_CAPACITY);
      off = allstak_append_hex((uint64_t)state.frames[i], g_record_buf, off,
                               ALLSTAK_RECORD_CAPACITY);
      off = allstak_append_literal("\n", g_record_buf, off,
                                   ALLSTAK_RECORD_CAPACITY);
    }

    // Single write of the whole record; write()/fsync() are async-signal-safe.
    ssize_t w = write(g_signal_fd, g_record_buf, (size_t)off);
    (void)w;
    fsync(g_signal_fd);
  }

  allstak_chain_previous(signum);
}

// ── Install (normal context, called from JNI) ──

// Returns 1 on success (at least one handler armed + file opened), 0 otherwise.
static int allstak_install_signal_handlers(const char *path) {
  if (path == NULL) return 0;

  // Pre-open the crash file. open() is NOT async-signal-safe, so do it here.
  if (g_signal_fd < 0) {
    g_signal_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (g_signal_fd < 0) return 0;
  }

  // Alternate signal stack (a faulting stack may be unusable, e.g. overflow).
  if (g_alt_stack.ss_sp == NULL) {
    g_alt_stack.ss_sp = g_alt_stack_mem;
    g_alt_stack.ss_size = sizeof(g_alt_stack_mem);
    g_alt_stack.ss_flags = 0;
    sigaltstack(&g_alt_stack, NULL);
  }

  if (g_installed_count > 0) return 1; // already armed

  int installed = 0;
  for (int i = 0; i < g_allstak_signal_count; i++) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = allstak_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    struct sigaction old;
    memset(&old, 0, sizeof(old));
    if (sigaction(g_allstak_signals[i], &action, &old) == 0) {
      g_prev_actions[installed] = old;
      installed++;
    }
  }
  g_installed_count = installed;
  return installed > 0 ? 1 : 0;
}

// ── JNI bridge ──
//
// Installs the handlers. Reads the crash-file path passed from Kotlin (the
// app's filesDir + filename). Returns true on success. Called in NORMAL
// context at app start — never from a signal handler.

JNIEXPORT jboolean JNICALL
Java_io_allstak_flutter_AllStakPlugin_nativeInstallSignalHandlers(
    JNIEnv *env, jclass clazz, jstring jpath) {
  (void)clazz;
  if (jpath == NULL) return JNI_FALSE;
  const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
  if (path == NULL) return JNI_FALSE;
  int ok = allstak_install_signal_handlers(path);
  (*env)->ReleaseStringUTFChars(env, jpath, path);
#if defined(__ANDROID__)
  if (ok) {
    __android_log_print(ANDROID_LOG_INFO, "AllStak",
                        "native signal handlers armed");
  }
#endif
  return ok ? JNI_TRUE : JNI_FALSE;
}
