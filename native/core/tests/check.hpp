#pragma once

#include <cstdio>

namespace marque::test {

inline int failures = 0;

inline void check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) {
        ++failures;
    }
}

inline int check_finish() {
    std::printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}

}
