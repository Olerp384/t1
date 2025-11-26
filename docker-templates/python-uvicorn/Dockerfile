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
    elif ls requirements*.txt >/dev/null 2>&1; then \
      pip install --no-cache-dir -r requirements.txt ; \
    fi

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
