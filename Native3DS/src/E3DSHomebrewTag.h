// E3DSHomebrewTag.h — folder tag for a .3dsx, which has no program ID.
// Header-only and free of core types so scripts/homebrew_tag_check.cpp can run the very
// same code. GPLv2-or-later, like the rest of the bridge.

#pragma once

#include <cstdio>
#include <string>

/// "3dsx-<16 hex digits>": FNV-1a over the first 16 MiB of the file plus its size, or an
/// empty string if the file can't be read. Depends on content only, never on the path or
/// name, so the same homebrew maps to the same folder wherever it lives.
inline std::string E3DSHomebrewTag(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return {};
    unsigned long long h = 1469598103934665603ull;
    auto mix = [&h](const unsigned char* p, size_t n) {
        for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
    };
    unsigned char buf[64 * 1024];
    size_t total = 0, n;
    while (total < (16u << 20) && (n = fread(buf, 1, sizeof buf, f)) > 0) { mix(buf, n); total += n; }
    fseek(f, 0, SEEK_END);
    const unsigned long long size = (unsigned long long)ftell(f);
    fclose(f);
    mix(reinterpret_cast<const unsigned char*>(&size), sizeof size);
    char out[32];
    snprintf(out, sizeof out, "3dsx-%016llX", h);
    return out;
}
