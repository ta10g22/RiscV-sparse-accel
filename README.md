# RISC-V AI Accelerator 

This repository contains my 3rd Year Individual Project at the University of Southampton:  
**Designing and benchmarking a custom RISC-V accelerator for machine learning workloads.**

---

## Project Overview
The goal of this project is to design, implement, and evaluate a hardware accelerator that extends a RISC-V core with **AI/ML-focused instructions**.  
The accelerator will support key ML operations (e.g. ReLU, pooling, sparse matrix multiplication) and introduce custom ISA extensions.

The design will be deployed on FPGA, benchmarked against CPU baselines, and analyzed for **performance, power, and area (PPA)** trade-offs.  
All code, documentation, and results will be maintained in this open-source repository.

---

## 🎯 Objectives
- Extend RISC-V ISA with ML-focused operations.
- Implement RTL modules in **SystemVerilog** (with systemverilog testbenches).
- Deploy accelerator to FPGA and run inference-style workloads.
- Benchmark performance (CPI, throughput, latency) vs CPU.
- Analyze energy and area efficiency.
- Provide clear GitHub documentation for reproducibility.

---

ai-accelerator/
├── rtl/        # SystemVerilog RTL modules
├── tb/         # Testbenches (SystemVerilog)
├── ip/         # RISC-V core and third-party IP
├── sw/         # RISC-V programs to exercise the accelerator
├── fpga/       # Quartus project files, pin assignments, SDC
├── docs/       # Block diagrams, notes, specifications
├── scripts/    # Build + utility scripts (Make, Python, Tcl)
├── sim/        # ModelSim scripts, build dirs, waveform outputs
└── README.md   # Project overview

---

## ✅ Success Criteria
- Correct execution of ML ops (validated against PyTorch/NumPy reference).
- Demonstrated FPGA deployment with working test program.
- ≥2× performance improvement over CPU baseline on benchmarked kernel.
- Documented trade-off analysis: power, performance, area (PPA).

---

## 🔮 Future Extensions
- Support for additional ML ops (e.g. convolution, activation functions).
- Integration with higher-level ML frameworks.
- Scaling to multi-core or systolic array design.
---

## 📚 References


## 📄 License
Open-source under MIT License.
