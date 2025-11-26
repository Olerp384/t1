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

# Install Poetry without virtualenv creation to keep deps in system site-packages.
RUN curl -sSL https://install.python-poetry.org | python3 - --version 1.8.3 \
 && ln -s /root/.local/bin/poetry /usr/local/bin/poetry

COPY pyproject.toml poetry.lock* ./
RUN poetry config virtualenvs.create false \
 && poetry install --no-interaction --no-ansi

COPY . .

CMD ["python", "main.py"]
