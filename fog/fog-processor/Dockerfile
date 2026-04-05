FROM python:3.11-slim

LABEL maintainer="coldchain-sentinel"
LABEL description="Cold-Chain Sentinel — Fog Processor"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SERVICE_NAME=fog

WORKDIR /app

# System dependencies for paho-mqtt TLS (needs libssl)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Download Amazon Root CA (for AWS IoT Core TLS)
RUN curl -sSL https://www.amazontrust.com/repository/AmazonRootCA1.pem \
        -o /etc/ssl/certs/AmazonRootCA1.pem

COPY fog/fog-processor/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY shared/               /app/shared/
COPY fog/fog-processor/    /app/fog/fog_processor/
# Make fog a proper package
RUN touch /app/fog/__init__.py

# Data directory for SQLite buffer
RUN mkdir -p /data

# Certificates directory (mount real certs here in production)
RUN mkdir -p /certs

ENV MQTT_HOST=mosquitto \
    MQTT_PORT=1883 \
    FOG_HTTP_HOST=0.0.0.0 \
    FOG_HTTP_PORT=8080 \
    BUFFER_DB_PATH=/data/fog_buffer.db \
    BUFFER_MAX_SIZE=10000 \
    BUFFER_FLUSH_INTERVAL=10 \
    AWS_IOT_ENDPOINT="" \
    AWS_IOT_PORT=8883 \
    AWS_IOT_CA_PATH=/etc/ssl/certs/AmazonRootCA1.pem \
    AWS_IOT_CERT_PATH=/certs/device-cert.pem \
    AWS_IOT_KEY_PATH=/certs/private-key.pem \
    LOG_LEVEL=INFO

EXPOSE 8080

CMD ["python", "-m", "fog.fog_processor.main"]
