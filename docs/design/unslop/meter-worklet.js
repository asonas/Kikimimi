class SamplePeakProcessor extends AudioWorkletProcessor {
  constructor() { super(); this.frames = 0; this.peak = 0; }
  process(inputs) {
    const channel = inputs[0]?.[0];
    if (channel) for (const sample of channel) {
      if (Number.isFinite(sample)) this.peak = Math.max(this.peak, Math.abs(sample));
      this.frames++;
      if (this.frames >= Math.round(sampleRate * 0.05)) {
        this.port.postMessage(this.peak > 0 ? Math.max(-120,20*Math.log10(this.peak)) : -120);
        this.peak = 0; this.frames = 0;
      }
    }
    // Outputs stay zero; microphone audio is never played through the speakers.
    return true;
  }
}
registerProcessor('sample-peak', SamplePeakProcessor);
