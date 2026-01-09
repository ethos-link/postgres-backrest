#!/usr/bin/env bash
set -euo pipefail

# Update the PostgreSQL version in the Dockerfile

if [ $# -ne 1 ]; then
    echo "Usage: $0 <postgres_version>"
    echo "Example: $0 17.0"
    exit 1
fi

NEW_VERSION="$1"

# Update the default ARG in Dockerfile
sed -i "s/ARG POSTGRES_VERSION=.*/ARG POSTGRES_VERSION=${NEW_VERSION}/" Dockerfile

echo "Updated Dockerfile to use PostgreSQL version ${NEW_VERSION}"
echo "You can now build and test the image."