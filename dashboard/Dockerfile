# ── Stage 1: Build React UI ───────────────────────────────────────────────────
FROM node:20-alpine AS ui-builder

WORKDIR /ui

# Install deps first (better layer caching)
COPY dashboard/ui/package.json ./
RUN npm install --legacy-peer-deps

# Copy source and build
COPY dashboard/ui/ ./
RUN npm run build
# Output: /ui/dist/


# ── Stage 2: Python FastAPI server ────────────────────────────────────────────
FROM python:3.11-slim

LABEL maintainer="coldchain-sentinel"
LABEL description="Cold-Chain Sentinel — Dashboard (API + React UI)"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SERVICE_NAME=dashboard \
    PYTHONPATH=/app

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Python deps
COPY dashboard/api/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY shared/          /app/shared/
COPY dashboard/api/   /app/dashboard/api/
RUN touch /app/dashboard/__init__.py

# Copy built React app into the static directory FastAPI will serve
COPY --from=ui-builder /ui/dist /app/static/

ENV MQTT_HOST=mosquitto \
    MQTT_PORT=1883 \
    DASH_HOST=0.0.0.0 \
    DASH_PORT=5001 \
    STATIC_DIR=/app/static \
    HISTORY_LEN=60 \
    MAX_EVENTS=200 \
    TEMP_WARN_C=-15.0 \
    TEMP_CRIT_C=-10.0 \
    OFFLINE_SECS=30 \
    LOG_LEVEL=INFO

EXPOSE 5001

HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:5001/api/health || exit 1

CMD ["uvicorn", "dashboard.api.main:app", "--host", "0.0.0.0", "--port", "5001", "--log-level", "warning"]
