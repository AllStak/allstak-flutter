# AllStak Flutter — NDK crash-capture native library.
#
# Builds liballstak_crash.so, loaded by AllStakPlugin.kt via System.loadLibrary.
# Async-signal-safe POSIX signal handlers (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/
# SIGTRAP) that capture native/NDK crashes the JVM uncaught-exception handler
# misses. See allstak_crash.c for the safety constraints.

cmake_minimum_required(VERSION 3.10)

project(allstak_crash C)

add_library(allstak_crash SHARED
    allstak_crash.c)

# log: __android_log_print. The C-runtime unwinder (_Unwind_Backtrace) is part
# of the toolchain and needs no extra link target.
find_library(log-lib log)

target_link_libraries(allstak_crash ${log-lib})
