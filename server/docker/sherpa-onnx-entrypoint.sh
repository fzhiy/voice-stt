#!/bin/sh
# Fetch the bilingual Paraformer model into the mounted /models volume on
# first run; behaviour mirrors the previous inline compose command.
set -e

if [ ! -d /models/sherpa-onnx-streaming-paraformer-bilingual-zh-en ]; then
  echo "[sherpa-onnx] downloading bilingual streaming Paraformer model ..." >&2
  wget -O /tmp/sherpa-onnx-model.tar.bz2 \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2
  tar -xjf /tmp/sherpa-onnx-model.tar.bz2 -C /models
  rm -f /tmp/sherpa-onnx-model.tar.bz2
fi

exec python sherpa-onnx-stream-server.py
