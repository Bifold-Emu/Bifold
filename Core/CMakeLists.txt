# AzaharCore — iOS frontend layer for the Azahar 3DS emulator core.
# This directory is linked into the Azahar tree as src/azios by scripts/bootstrap.sh and
# enabled with -DENABLE_AZIOS=ON (see patches/azahar/0004-azios-subdirectory.patch).

add_library(azios STATIC
    include/AzaharCore.h
    src/az_internal.h
    src/az_config.cpp
    src/az_core.cpp
    src/az_input.cpp
    src/az_jit.cpp
    src/az_keyboard.cpp
    src/az_multiplayer.cpp
    src/az_window.cpp
)

target_include_directories(azios PUBLIC include PRIVATE src)
target_link_libraries(azios PRIVATE citra_common citra_core video_core audio_core input_common
                                    network inih lodepng)
if (ENABLE_WEB_SERVICE)
    target_link_libraries(azios PRIVATE web_service)
    target_compile_definitions(azios PRIVATE ENABLE_WEB_SERVICE)
endif()

option(AZIOS_APPSTORE "Build the App Store flavour (JIT compiled out of the frontend policy)" OFF)
if (AZIOS_APPSTORE)
    target_compile_definitions(azios PRIVATE AZIOS_APPSTORE)
endif()

if (IOS)
    target_link_libraries(azios PRIVATE "-framework Foundation" "-framework Metal"
                                        "-framework QuartzCore" "-framework IOSurface")
else()
    # Host-side test driver (Linux/macOS): boots tiny ARM ELF programs headlessly and exercises
    # the multiplayer/lobby API against real Azahar rooms.
    add_executable(azios_test tests/azios_test.cpp)
    target_link_libraries(azios_test PRIVATE azios citra_common citra_core)
endif()
