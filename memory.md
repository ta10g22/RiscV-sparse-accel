# Project Memory: RISC-V Sparse Matrix Accelerator

## Long-Term Goals (User-Aligned)
- Build deep, full-stack understanding of this project end-to-end (RTL, firmware, SoC integration, benchmarking, reporting).
- Produce a final report and final-year project outcome stronger than the 91% CNN accelerator report benchmark.
- Keep the technical focus on SpMM acceleration (not broadening scope away from the core kernel).
- Improve literature depth and evaluation rigor to top-grade standard.

## Original Brief (Added 2026-03-03)
- Source: `Part_III_broject_brief.pdf`
- Core brief goals:
  - SpMM + ReLU accelerator on DE1-SoC (Cyclone V), RISC-V soft-core integration via MMIO.
  - CPU baseline in C, hardware acceleration in SystemVerilog.
  - Evaluate correctness, speed, energy, and area (PPA) vs CPU.
  - Validate against NumPy/PyTorch reference flow.
- Stretch goals from brief:
  - INT8 quantized datapath.
  - Optional max-pooling/activation extensions.
  - Custom RISC-V instruction wrapper/trap to MMIO engine.

## Current Technical Status
- Working SoC integration with PicoRV32 + accelerator + on-chip RAM.
- Firmware benchmark path implemented and deployed.
- Demonstrated board result code: `42 FF 08` (decoded as ~`8x` speedup claim, with known display clipping limits).
- Report has been substantially updated from placeholder state to structured technical draft.

## Important Ground Truth (Interrupt vs Polling)
- Current firmware completion path uses polling:
  - `accel_wait_done()` spin-waits on `STATUS_DONE`.
- Interrupt bit exists in MMIO (`CTRL_IRQ_EN`) but is not used end-to-end in current integrated build:
  - CPU in `soc_top` has `ENABLE_IRQ = 0`.
  - CPU `irq` input is tied to zero.
  - Accelerator `irq` output is not connected in `soc_top`.
- Conclusion: current operation is polling-based, not interrupt-driven.

## Report Progress Snapshot
- Main report compiles locally (`docs/my_report/main.pdf`).
- Placeholder-heavy sections replaced with concrete architecture/evaluation narrative.
- Benchmark section includes decoded evidence and limitations.
- Initial bibliography and citations added; literature depth still below target for top-band marking.

## Open Gaps to Reach Top-Band Quality
- Evaluation depth: broader benchmark campaign and stronger traceability of raw measurements.
- Literature depth: more high-quality, directly relevant sparse-acceleration and benchmarking references.
- PPA section: explicit post-fit area/timing/power evidence and fair CPU-vs-accelerator comparison methodology.
- Correctness evidence: stronger multi-layer validation workflow (software gold model, regression dataset, edge cases).

## Next Milestone Focus
- Strengthen benchmarking methodology for the SpMM workload family (matrix size/sparsity sweeps, repeatability, confidence).
- Add professional correctness verification evidence and reproducible experiment protocol.
- Add PPA comparison using Quartus reports + consistent CPU/accelerator measurement boundaries.
