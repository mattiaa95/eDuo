# eDuo's 3DS frontend, built inside Azahar's tree (patch 0002 adds it when
# EDUO_FRONTEND_DIR is set). scripts/build_3ds_core.sh drives it.
add_library(eduo3ds STATIC
    src/E3DS.h
    src/E3DS.mm
    src/E3DSHomebrewTag.h
    src/input_manager.cpp
    src/input_manager.h
)
target_include_directories(eduo3ds PUBLIC src)
target_compile_options(eduo3ds PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(eduo3ds PRIVATE citra_common citra_core video_core audio_core input_common)
