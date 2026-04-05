FROM python:3.11-slim

LABEL maintainer="coldchain-sentinel"
LABEL description="Cold-Chain Sentinel — Edge Processor"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SERVICE_NAME=edge

WORKDIR /app

COPY edge/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY shared/ /app/shared/
COPY edge/ /app/edge/

ENV MQTT_HOST=mosquitto \
    MQTT_PORT=1883 \
    EDGE_DOWNSAMPLE_N=10 \
    EDGE_TEMP_MAX_C=-15.0 \
    EDGE_DOOR_OPEN_SECONDS=300 \
    EDGE_BATTERY_LOW_V=11.2 \
    EDGE_EWMA_ALPHA=0.1 \
    EDGE_ANOMALY_ZSCORE=3.0 \
    LOG_LEVEL=INFO

CMD ["python", "-m", "edge.main"]
