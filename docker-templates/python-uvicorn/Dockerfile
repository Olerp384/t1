# syntax=docker/dockerfile:1
ARG PYTHON_VERSION=3.11
FROM python:${PYTHON_VERSION}-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential curl \
 && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml poetry.lock* requirements*.txt ./
# Try poetry first if present, fallback to pip requirements
RUN if [ -f pyproject.toml ]; then \
      pip install --no-cache-dir poetry==1.8.3 && \
      poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi ; \
    else \
      req_file="$(ls requirements*.txt 2>/dev/null | head -n1 || true)" ; \
      if [ -n "$req_file" ]; then \
        pip install --no-cache-dir -r "$req_file" ; \
      else \
        echo "No dependency files found; skipping install"; \
      fi ; \
    fi

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
