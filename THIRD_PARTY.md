# Third-party components

Everything compiled into the eDuo binary, including the components that
melonDS itself vendors and builds unconditionally.

| Component | Where | License | Copyright |
|---|---|---|---|
| melonDS | `Vendor/melonDS` (git submodule, unmodified upstream) | GPLv3 | © Arisotura and the melonDS team |
| FreeBIOS | inside melonDS (`src/FreeBIOS*`) | BSD 2-clause | © 2013 Gilead Kutnick |
| teakra | inside melonDS (`src/teakra`) | MIT | © wwylele and contributors |
| blip-buf | inside melonDS (`src/blip-buf`) | LGPL-2.1 | © Shay Green (blargg) |
| xxHash | inside melonDS (`src/xxhash`) | BSD 2-clause | © 2012–2023 Yann Collet |
| FatFs | inside melonDS (`src/fatfs`) | FatFs license (BSD-style, one condition) | © 2021 ChaN |
| tiny-AES-c | inside melonDS (`src/tiny-AES-c`) | The Unlicense (public domain) | — |
| SHA-1 | inside melonDS (`src/sha1`) | Public domain | Steve Reid |
| LZMA SDK (7z decoder) | `Targets/INDS/Sources/Vendor/lzma` | Public domain | Igor Pavlov |
| minizip | `Targets/INDS/Sources/Vendor/minizip` | zlib | © 1998–2010 Gilles Vollant |

License texts travel with the app and with this repository:
`LICENSE` (GPLv3, covers eDuo itself and melonDS),
`Targets/INDS/Resources/Legal/NOTICES.txt` (verbatim notices of every
component above, as BSD/MIT/zlib/LGPL require),
`Targets/INDS/Sources/Vendor/lzma/LICENSE.txt` and
`Targets/INDS/Sources/Vendor/minizip/LICENSE.txt`, plus the notices kept at
the top of each vendored file.

Not compiled in: melonDS's Dolphin-derived JIT (`ENABLE_JIT=OFF`), its
OpenGL renderer, GDB stub, and the net-utils / multiplayer targets — see
`BUILDING.md` for the exact core configuration.

Everything else in `Targets/` is original eDuo code, © Mattia La Spina,
released under the GPLv3 (see `LICENSE`).
