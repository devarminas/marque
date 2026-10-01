#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace marque::transport {

class Opener {
public:
    virtual ~Opener() = default;

    virtual std::size_t overhead() const = 0;

    [[nodiscard]] virtual bool open(std::span<const std::uint8_t> header, std::span<const std::uint8_t> sealed,
                                    std::vector<std::uint8_t>& out) = 0;
};

class Sealer {
public:
    virtual ~Sealer() = default;

    virtual std::size_t overhead() const = 0;

    virtual void seal(std::span<const std::uint8_t> header, std::span<const std::uint8_t> body,
                      std::vector<std::uint8_t>& out) = 0;
};

class Plain final : public Opener, public Sealer {
public:
    std::size_t overhead() const override { return 0; }

    void seal(std::span<const std::uint8_t>, std::span<const std::uint8_t> body,
              std::vector<std::uint8_t>& out) override {
        out.insert(out.end(), body.begin(), body.end());
    }

    bool open(std::span<const std::uint8_t>, std::span<const std::uint8_t> sealed,
              std::vector<std::uint8_t>& out) override {
        out.insert(out.end(), sealed.begin(), sealed.end());
        return true;
    }
};

}
