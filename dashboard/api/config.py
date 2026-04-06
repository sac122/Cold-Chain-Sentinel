import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))
from shared.utils import env_int, env_float

class DashboardConfig:
    MQTT_HOST: str        = os.getenv("MQTT_HOST", "localhost")
    MQTT_PORT: int        = env_int("MQTT_PORT", 1883)
    MQTT_USERNAME: str    = os.getenv("MQTT_USERNAME", "")
    MQTT_PASSWORD: str    = os.getenv("MQTT_PASSWORD", "")
    HTTP_HOST: str        = os.getenv("DASH_HOST", "0.0.0.0")
    HTTP_PORT: int        = env_int("DASH_PORT", 5001)
    # How many temperature history points to keep per device
    HISTORY_LEN: int      = env_int("HISTORY_LEN", 60)
    # Max events in global feed
    MAX_EVENTS: int       = env_int("MAX_EVENTS", 200)
    # Frozen cargo alert threshold (°C) — used for status colouring
    TEMP_WARN_C: float    = env_float("TEMP_WARN_C", -15.0)
    TEMP_CRIT_C: float    = env_float("TEMP_CRIT_C", -10.0)
    # Seconds before a device is marked offline
    OFFLINE_SECS: float   = env_float("OFFLINE_SECS", 30.0)
    # Static files directory (built React app)
    STATIC_DIR: str       = os.getenv("STATIC_DIR", "/app/static")
