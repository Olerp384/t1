# syntax=docker/dockerfile:1
ARG PYTHON_VERSION=3.11
FROM python:${PYTHON_VERSION}-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY requirements*.txt ./
# Install first matching requirements file if present to avoid failing on missing names
RUN req_file="$(ls requirements*.txt 2>/dev/null | head -n1 || true)" \
 && if [ -n "$req_file" ]; then \
      pip install --no-cache-dir -r "$req_file"; \
    else \
      echo "No requirements*.txt found; skipping dependency install"; \
    fi

COPY . .

CMD ["python", "main.py"]
