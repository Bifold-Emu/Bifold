# Azahar dedicated room server (official azahar-room), built from the same tag as the app.
ARG AZAHAR_TAG=2126.2

FROM ubuntu:24.04 AS builder
ARG AZAHAR_TAG
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git ca-certificates cmake ninja-build g++ python3 pkg-config && rm -rf /var/lib/apt/lists/*
RUN git clone --branch "${AZAHAR_TAG}" --depth 1 https://github.com/azahar-emu/azahar /src && \
    git -C /src submodule update --init --recursive --depth 1 -j 8
RUN cmake -S /src -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_QT=OFF -DENABLE_SDL2=OFF -DENABLE_TESTS=OFF -DENABLE_OPENGL=OFF -DENABLE_VULKAN=OFF \
      -DENABLE_CUBEB=OFF -DENABLE_OPENAL=OFF -DENABLE_LIBUSB=OFF -DENABLE_GDBSTUB=OFF \
      -DENABLE_ROOM=ON -DENABLE_ROOM_STANDALONE=ON -DENABLE_WEB_SERVICE=ON \
      -DCITRA_WARNINGS_AS_ERRORS=OFF -DCITRA_USE_PRECOMPILED_HEADERS=OFF && \
    cmake --build /build --target citra_room_standalone -j"$(nproc)" && \
    cp "$(find /build -name azahar-room -type f -perm -u+x | head -n1)" /usr/local/bin/azahar-room

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/azahar-room /usr/local/bin/azahar-room
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && useradd -r -m room
USER room
WORKDIR /home/room
EXPOSE 24872/udp
ENTRYPOINT ["/entrypoint.sh"]
