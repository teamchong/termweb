#!/usr/bin/env bun
/**
 * Bandwidth benchmark report: fetches live stats from a running termweb
 * instance (built with -Dbenchmark) and prints a VT vs H264+zstd comparison.
 *
 * Usage:
 *   1. Build with benchmark:  make benchmark
 *   2. Run termweb and use it normally (ls, btm, claude, etc.)
 *   3. Generate report:       make benchmark-report
 *
 *   bun run packages/mux/benchmark/run.ts [--port 7681]
 */

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
function getArg(name: string, fallback: string): string {
  const idx = args.indexOf(`--${name}`);
  return idx >= 0 && args[idx + 1] ? args[idx + 1] : fallback;
}

const PORT = parseInt(getArg("port", "7681"), 10);
const BASE = `http://localhost:${PORT}`;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${bytes} B`;
}

function formatRate(bytes: number, seconds: number): string {
  if (seconds <= 0) return "N/A";
  return `${formatBytes(bytes / seconds)}/s`;
}

interface Stats {
  elapsed_ms: number;
  h264_bytes: number;
  h264_frames: number;
  control_bytes_sent: number;
  control_bytes_recv: number;
  raw_pixels_bytes: number;
  vt_bytes: number;
  total_ws_bytes: number;
  commands: string[];
}

async function fetchStats(): Promise<Stats> {
  const res = await fetch(`${BASE}/api/benchmark/stats`);
  if (!res.ok) throw new Error(`Stats endpoint returned ${res.status}`);
  return res.json();
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

function printReport(stats: Stats): void {
  const elapsed_s = stats.elapsed_ms / 1000;
  const vtBytes = stats.vt_bytes;
  const h264Bytes = stats.h264_bytes;
  const ctrlSent = stats.control_bytes_sent;
  const ctrlRecv = stats.control_bytes_recv;
  const totalWs = h264Bytes + ctrlSent;
  const rawPx = stats.raw_pixels_bytes;
  const commands = stats.commands.length > 0 ? stats.commands : ["(idle)"];

  console.log("");
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log("║          Termweb Bandwidth Benchmark Report                 ║");
  console.log("║          VT Passthrough vs H264 + zstd                      ║");
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");

  // Session info
  console.log(`  Session duration:  ${elapsed_s.toFixed(1)}s`);
  console.log(`  Commands seen:     ${commands.join(", ")}`);
  console.log("");

  // Main comparison
  console.log("  ┌─────────────────────────────────────────────────────────┐");
  console.log("  │  Approach              │  Total Bytes  │  Rate         │");
  console.log("  ├─────────────────────────────────────────────────────────┤");
  console.log(`  │  VT Passthrough        │  ${formatBytes(vtBytes).padEnd(13)}│  ${formatRate(vtBytes, elapsed_s).padEnd(13)}│`);
  console.log(`  │  H264 + zstd (termweb) │  ${formatBytes(totalWs).padEnd(13)}│  ${formatRate(totalWs, elapsed_s).padEnd(13)}│`);
  console.log("  └─────────────────────────────────────────────────────────┘");
  console.log("");

  // Ratio and savings
  if (vtBytes > 0) {
    const ratio = totalWs / vtBytes;
    if (totalWs < vtBytes) {
      const saving = ((1 - ratio) * 100).toFixed(1);
      console.log(`  Result: H264+zstd saves ${saving}% bandwidth (${ratio.toFixed(2)}x ratio)`);
    } else {
      const overhead = ((ratio - 1) * 100).toFixed(1);
      console.log(`  Result: H264+zstd uses ${overhead}% more bandwidth (${ratio.toFixed(2)}x ratio)`);
    }
  } else {
    console.log("  Result: No VT bytes recorded (terminal may be idle)");
  }
  console.log("");

  // Detailed breakdown
  console.log("  Detailed Breakdown:");
  console.log("  ───────────────────");
  console.log(`    VT bytes (raw PTY output):       ${formatBytes(vtBytes)}`);
  console.log(`    H264 video bytes:                ${formatBytes(h264Bytes)} (${stats.h264_frames} frames)`);
  console.log(`    Control channel sent (zstd):     ${formatBytes(ctrlSent)}`);
  console.log(`    Control channel received:        ${formatBytes(ctrlRecv)}`);
  console.log(`    Total WebSocket out:             ${formatBytes(totalWs)}`);
  console.log(`    Raw BGRA pixels captured:        ${formatBytes(rawPx)}`);
  if (rawPx > 0 && h264Bytes > 0) {
    console.log(`    H264 compression ratio (vs raw): ${(rawPx / h264Bytes).toFixed(0)}:1`);
  }
  console.log("");

  // Key takeaways
  console.log("  Key Insights:");
  console.log("  ─────────────");
  console.log("  • VT passthrough sends raw escape sequences — bandwidth scales with output volume");
  console.log("  • H264+zstd has bounded bandwidth (capped by bitrate), regardless of terminal output");
  console.log("  • Heavy workloads (claude code, cat large files) cause VT clients to lag;");
  console.log("    H264 decoding is constant-time via hardware acceleration");
  console.log("");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  const stats = await fetchStats();
  printReport(stats);
} catch (err) {
  console.error(`\nError: Cannot connect to termweb at ${BASE}`);
  console.error("Make sure termweb is running with benchmark enabled:");
  console.error("  1. Build:  make benchmark");
  console.error("  2. Run:    ./zig-out/bin/termweb");
  console.error("  3. Use the terminal (run commands, browse, etc.)");
  console.error("  4. Report: make benchmark-report\n");
  process.exit(1);
}
