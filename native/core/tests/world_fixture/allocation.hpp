#pragma once

#include <cstdlib>
#include <cstdint>
#include <limits>
#include <new>

namespace world_allocation {

inline bool active = false;
inline std::uint64_t calls = 0;
inline std::uint64_t bytes = 0;
inline std::uint64_t fail_after = std::numeric_limits<std::uint64_t>::max();

inline void record(std::size_t size) {
    if (!active) return;
    if (calls++ == fail_after) throw std::bad_alloc();
    bytes += size;
}

inline void begin(std::uint64_t failure = std::numeric_limits<std::uint64_t>::max()) {
    calls = 0;
    bytes = 0;
    fail_after = failure;
    active = true;
}

inline void end() { active = false; }

}

[[gnu::noinline]] void* operator new(std::size_t size) {
    world_allocation::record(size);
    if (auto* value = std::malloc(size ? size : 1)) return value;
    throw std::bad_alloc();
}

void* operator new[](std::size_t size) { return ::operator new(size); }
[[gnu::noinline]] void operator delete(void* value) noexcept { std::free(value); }
void operator delete[](void* value) noexcept { ::operator delete(value); }
void operator delete(void* value, std::size_t) noexcept { ::operator delete(value); }
void operator delete[](void* value, std::size_t) noexcept { ::operator delete(value); }

[[gnu::noinline]] void* operator new(std::size_t size, std::align_val_t alignment) {
    world_allocation::record(size);
    const auto align = static_cast<std::size_t>(alignment);
    const auto rounded = ((size ? size : 1) + align - 1) / align * align;
    if (auto* value = std::aligned_alloc(align, rounded)) return value;
    throw std::bad_alloc();
}

void* operator new[](std::size_t size, std::align_val_t alignment) { return ::operator new(size, alignment); }
void operator delete(void* value, std::align_val_t) noexcept { ::operator delete(value); }
void operator delete[](void* value, std::align_val_t) noexcept { ::operator delete(value); }
void operator delete(void* value, std::size_t, std::align_val_t) noexcept { ::operator delete(value); }
void operator delete[](void* value, std::size_t, std::align_val_t) noexcept { ::operator delete(value); }
