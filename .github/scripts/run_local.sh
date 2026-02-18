#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ARTS=artifacts
RUNS="${1:-5}"
MTU=1504

chmod +x "$ARTS"/build-quiche/* "$ARTS"/build-google/*
chmod +x "$ARTS/build-neqo/neqo-client" "$ARTS/build-neqo/neqo-server"

mkdir -p binaries/neqo binaries/neqo-main
cp "$ARTS/build-neqo/neqo-client" "$ARTS/build-neqo/neqo-server" binaries/neqo/
cp "$ARTS/build-neqo/neqo-client" "$ARTS/build-neqo/neqo-server" binaries/neqo-main/

mkdir -p google-quiche/bazel-bin/quiche
cp "$ARTS"/build-google/* google-quiche/bazel-bin/quiche/

mkdir -p quiche/target/release
cp "$ARTS"/build-quiche/* quiche/target/release/

export LD_LIBRARY_PATH="$PWD/artifacts/build-neqo/lib:${LD_LIBRARY_PATH:-}"
export NSS_DB_PATH="$PWD/artifacts/build-neqo/test-fixture/db"
export NSS_DIR="$PWD/artifacts/build-neqo/nss"
export NSS_PREBUILT=1

python3 .github/scripts/perfcompare.py \
  --host 127.0.0.1 \
  --port 4433 \
  --size 33554432 \
  --runs "$RUNS" \
  --workspace "$PWD"
