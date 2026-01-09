#!/usr/bin/env bash
set -euo pipefail

# Build and push the postgres-backrest image to multiple registries

# Default values
POSTGRES_VERSION="${POSTGRES_VERSION:-18.1}"
IMAGE_NAME="${IMAGE_NAME:-postgres-backrest}"
REGISTRIES="${REGISTRIES:-docker.io ghcr.io}"

# Function to build and push to a registry
build_and_push() {
    local registry="$1"
    local full_image="${registry}/${IMAGE_NAME}:${POSTGRES_VERSION}"

    echo "Building ${full_image}..."
    DOCKER_BUILDKIT=1 docker build --build-arg POSTGRES_VERSION="${POSTGRES_VERSION}" -t "${full_image}" .

    echo "Pushing ${full_image}..."
    docker push "${full_image}"

    # Also tag as latest if it's the default version
    if [ "${POSTGRES_VERSION}" = "18.1" ]; then
        docker tag "${full_image}" "${registry}/${IMAGE_NAME}:latest"
        docker push "${registry}/${IMAGE_NAME}:latest"
    fi
}

# Login to registries (you need to set credentials)
for registry in $REGISTRIES; do
    echo "Logging into ${registry}..."
    # You need to set DOCKER_USERNAME and DOCKER_PASSWORD or use docker login manually
    if [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_PASSWORD:-}" ]; then
        echo "${DOCKER_PASSWORD}" | docker login "${registry}" -u "${DOCKER_USERNAME}" --password-stdin
    else
        echo "Please set DOCKER_USERNAME and DOCKER_PASSWORD or login manually to ${registry}"
        exit 1
    fi
done

# Build and push to each registry
for registry in $REGISTRIES; do
    build_and_push "$registry"
done

echo "Done."