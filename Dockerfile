# Bonsai Demo — llama.cpp chat UI (CUDA). Linux x86_64 pre-built binaries match CUDA 12.8
# when no toolkit is detected at image build time (same as local setup default).
#
# Build (downloads GGUF from Hugging Face; set token if repos are private):
#   docker build -t bonsai-demo \
#     --build-arg HF_TOKEN=hf_xxx \
#     --build-arg BONSAI_MODEL=8B \
#     .
#
# Skip embedding the model in the image (mount ./models at runtime instead):
#   docker build -t bonsai-demo --build-arg SKIP_MODEL_DOWNLOAD=1 .
#   docker run --gpus all -p 8080:8080 -v "$(pwd)/models:/app/models" bonsai-demo
#
# Run (needs NVIDIA Container Toolkit on the host):
#   docker run --gpus all -p 8080:8080 -e HF_TOKEN=hf_xxx bonsai-demo
#
# Override model size at runtime (must exist under /app/models):
#   docker run --gpus all -p 8080:8080 -e BONSAI_MODEL=4B bonsai-demo

FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    build-essential \
    lsof \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

COPY pyproject.toml uv.lock ./

RUN uv venv .venv --python 3.11 && uv sync --frozen

COPY . .

ARG BONSAI_MODEL=8B
ENV BONSAI_MODEL=${BONSAI_MODEL}

ARG HF_TOKEN=
ENV HF_TOKEN=${HF_TOKEN}

RUN chmod +x /app/scripts/*.sh && \
    sh /app/scripts/download_binaries.sh

ARG SKIP_MODEL_DOWNLOAD=0
RUN if [ "$SKIP_MODEL_DOWNLOAD" = "0" ]; then \
      sh /app/scripts/download_models.sh; \
    else \
      echo "SKIP_MODEL_DOWNLOAD=1: expect models/ mounted or downloaded at runtime"; \
    fi

EXPOSE 8080

CMD ["sh", "-c", "exec /app/scripts/start_llama_server.sh"]
