# ── Stage 1: build deps ────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: runtime image ──────────────────────────────────────────────────
FROM python:3.11-slim

LABEL maintainer="you@example.com"
LABEL description="Simple key-value store for K8s HPA demo"

WORKDIR /app

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY main.py .

# Non-root user for security
RUN useradd -m appuser
USER appuser

ENV PORT=5000
EXPOSE 5000

# gunicorn with 2 sync workers — keeps resource usage predictable for HPA demo
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "30", "main:app"]
