#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static atomic_int doc_cache_loads;
static _Atomic pthread_t held_thread;
static atomic_bool released;

static int is_doc_cache(const char* path) {
    static const char suffix[] = "/editor_doc_cache-4.7.res";
    size_t len = strlen(path);
    return len >= sizeof(suffix) - 1 && strcmp(path + len - (sizeof(suffix) - 1), suffix) == 0;
}

static void hold_reload_doc_load(const char* path) {
    if (path == NULL || gettid() == getpid() || !is_doc_cache(path)) {
        return;
    }
    if (atomic_fetch_add(&doc_cache_loads, 1) != 1) {
        return;
    }
    fprintf(stderr, "repro_gdext_doc_race: holding the second doc cache load until teardown\n");
    atomic_store(&held_thread, pthread_self());
    while (!atomic_load(&released)) {
        usleep(1000);
    }
}

FILE* fopen(const char* path, const char* mode) {
    static FILE* (*real)(const char*, const char*);
    if (real == NULL) {
        real = (FILE * (*)(const char*, const char*)) dlsym(RTLD_NEXT, "fopen");
    }
    hold_reload_doc_load(path);
    return real(path, mode);
}

FILE* fopen64(const char* path, const char* mode) {
    static FILE* (*real)(const char*, const char*);
    if (real == NULL) {
        real = (FILE * (*)(const char*, const char*)) dlsym(RTLD_NEXT, "fopen64");
    }
    hold_reload_doc_load(path);
    return real(path, mode);
}

int pthread_join(pthread_t thread, void** result) {
    static int (*real)(pthread_t, void**);
    if (real == NULL) {
        real = (int (*)(pthread_t, void**))dlsym(RTLD_NEXT, "pthread_join");
    }
    pthread_t held = atomic_load(&held_thread);
    if (held != 0 && pthread_equal(thread, held)) {
        fprintf(stderr, "repro_gdext_doc_race: main thread joined the held worker, releasing it\n");
        atomic_store(&released, true);
    }
    return real(thread, result);
}
