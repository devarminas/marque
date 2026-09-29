#pragma once

// Plain check()-style test harness shared by every native/core/tests/*.cpp
// executable. No test framework dependency: each test file is its own
// main(), calls check() for each assertion, and finishes by returning
// check_finish() so ctest sees a non-zero exit on any failure.

#include <cstdio>

namespace marque::test {

inline int failures = 0;

inline void check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) {
        ++failures;
    }
}

// Prints the failure tally and returns the process exit code: 0 if every
// check() passed, 1 otherwise.
inline int check_finish() {
    std::printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}

}
