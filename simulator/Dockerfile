FROM python:3.11-slim

LABEL maintainer="coldchain-sentinel"
LABEL description="Cold-Chain Sentinel — IoT Device Simulator"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SERVICE_NAME=simulator

WORKDIR /app

# Install dependencies
COPY simulator/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy shared library and simulator source
COPY shared/ /app/shared/
COPY simulator/ /app/simulator/

# Default: 10 devices, 2-second interval
ENV NUM_DEVICES=10 \
    PUBLISH_INTERVAL=2.0 \
    RANDOM_SEED=42 \
    CARGO_TYPE=frozen \
    MQTT_HOST=mosquitto \
    MQTT_PORT=1883 \
    LOG_LEVEL=INFO

CMD ["python", "-m", "simulator.main"]
