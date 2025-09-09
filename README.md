# RISC-V AI Accelerator 🚀

This repository contains my 3rd Year Individual Project at the University of Southampton:  
**Designing and benchmarking a custom RISC-V accelerator for machine learning workloads.**

---

## 📌 Project Overview
The goal of this project is to design, implement, and evaluate a hardware accelerator that extends a RISC-V core with **AI/ML-focused instructions**.  
The accelerator will support key ML operations (e.g. ReLU, pooling, sparse matrix multiplication), integrate vector-like instructions, and introduce custom ISA extensions.

The design will be deployed on FPGA, benchmarked against CPU baselines, and analyzed for **performance, power, and area (PPA)** trade-offs.  
All code, documentation, and results will be maintained in this open-source repository.

---

## 🎯 Objectives
- Extend RISC-V ISA with ML-focused operations.
- Implement RTL modules in **SystemVerilog** (with Python-based testbenches).
- Deploy accelerator to FPGA and run inference-style workloads.
- Benchmark performance (CPI, throughput, latency) vs CPU.
- Analyze energy and area efficiency.
- Provide clear GitHub documentation for reproducibility.

---

## 🗂️ Repository Structure
ai-accelerator/
│── docs/ # Project notes, ISA extensions, design diagrams
│── rtl/ # SystemVerilog RTL modules
│── tb/ # Testbenches (SystemVerilog + Python)
│── scripts/ # Build and simulation scripts (Makefiles, Verilator, etc.)
│── sw/ # Example RISC-V programs to exercise accelerator
│── results/ # Benchmark data, plots, PPA analysis
│── README.md # This file

---

## 📚 References
- [RISC-V ISA Specifications](https://riscv.org/technical/specifications/)
- [Gemmini Accelerator (Berkeley)](https://github.com/ucb-bar/gemmini)
- [Apache TVM VTA](https://tvm.apache.org/docs/vta/index.html)
- ARM/FPGA textbooks and lecture notes (University of Southampton modules)

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

## 📄 License
Open-source under MIT License.
