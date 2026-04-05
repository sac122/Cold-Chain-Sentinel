"""
Lightweight online anomaly detection for the edge processor.

Algorithm: EWMA (Exponentially-Weighted Moving Average) + rolling variance
           → z-score for each incoming temperature reading.

This runs entirely in Python (no ML framework needed) so it is suitable
for resource-constrained edge hardware.

Math recap
----------
Let α ∈ (0, 1) be the smoothing factor (default 0.1).

  ewma[i]   = α * x[i] + (1 - α) * ewma[i-1]
  var[i]    = (1 - α) * (var[i-1] + α * (x[i] - ewma[i-1])²)
  std[i]    = sqrt(var[i] + ε)      # ε avoids div-by-zero at startup
  z[i]      = (x[i] - ewma[i]) / std[i]

An anomaly is flagged when |z[i]| > threshold (default 3.0).

Per-device state is maintained in AnomalyDetector.get_or_create().
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from shared.schemas import EventPayload, EventSeverity, EventType, TelemetryPayload
from edge.config import EdgeConfig


@dataclass
class EWMAState:
    ewma: float
    variance: float
    n_samples: int = 0


class AnomalyDetector:
    """Maintains EWMA state for each device and scores incoming readings."""

    _EPS = 1e-6   # floor for variance to avoid div-by-zero

    def __init__(self, cfg: EdgeConfig) -> None:
        self._alpha     = cfg.EWMA_ALPHA
        self._threshold = cfg.ANOMALY_ZSCORE_THRESHOLD
        self._min_n     = cfg.ANOMALY_MIN_SAMPLES
        self._states: dict[str, EWMAState] = {}

    # ── State management ──────────────────────────────────────────────────────

    def _get_state(self, device_id: str, first_value: float) -> EWMAState:
        if device_id not in self._states:
            self._states[device_id] = EWMAState(
                ewma=first_value,
                variance=0.0,
                n_samples=0,
            )
        return self._states[device_id]

    # ── Core update ───────────────────────────────────────────────────────────

    def update(
        self,
        payload: TelemetryPayload,
        cfg: EdgeConfig,
    ) -> tuple[TelemetryPayload, list[EventPayload]]:
        """
        Update EWMA state with the new temperature reading.

        Returns:
            (annotated_payload, events)
            annotated_payload has ewma_temp and anomaly_score filled in.
            events is a list of ANOMALY EventPayload objects (0 or 1).
        """
        x = payload.temp_c
        alpha = self._alpha
        state = self._get_state(payload.device_id, x)

        prev_ewma = state.ewma

        # Update EWMA
        state.ewma = alpha * x + (1 - alpha) * state.ewma

        # Update variance (Welford-style EWMA variance)
        state.variance = (1 - alpha) * (state.variance + alpha * (x - prev_ewma) ** 2)

        state.n_samples += 1

        std = math.sqrt(max(state.variance, self._EPS))
        z_score = (x - state.ewma) / std

        # Annotate payload
        annotated = payload.model_copy(update={
            "ewma_temp":     round(state.ewma, 4),
            "anomaly_score": round(z_score, 4),
            "edge_processed": True,
        })

        events: list[EventPayload] = []

        # Only score after warm-up period
        if state.n_samples >= self._min_n and abs(z_score) > self._threshold:
            events.append(EventPayload(
                device_id     = payload.device_id,
                event_type    = EventType.ANOMALY,
                severity      = (
                    EventSeverity.CRITICAL
                    if abs(z_score) > self._threshold * 1.5
                    else EventSeverity.WARNING
                ),
                reason        = (
                    f"Temperature anomaly: z-score {z_score:.2f} "
                    f"(ewma={state.ewma:.2f} °C, σ={std:.3f}, "
                    f"reading={x:.2f} °C)"
                ),
                telemetry     = annotated,
                anomaly_score = z_score,
            ))

        return annotated, events

    def reset(self, device_id: str) -> None:
        """Reset state for a device (e.g., after maintenance)."""
        self._states.pop(device_id, None)

    @property
    def device_count(self) -> int:
        return len(self._states)
