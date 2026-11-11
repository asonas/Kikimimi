export function samplePeakDBFS(samples) {
  let peak = 0;
  for (const value of samples) if (Number.isFinite(value)) peak = Math.max(peak, Math.abs(value));
  return peak > 0 ? Math.max(-120, 20 * Math.log10(peak)) : -120;
}

export class MeterBallistics {
  constructor() { this.reset(); }
  reset() { this.level = -60; this.peak = -60; this.holdUntil = 0; this.lastFrame = null; }
  frame(db, now, { reducedMotion = false, stale = false } = {}) {
    if (stale) { this.reset(); return { level: -60, peak: -60, stale: true }; }
    const dt = this.lastFrame === null ? 0 : Math.min(0.1, Math.max(0, (now - this.lastFrame) / 1000));
    this.lastFrame = now;
    const value = Math.max(-60, Math.min(0, Number.isFinite(db) ? db : -60));
    this.level = reducedMotion ? value : Math.max(value, this.level - 24 * dt);
    if (value >= this.peak) { this.peak = value; this.holdUntil = now + 800; }
    else if (now > this.holdUntil) this.peak = Math.max(this.level, this.peak - 24 * dt);
    return { level: this.level, peak: this.peak, stale: false };
  }
}

// Deterministic PCM fixtures. These are synthetic test signals, not recorded speech.
export function fixturePCM(seconds, channel, scenario, sampleRate = 16000) {
  const out = new Float32Array(sampleRate * 0.05);
  if (scenario === 'silence') return out;
  const cycle = (seconds + channel * 1.9) % 5.4;
  const talking = cycle < 3.3;
  const db = scenario === 'loud' ? -0.3 : talking ? -30 + 15 * Math.abs(Math.sin(seconds * 4.8 + channel)) : -90;
  const amplitude = 10 ** (db / 20);
  for (let i = 0; i < out.length; i++) out[i] = amplitude * Math.sin(2 * Math.PI * 200 * (seconds + i / sampleRate));
  return out;
}
