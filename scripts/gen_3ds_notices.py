#!/usr/bin/env python3
"""Regenerates the second-format section of Resources/Legal/NOTICES.txt with the
verbatim notices of everything build_3ds_core.sh links (the BSD/MIT/
Apache/zlib/BSL licenses require it). Between markers: safe to run as many times as needed."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / "Vendor/azahar/externals"
NOTICES = ROOT / "Targets/INDS/Resources/Legal/NOTICES.txt"
BEGIN, END = "# --- second-format core: begin ---", "# --- second-format core: end ---"
# (name, license, file)
PARTS = [
    ("Second-format emulation core", "GPLv2 or later · © Citra Emulator Project / Azahar Emulator Project",
     ROOT / "Vendor/azahar/misc/licenses/gplv2.txt"),
    ("Open replacement system font", "GPLv2 (citra_system_archives) · glyphs: GNU Unifont (GPLv2+ with font exception), Montserrat (SIL OFL 1.1)",
     ROOT / "Native3DS/licenses/OpenSharedFont-NOTICE.txt"),
    ("MoltenVK", "Apache-2.0 · © The Brenwill Workshop Ltd. / Khronos Group", ROOT / "Native3DS/licenses/MoltenVK-LICENSE.txt"),
    ("Boost", "BSL-1.0", EXT / "boost/LICENSE_1_0.txt"),
    ("fmt", "MIT", EXT / "fmt/LICENSE"),
    ("Crypto++", "BSL-1.0", EXT / "cryptopp/LICENSE"),
    ("glslang", "BSD-3-Clause and others", EXT / "glslang/LICENSE.txt"),
    ("SPIRV-Tools", "Apache-2.0", EXT / "spirv-tools/LICENSE"),
    ("SPIRV-Headers", "MIT", EXT / "spirv-headers/LICENSE"),
    ("Vulkan-Headers", "Apache-2.0 / MIT", EXT / "vulkan-headers/LICENSE.md"),
    ("VulkanMemoryAllocator", "MIT", EXT / "vma/LICENSE.txt"),
    ("sirit", "BSD-3-Clause", EXT / "sirit/sirit/LICENSE.txt"),
    ("zstd", "BSD-3-Clause", EXT / "zstd/LICENSE"),
    ("teakra", "MIT", EXT / "teakra/LICENSE"),
    ("SoundTouch", "LGPL-2.1", EXT / "soundtouch/COPYING.TXT"),
    ("FAAD2", "GPLv2 or later", EXT / "faad2/faad2/COPYING"),
    ("LibreSSL", "OpenSSL / ISC", EXT / "libressl/COPYING"),
    ("OpenAL Soft", "LGPL-2.0", EXT / "openal-soft/COPYING"),
    ("LodePNG", "zlib", EXT / "lodepng/lodepng/LICENSE"),
    ("xxHash", "BSD-2-Clause", EXT / "xxHash/LICENSE"),
    ("ENet", "MIT", EXT / "enet/LICENSE"),
    ("oaknut", "MIT", EXT / "oaknut/LICENSE"),
    ("dynarmic", "0BSD", EXT / "dynarmic/LICENSE.txt"),
    ("inih", "BSD-3-Clause", EXT / "inih/inih/LICENSE.txt"),
    ("nihstro", "BSD-3-Clause", EXT / "nihstro/license.txt"),
    ("dds-ktx", "BSD-2-Clause", EXT / "dds-ktx/LICENSE"),
    ("libyuv", "BSD-3-Clause", EXT / "libyuv/LICENSE"),
    ("microtar", "MIT", EXT / "microtar/LICENSE"),
]
blocks = [BEGIN]
for name, lic, path in PARTS:
    blocks += ["", "=" * 72, f"{name} — {lic}", "=" * 72, path.read_text(errors="replace").strip()]
blocks += ["", END]
section = "\n".join(blocks) + "\n"
text = NOTICES.read_text()
if BEGIN in text:
    text = text[:text.index(BEGIN)] + section + text[text.index(END) + len(END) + 1:]
else:
    text = text.rstrip("\n") + "\n\n\n" + section
NOTICES.write_text(text)
missing = [n for n, _, p in PARTS if not p.exists()]
assert not missing, missing
print("ok:", len(PARTS), "avisos en", NOTICES.relative_to(ROOT))
