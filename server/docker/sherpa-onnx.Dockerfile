# syntax=docker/dockerfile:1.7
# voice-stt sherpa-onnx CPU streaming backend.
# Build from server/ as context: `docker compose --profile cpu build`.
FROM python:3.11-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget bzip2 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir sherpa-onnx websockets numpy

COPY sherpa-onnx-entrypoint.sh /usr/local/bin/sherpa-onnx-entrypoint.sh
RUN chmod +x /usr/local/bin/sherpa-onnx-entrypoint.sh

WORKDIR /app

ENTRYPOINT ["/usr/local/bin/sherpa-onnx-entrypoint.sh"]
