#!/usr/bin/env bash
set -euo pipefail

# Build and push a multi-arch postgres-backrest image to multiple registries.

# Default values
POSTGRES_VERSION="${POSTGRES_VERSION:-$(cat POSTGRES_VERSION)}"
IMAGE_VERSION="${IMAGE_VERSION:-$(cat VERSION)}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
IMAGES="${IMAGES:-docker.io/ethoslink/postgres-backrest ghcr.io/ethos-link/postgres-backrest}"
BUILDER="${BUILDER:-postgres-backrest-builder}"
ALLOW_TAG_OVERWRITE="${ALLOW_TAG_OVERWRITE:-0}"
PUBLISH_LATEST="${PUBLISH_LATEST:-1}"

for image in $IMAGES; do
    if [ "${ALLOW_TAG_OVERWRITE}" != "1" ] && docker buildx imagetools inspect "${image}:${IMAGE_VERSION}" >/dev/null 2>&1; then
        echo "Refusing to overwrite existing image tag: ${image}:${IMAGE_VERSION}" >&2
        echo "Use a new IMAGE_VERSION, or set ALLOW_TAG_OVERWRITE=1 for an explicit overwrite." >&2
        exit 1
    fi
done

if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${BUILDER}" --driver docker-container --use
else
    docker buildx use "${BUILDER}"
fi

docker buildx inspect --bootstrap >/dev/null

build_args=(
    --platform "${PLATFORMS}"
    --build-arg "POSTGRES_VERSION=${POSTGRES_VERSION}"
    --label "org.opencontainers.image.version=${IMAGE_VERSION}"
    --label "org.opencontainers.image.base.name=docker.io/library/postgres:${POSTGRES_VERSION}"
    --push
)

for image in $IMAGES; do
    build_args+=(--tag "${image}:${IMAGE_VERSION}")

    if [ "${PUBLISH_LATEST}" = "1" ]; then
        build_args+=(--tag "${image}:latest")
    fi
done

echo "Building ${IMAGES}:${IMAGE_VERSION} from postgres:${POSTGRES_VERSION} for ${PLATFORMS}..."
docker buildx build "${build_args[@]}" .

echo "Published ${IMAGE_VERSION} for ${PLATFORMS}."
