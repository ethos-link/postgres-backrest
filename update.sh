#!/usr/bin/env bash
set -euo pipefail

# Update the PostgreSQL base image version and image release tag.

usage() {
    echo "Usage: $0 <postgres_version> [-r=<revision>|--revision=<revision>]"
    echo "Examples:"
    echo "  $0 18.4"
    echo "  $0 18.3 -r=1"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

NEW_POSTGRES_VERSION="$1"
REVISION=""

shift

while [ $# -gt 0 ]; do
    case "$1" in
        -r=*|--revision=*)
            REVISION="${1#*=}"
            ;;
        -r|--revision)
            shift
            if [ $# -eq 0 ]; then
                usage
            fi
            REVISION="$1"
            ;;
        -*)
            usage
            ;;
        *)
            usage
            ;;
    esac
    shift
done

if [ -n "${REVISION}" ]; then
    if ! [[ "${REVISION}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Revision must be a positive integer." >&2
        exit 1
    fi

    NEW_IMAGE_VERSION="${NEW_POSTGRES_VERSION}-r${REVISION}"
fi

NEW_IMAGE_VERSION="${NEW_IMAGE_VERSION:-$NEW_POSTGRES_VERSION}"

# Update the default ARG in Dockerfile
sed -i "s/ARG POSTGRES_VERSION=.*/ARG POSTGRES_VERSION=${NEW_POSTGRES_VERSION}/" Dockerfile

# Update version files
echo "${NEW_POSTGRES_VERSION}" > POSTGRES_VERSION
echo "${NEW_IMAGE_VERSION}" > VERSION

echo "Updated PostgreSQL base version to ${NEW_POSTGRES_VERSION}"
echo "Updated image release version to ${NEW_IMAGE_VERSION}"
echo "You can now build and test the image."
