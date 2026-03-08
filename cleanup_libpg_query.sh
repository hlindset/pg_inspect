#!/bin/sh

set -eu

cd "$(dirname "$0")"

if [ ! -d "libpg_query" ]; then
  echo "libpg_query directory not found" >&2
  exit 1
fi

rm -r \
  libpg_query/examples \
  libpg_query/test \
  libpg_query/testdata \
  libpg_query/tmp \
  libpg_query/patches \
  libpg_query/scripts \
  libpg_query/srcdata \
  libpg_query/.github

rm -f \
  libpg_query/.gitattributes \
  libpg_query/.gitignore \
  libpg_query/.ruby-version \
  libpg_query/CHANGELOG.md \
  libpg_query/README.md \
  libpg_query/libpg_query.a

find libpg_query/src libpg_query/protobuf -name '*.o' -delete

echo "Trimmed libpg_query to the source-build subset."
