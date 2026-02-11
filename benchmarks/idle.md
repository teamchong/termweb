```
bun run packages/mux/benchmark/run.ts --port 7681

╔══════════════════════════════════════════════════════════════╗
║          Termweb Bandwidth Benchmark Report                  ║
║          VT Passthrough vs H264 + zstd                       ║
╚══════════════════════════════════════════════════════════════╝

  Session duration:  67.7s
  Commands seen:     sh, bash

  ┌─────────────────────────────────────────────────────────────────┐
  │  Approach              │  Bytes (↑)    │  Rate                  │
  ├─────────────────────────────────────────────────────────────────┤
  │  VT Passthrough        │  29.2 KB      │  441.03306639874705 B/s│
  │  H264 + zstd (termweb) │  30.7 KB      │  465.0571791613723 B/s │
  └─────────────────────────────────────────────────────────────────┘

  Result: H264+zstd uses 5.4% more bandwidth (1.05x ratio)

  Detailed Breakdown:
  ───────────────────
    VT bytes (raw PTY output):       29.2 KB
    H264 video bytes:                30.6 KB (2 frames)
    Control channel sent (zstd):     191 B
    Control channel received:        1.1 KB
    Raw BGRA pixels captured:        33332.63 MB
    H264 compression ratio (vs raw): 1117206:1

  Notes:
  ──────
  • Comparison is server→client output only (input is equivalent for both)
  • VT passthrough sends raw escape sequences — bandwidth scales with output volume
  • H264+zstd has bounded bandwidth (capped by bitrate), regardless of terminal output
  • Heavy workloads (claude code, cat large files) cause VT clients to lag;
    H264 decoding is constant-time via hardware acceleration
```