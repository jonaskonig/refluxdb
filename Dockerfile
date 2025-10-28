ARG RUST_VERSION=1.88  
ARG TARGETPLATFORM  
FROM rust:${RUST_VERSION}-slim-bookworm as build  
  
USER root  
  
RUN apt update \  
    && apt install --yes binutils build-essential curl pkg-config libssl-dev clang lld git patchelf protobuf-compiler zstd libz-dev \  
    && rm -rf /var/lib/{apt,dpkg,cache,log}  
  
RUN mkdir /influxdb3  
WORKDIR /influxdb3  
  
ARG CARGO_INCREMENTAL=no  
ARG CARGO_NET_GIT_FETCH_WITH_CLI=true
ARG CARGO_BUILD_JOBS=12  
ARG PROFILE=release  
ARG FEATURES=aws,gcp,azure,jemalloc_replacing_malloc,tokio_console  
ARG PACKAGE=influxdb3  
ARG PBS_DATE=20250612  
ARG PBS_VERSION=3.13.5  
ARG TARGETPLATFORM  
  
# Map TARGETPLATFORM to PBS_TARGET (from docker_build_release.bash)  
RUN case "$TARGETPLATFORM" in \  
    "linux/amd64") \  
        echo "x86_64-unknown-linux-gnu" > /tmp/pbs_target ;; \  
    "linux/arm64") \  
        echo "aarch64-unknown-linux-gnu" > /tmp/pbs_target ;; \  
    *) \  
        echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \  
    esac  
  
ENV CARGO_INCREMENTAL=$CARGO_INCREMENTAL \  
    CARGO_NET_GIT_FETCH_WITH_CLI=$CARGO_NET_GIT_FETCH_WITH_CLI \  
    PROFILE=$PROFILE \  
    FEATURES=$FEATURES \  
    PACKAGE=$PACKAGE \  
    PBS_DATE=$PBS_DATE \  
    PBS_VERSION=$PBS_VERSION  
  
# Copy CircleCI scripts for Python Build Standalone  
COPY .circleci /influxdb3/.circleci  
  
# Fetch and extract Python Build Standalone (from fetch-python job)  
RUN PBS_TARGET=$(cat /tmp/pbs_target) && \  
    sed -i "s/^readonly TARGETS=.*/readonly TARGETS=${PBS_TARGET}/" ./.circleci/scripts/fetch-python-standalone.bash && \  
    ./.circleci/scripts/fetch-python-standalone.bash /influxdb3/python-artifacts "${PBS_DATE}" "${PBS_VERSION}" && \  
    tar -C /influxdb3/python-artifacts -zxf /influxdb3/python-artifacts/all.tar.gz "./${PBS_TARGET}" && \  
    sed -i 's#tmp/workspace#influxdb3#' "/influxdb3/python-artifacts/${PBS_TARGET}/pyo3_config_file.txt"  
  
COPY . /influxdb3  
  
# Install Rust toolchain and target (from build-release job)  
RUN \  
  --mount=type=cache,id=influxdb3_rustup,sharing=locked,target=/usr/local/rustup \  
  --mount=type=cache,id=influxdb3_registry,sharing=locked,target=/usr/local/cargo/registry \  
  --mount=type=cache,id=influxdb3_git,sharing=locked,target=/usr/local/cargo/git \  
    PBS_TARGET=$(cat /tmp/pbs_target) && \  
    rustup toolchain install && \  
    rustup target add ${PBS_TARGET}  
  
# Build with PYO3 configuration (from build-release job)  
RUN \  
  --mount=type=cache,id=influxdb3_rustup,sharing=locked,target=/usr/local/rustup \  
  --mount=type=cache,id=influxdb3_registry,sharing=locked,target=/usr/local/cargo/registry \  
  --mount=type=cache,id=influxdb3_git,sharing=locked,target=/usr/local/cargo/git \  
  --mount=type=cache,id=influxdb3_target,sharing=locked,target=/influxdb3/target \  
    PBS_TARGET=$(cat /tmp/pbs_target) && \  
    export PYO3_CONFIG_FILE="/influxdb3/python-artifacts/${PBS_TARGET}/pyo3_config_file.txt" && \  
    export LD_LIBRARY_PATH="/influxdb3/python-artifacts/${PBS_TARGET}/python/lib:${LD_LIBRARY_PATH}" && \  
    cargo build --target-dir /influxdb3/target --target=${PBS_TARGET} --package="${PACKAGE}" --profile="${PROFILE}" --no-default-features --features="${FEATURES}" && \  
    objcopy --compress-debug-sections "target/${PBS_TARGET}/${PROFILE}/${PACKAGE}" && \  
    cp "/influxdb3/target/${PBS_TARGET}/${PROFILE}/${PACKAGE}" "/root/${PACKAGE}" && \  
    patchelf --set-rpath '$ORIGIN/python/lib:$ORIGIN/../lib/influxdb3/python/lib' "/root/${PACKAGE}" && \  
    cp -a "/influxdb3/python-artifacts/${PBS_TARGET}/python" /root/python  
  
FROM debian:bookworm-slim  
  
RUN apt update \  
    && apt install --yes ca-certificates gettext-base libssl3 wget curl --no-install-recommends \  
    && rm -rf /var/lib/{apt,dpkg,cache,log} \  
    && groupadd --gid 1500 influxdb3 \  
    && useradd --uid 1500 --gid influxdb3 --shell /bin/bash --create-home influxdb3  
  
RUN mkdir /var/lib/influxdb3 && \  
    chown influxdb3:influxdb3 /var/lib/influxdb3  
  
RUN mkdir -p /usr/lib/influxdb3  
COPY --from=build /root/python /usr/lib/influxdb3/python  
RUN chown -R root:root /usr/lib/influxdb3  
  
RUN mkdir /plugins && \  
    chown influxdb3:influxdb3 /plugins  
  
 
  
RUN mkdir ~/.influxdb3  
  
ARG PACKAGE=influxdb3  
ENV PACKAGE=$PACKAGE  
ENV INFLUXDB3_PLUGIN_DIR=/plugins  
  
COPY --from=build "/root/$PACKAGE" "/usr/bin/$PACKAGE"  
  
RUN chmod +x /usr/bin/influxdb3  

USER influxdb3 

EXPOSE 8181  
  
ENV LOG_FILTER=info  
  
CMD ["/usr/bin/influxdb3", "serve", "--writer-id=iox", "--object-store", "file", "--data-dir", "/data"]
