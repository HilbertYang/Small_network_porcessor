# Small Network Processor — SmartNIC on Xilinx Virtex-2 Pro

A custom SmartNIC design that integrates a multi-threaded RISC CPU, a SIMD/Tensor GPU accelerator, and a NetFPGA/NF2 packet-processing shell on a **Xilinx Virtex-2 Pro FPGA** (xc2vp30, ff896, speed grade -6).

The CPU core originates from [**mini-Processor**](https://github.com/HilbertYang/mini-Processor) and the GPU core from [**TinyGPGPU-Arch**](https://github.com/HilbertYang/TinyGPGPU-Arch). This repository combines them into a unified NF2.1-compatible accelerator system.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [Module Hierarchy](#module-hierarchy)
  - [CPU — multi-thread ARM-like pipeline](#cpu--multi-thread-arm-like-pipeline)
  - [GPU — SIMD/Tensor core](#gpu--simdtensor-core)
  - [Shared DMEM and Arbitration](#shared-dmem-and-arbitration)
  - [CPU–GPU Control Interface](#cpugpu-control-interface)
- [Instruction Sets](#instruction-sets)
  - [CPU ISA](#cpu-isa)
  - [GPU ISA](#gpu-isa)
- [Software Register Map](#software-register-map)
- [Repository Layout](#repository-layout)
- [Quick Start](#quick-start)
- [Simulation](#simulation)
- [Host Scripts](#host-scripts)
- [Build / Synthesis](#build--synthesis)
- [Development Status](#development-status)

---

## Overview

The design provides an in-network compute fabric that can run tensor/SIMD kernels (BFloat16 MAC, 4×i16 SIMD) while sitting in the packet datapath of an NF2.1 NetFPGA card. The architecture decouples the packet FIFO path from the compute path so the two can be brought up and validated independently.

**Key characteristics:**

| Feature | Detail |
|---------|--------|
| Target FPGA | Xilinx Virtex-2 Pro — xc2vp30-6ff896 |
| CPU | 5-stage ARM-like pipeline, 4 hardware threads, 64-bit registers |
| GPU | 5-stage SIMD/Tensor core, 4-lane BF16 + 4×i16, 16 GP registers |
| Shared memory | 256 × 64-bit dual-port BRAM |
| Host interface | NF2.1 register ring (software-accessible control/status registers) |
| RTL language | Verilog; synthesised with Xilinx ISE / XST |

---

## Architecture

### Module Hierarchy

```
user_data_path                       NF2.1 register-only wrapper; packet datapath tied off
  rtl/cpu_gpu_top/top_level/user_data_path.v
  └── cpu_gpu_dmem_top_regs          Host register interface
        └── cpu_gpu_dmem_top         Active CPU+GPU+shared-DMEM integration
              rtl/cpu_gpu_top/top_level/cpu_gpu_dmem_top.v
              ├── data_process_unit  CPU + GPU compute unit (external BRAM)
              │     rtl/cpu_gpu_top/top_level/data_process_unit.v
              │     ├── cpu_mt                   5-stage multi-threaded CPU
              │     │   rtl/cpu_gpu_top/cpu/cpu_arm_mt.v
              │     │     ├── REG_FILE_BANK      4-thread × 16 × 64-bit register file
              │     │     ├── ALU                64-bit scalar ALU
              │     │     ├── pc_target          4-thread PC manager (round-robin)
              │     │     ├── GPU_interface      CPU-to-GPU handshake & pipeline stall
              │     │     └── I_M_32bit_512depth CPU instruction memory (512 × 32-bit BRAM)
              │     └── gpu_core                 5-stage pipelined SIMD/Tensor GPU
              │         rtl/cpu_gpu_top/gpu/gpu_core3.v
              │               ├── control_unit   Combinational instruction decode
              │               ├── regfile        16 × 64-bit GP registers (R0 = 0)
              │               ├── param_regs     8 × 64-bit kernel parameter registers
              │               ├── alu_i16x4      4-lane 16-bit integer ALU + 64-bit addr ALU
              │               ├── tensor_core_bf16x4   4-lane BFloat16 tensor core
              │               │     └── tensor16_pipe3 × 4   4-stage BF16 MAC per lane
              │               │           └── multest3        Xilinx MULT18X18S (2-cycle DSP)
              │               └── I_M_32bit_512depth   GPU instruction memory
              └── D_M_64bit_256      Shared data memory (256 × 64-bit dual-port BRAM)
                                     Port A: host programming / future FIFO writes
                                     Port B: GPU (priority) / CPU shared access
```

Older or parallel integration paths also exist:

- **FIFO/packet path** — `rtl/fifo/src/processor.v` (`top_processor_system`) with associated FIFO buffers; intended for future reassembly with the CPU+GPU path.
- **Legacy SmartNIC wrapper** — `rtl/top_level/smartnic.v`; earlier integration experiment combining DMEM, IDS-FIFO, and `data_process_unit`.

### CPU — multi-thread ARM-like pipeline

Detailed design: [**HilbertYang/mini-Processor**](https://github.com/HilbertYang/mini-Processor)

The CPU (`cpu_mt`, defined in [rtl/cpu_gpu_top/cpu/cpu_arm_mt.v](rtl/cpu_gpu_top/cpu/cpu_arm_mt.v)) is a 5-stage ARM-like 32-bit pipeline extended with custom GPU-control and FIFO-streaming instructions.

- **4 hardware threads** — `pc_target` maintains 4 independent PCs; round-robin scheduling advances the thread ID on every pipeline `advance` pulse.
- **Register file** — banked 4 threads × 16 registers × 64-bit (`REG_FILE_BANK`); write-before-read forwarding within the same cycle.
- **No hardware hazard detection** — the programmer inserts NOPs to avoid RAW hazards.
- **Tensor Core stall** — MAC_BF16 / MUL_BF16 incur a 6-cycle pipeline stall (`TC_LATENCY = 6`) matching the BF16 tensor core latency.

Pipeline stages: IF → ID → EX → MEM → WB

### GPU — SIMD/Tensor core

Detailed design: [**HilbertYang/TinyGPGPU-Arch**](https://github.com/HilbertYang/TinyGPGPU-Arch)

The GPU (`gpu_core`, defined in [rtl/cpu_gpu_top/gpu/gpu_core3.v](rtl/cpu_gpu_top/gpu/gpu_core3.v)) is a 5-stage pipelined single-stream SIMD/Tensor accelerator (explicitly not SIMT).

- **SIMD model** — each 64-bit register holds 4 × i16 (or 4 × bf16) lanes packed as `[63:48|47:32|31:16|15:0]`.
- **TID convention** — thread ID increments by 4 per loop iteration; word address = TID/4 for 64-bit memory accesses covering 4 i16 elements.
- **BF16 tensor core** — 4-lane, 4-stage pipelined multiply-accumulate using Xilinx `MULT18X18S` DSP blocks.
- **Parameter registers** — 8 × 64-bit registers (`param_regs`) written by the CPU via the `WRP` instruction; read by the GPU via `LD_PARAM`.

Pipeline stages: IF → ID → EX → MEM → WB

### Shared DMEM and Arbitration

A single 256 × 64-bit dual-port BRAM (`D_M_64bit_256`) is shared between the CPU, GPU, and host:

| Port | Primary use |
|------|-------------|
| Port A | Host programming; future FIFO packet writes |
| Port B | GPU (priority when `gpu_mem_access=1`) then CPU |

GPU priority is set by `gpu_mem_access`, which is asserted together with `gpu_run`.

### CPU–GPU Control Interface

The `GPU_interface` module manages the handshake:

1. CPU executes `GPU_RUN` → `GPU_interface` asserts `gpu_run` and **deasserts `advance`**, freezing the CPU pipeline.
2. GPU executes its kernel using shared DMEM.
3. GPU asserts `done` → `GPU_interface` sees `gpu_done`, releases `advance`, CPU resumes.

The `WRP Rs,#imm3` instruction allows the CPU to write kernel parameters into the GPU's `param_regs` before launching.

IMEM is selected by the `imem_sel` bit: `0` → GPU instruction memory, `1` → CPU instruction memory.

---

## Instruction Sets

### CPU ISA

32-bit ARM-like encoding with custom extensions. Instruction categories:

| Category | Instructions |
|----------|-------------|
| Data processing | `ADD`, `SUB`, `AND`, `ORR`, `EOR`, `MOV`, `SLT` |
| Shift | `SLL`, `SRL` |
| Memory | `LDR`, `STR` |
| Branch | `B`, `BL`, `BEQ`, `BNE`, `BX`, `J` |
| GPU control | `GPU_RUN`, `WRP Rs,#imm3` |
| FIFO streaming | `RDF Rd,#sel`, `FIFOWAIT`, `FIFODONE` |
| Special | `NOP` |

Custom instruction encodings (`inst[31:24]`):

| Instruction | Encoding `[31:24]` | Description |
|-------------|-------------------|-------------|
| `GPU_RUN` | `8'b10101101` | Launch GPU kernel; stall CPU until `gpu_done` |
| `WRP Rs,#imm3` | `8'b10101110` | Write `RF[Rs]` to GPU param register at `imm3` |
| `RDF Rd,#sel` | `8'b10101111` | Read FIFO offset into `Rd` (sel=0: start, sel=1: end) |
| `FIFOWAIT` | `8'b10101100` | Stall until `fifo_data_ready` is high |
| `FIFODONE` | `8'b10101011` | Assert `fifo_data_done` for one cycle |

### GPU ISA

32-bit, 5-bit opcode. Instruction format: `[31:27]=OPCODE [26:23]=RD [22:19]=RS1 [18:15]=RS2 [14:0]=IMM15`

| Opcode | Hex | Operation |
|--------|-----|-----------|
| `NOP` | `0x00` | No operation |
| `ADD_I16` | `0x01` | RD = RS1 + RS2 (4×i16 SIMD) |
| `SUB_I16` | `0x02` | RD = RS1 − RS2 (4×i16 SIMD) |
| `MAX_I16` | `0x03` | RD = max(RS1, RS2) (4×i16, ReLU) |
| `ADD64` | `0x04` | RD = RS1 + RS2 (64-bit scalar) |
| `ADDI64` | `0x05` | RD = RS1 + sign_ext(imm15) |
| `SETP_GE` | `0x06` | PRED = (RS1[31:0] ≥ RS2[31:0]) |
| `SHIFTLV` | `0x07` | RD = RS1 (stub — shift not yet implemented) |
| `SHIFTRV` | `0x08` | RD = RS1 (stub — shift not yet implemented) |
| `MAC_BF16` | `0x09` | RD = RS1 × RS2 + RD (4×bf16 MAC, 6-cycle latency) |
| `MUL_BF16` | `0x0a` | RD = RS1 × RS2 (4×bf16 multiply, 6-cycle latency) |
| `LD64` | `0x10` | RD = DMEM[RS1 + imm15] |
| `ST64` | `0x11` | DMEM[RS1 + imm15] = RD |
| `MOV` | `0x12` | RD = sign_ext(imm15) |
| `BPR` | `0x13` | if PRED: PC = imm15[8:0] |
| `BR` | `0x14` | PC = imm15[8:0] |
| `RET` | `0x15` | Halt (assert `done`) |
| `LD_PARAM` | `0x16` | RD = PARAM[imm15[2:0]] |

---

## Software Register Map

Registers accessed through the NF2.1 register ring (active path: `cpu_gpu_dmem_top_regs`).

**Software-writable (host → hardware):**

| Offset | Name | Bits | Purpose |
|--------|------|------|---------|
| 0 | `sw_ctrl` | [0] run, [1] step, [2] pc_reset, [3] imem_prog_we, [4] dmem_prog_en, [5] dmem_prog_we, [6] imem_sel | Run / program control |
| 1 | `sw_imem_addr` | [8:0] | IMEM program address |
| 2 | `sw_imem_wdata` | [31:0] | IMEM write data |
| 3 | `sw_dmem_addr` | [7:0] | DMEM program address |
| 4 | `sw_dmem_wdata_lo` | [31:0] | DMEM write data [31:0] |
| 5 | `sw_dmem_wdata_hi` | [31:0] | DMEM write data [63:32] |
| 6 | `sw_fifo_ctrl` | [7:0] fifo_start_offset, [15:8] fifo_end_offset, [16] fifo_data_ready | FIFO boundary/control |
| 7 | reserved | — | — |

**Hardware-readable (hardware → host):**

| Offset | Name | Purpose |
|--------|------|---------|
| 0 | `hw_cpu_pc_dbg` | CPU current PC |
| 1 | `hw_cpu_if_instr` | CPU IF-stage instruction word |
| 2 | `hw_gpu_pc_dbg` | GPU current PC |
| 3 | `hw_gpu_if_instr` | GPU IF-stage instruction word |
| 4 | `hw_dmem_rdata_lo` | DMEM read data [31:0] |
| 5 | `hw_dmem_rdata_hi` | DMEM read data [63:32] |
| 6 | `hw_done` | GPU kernel completion flag |
| 7 | `hw_fifo_data_done` | CPU/FIFO completion signal |
| 8 | `hw_hb` | Heartbeat counter |

> **`imem_sel`**: `0` programs the GPU instruction memory; `1` programs the CPU instruction memory. Both share the same `imem_prog_addr`/`imem_prog_wdata` bus.

---

## Repository Layout

```
rtl/
  cpu_gpu_top/
    cpu/              CPU modules: cpu_arm_mt, ALU, REG_FILE_BANK, pc_target,
                      GPU_interface, I_M_32bit_512depth
    gpu/              GPU modules: gpu_core3, control_unit, regfile, param_regs,
                      alu_i16x4, tensor_core_bf16x4, tensor16_pipe3, multest3
    gpu/tb/           Legacy GPU-only testbenches
    top_level/        Active CPU+GPU bring-up: cpu_gpu_dmem_top, data_process_unit,
                      cpu_gpu_dmem_top_regs, user_data_path
  fifo/src/           FIFO/packet-path RTL: processor, fifo, cvfifo, user_data_path
  fifo/top_level/     Older FIFO integration copies
  top_level/          Legacy SmartNIC wrapper: smartnic, smartnic_top_regs,
                      user_data_path, ids_ff_top, convertable_fifo

sim/
  cpu_gpu/            Active CPU+GPU simulation testbenches
  script/             ISim log-cleaning utilities

scripts/
  CPU_GPU/
    cpu_gpu_reg.py        Unified register interface wrapper
    cpu_gpu_script/       CPU+GPU host scripts (init, step, reg)
    gpu_script/           GPU-only host scripts (init, step, reg)
  smartnic/             SmartNIC-targeted init/step/reg scripts

bin/
  make/project/         Bitfile-generation staging workspace (may lag active RTL)
  make/result/          Archived bitstreams / packaged outputs
```

> **Note on repeated filenames**: `user_data_path.v`, `processor.v`, and similar names appear in multiple subtrees with unrelated implementations. Always reason using full paths.

---

## Quick Start

This repository currently has **two practical entry points**, depending on whether you want to inspect behavior in simulation or interact with hardware through the NF2 register interface.

### 1. Simulation-first bring-up

- Start from `sim/cpu_gpu/`; this is the active verification area for the CPU+GPU register-controlled integration.
- Recommended first testbench:
  - [tb_cpu_gpu_dmem_top.v](sim/cpu_gpu/tb_cpu_gpu_dmem_top.v) for an end-to-end CPU-launches-GPU flow
- Other focused bring-up tests:
  - [tb_cpu_gpu_fifo_inst.v](sim/cpu_gpu/tb_cpu_gpu_fifo_inst.v) for `RDF` / `FIFOWAIT` / `FIFODONE`
  - [tb_cpu_gpu_param.v](sim/cpu_gpu/tb_cpu_gpu_param.v) for `WRP` and `GPU_RUN`
  - [tb_smallest_test_fma.v](sim/cpu_gpu/tb_smallest_test_fma.v) for BF16 MAC/FMA behavior

Simulation assumes a Xilinx ISim-era flow. The repository does not currently provide a checked-in one-command simulation wrapper, so compile/elaboration is expected to be done in your local ISim/ISE environment.

### 2. Hardware register bring-up

The active host-side flow is the CPU+GPU register wrapper in:

- [cpu_gpu_dmem_top_regs.v](rtl/cpu_gpu_top/top_level/cpu_gpu_dmem_top_regs.v)
- [user_data_path.v](rtl/cpu_gpu_top/top_level/user_data_path.v)

Typical sequence:

1. Program IMEM/DMEM with [cpugpu_init.py](scripts/CPU_GPU/cpu_gpu_script/cpugpu_init.py)
2. Start or step execution with [cpugpu_step.py](scripts/CPU_GPU/cpu_gpu_script/cpugpu_step.py)
3. Inspect state with [cpugpureg.py](scripts/CPU_GPU/cpu_gpu_script/cpugpureg.py) or [cpu_gpu_reg.py](scripts/CPU_GPU/cpu_gpu_reg.py)

Example commands:

```bash
python scripts/CPU_GPU/cpu_gpu_script/cpugpu_init.py
python scripts/CPU_GPU/cpu_gpu_script/cpugpureg.py run 1
python scripts/CPU_GPU/cpu_gpu_script/cpugpureg.py done_check
python scripts/CPU_GPU/cpu_gpu_script/cpugpureg.py allregs
```

Prerequisites:

- NetFPGA/NF2 userspace utilities providing `regwrite` and `regread`
- Python environment compatible with the script shebangs in `scripts/` (`python` and `python3` are both used in this repo)
- Register definitions matching the active block address map in your NF2 build

If you only want one host utility, prefer [cpu_gpu_reg.py](scripts/CPU_GPU/cpu_gpu_reg.py): it is the clearest consolidated register helper in the current tree.

---

## Simulation

All active testbenches live in `sim/cpu_gpu/` and target `cpu_gpu_dmem_top`.

| Testbench | DUT | Description |
|-----------|-----|-------------|
| [tb_cpu_gpu_dmem_top.v](sim/cpu_gpu/tb_cpu_gpu_dmem_top.v) | `cpu_gpu_dmem_top` | Full system; task-based IMEM/DMEM programming; run-until-done |
| [tb_cpu_gpu_fifo_inst.v](sim/cpu_gpu/tb_cpu_gpu_fifo_inst.v) | `cpu_gpu_dmem_top` | CPU FIFO-instruction tests (`RDF`, `FIFOWAIT`, `FIFODONE`) |
| [tb_smallest_test_fma.v](sim/cpu_gpu/tb_smallest_test_fma.v) | `cpu_gpu_dmem_top` | BF16 FMA kernel (MAC_BF16 loop, 3 iterations) |
| [tb_smallest_test.v](sim/cpu_gpu/tb_smallest_test.v) | `cpu_gpu_dmem_top` | Basic integer ADD_I16 test |
| [tb_cpu_gpu_param.v](sim/cpu_gpu/tb_cpu_gpu_param.v) | `cpu_gpu_dmem_top` | Parameter register read/write |
| [tb_sort_arm_mt.v](sim/cpu_gpu/tb_sort_arm_mt.v) | `cpu_top_with_Mem` | CPU-only memory-backed sort benchmark for the multithreaded core |

Simulation is run with **Xilinx ISim**. The `sim/script/clean.py` utility strips ISim-specific noise from log output.

---

## Host Scripts

Python scripts in `scripts/` communicate with the hardware via NF2 `regwrite`/`regread` commands.

Important assumptions for these scripts:

- `regwrite` and `regread` must already be installed and available in `PATH`
- Several scripts use `#!/usr/bin/env python` while others use `python3`; use an environment where both resolve correctly, or invoke scripts explicitly with your desired interpreter
- Address constants in the helpers assume the active CPU+GPU register block is mapped at the expected NF2 address range

| Script | Purpose |
|--------|---------|
| [cpu_gpu_reg.py](scripts/CPU_GPU/cpu_gpu_reg.py) | Unified register interface (top-level wrapper) |
| [cpugpu_init.py](scripts/CPU_GPU/cpu_gpu_script/cpugpu_init.py) | 3-phase init: GPU IMEM → CPU IMEM → DMEM; encodes BF16 MAC kernel |
| [cpugpu_step.py](scripts/CPU_GPU/cpu_gpu_script/cpugpu_step.py) | CPU+GPU step/run control |
| [cpugpureg.py](scripts/CPU_GPU/cpu_gpu_script/cpugpureg.py) | Register read/write helper |
| [gpu_init.py](scripts/CPU_GPU/gpu_script/gpu_init.py) | GPU-only init (DMEM + PARAM + IMEM) |
| [gpu_init_FMA.py](scripts/CPU_GPU/gpu_script/gpu_init_FMA.py) | GPU FMA-specific init variant |
| [gpu_step.py](scripts/CPU_GPU/gpu_script/gpu_step.py) | GPU-only step/run control |
| [gpureg.py](scripts/CPU_GPU/gpu_script/gpureg.py) | GPU-only register helper |
| [smartnic_init_fma.py](scripts/smartnic/smartnic_init_fma.py) | SmartNIC FMA kernel init |
| [smartnic_init_passThough.py](scripts/smartnic/smartnic_init_passThough.py) | SmartNIC pass-through init |

---

## Build / Synthesis

Synthesis uses **Xilinx ISE** (XST back-end) targeting the xc2vp30-6ff896 device. The authoritative hardware sources are the RTL files under `rtl/`; the checked-in build collateral under `bin/make/project/` is a staging/archive area rather than the source of truth. In practice, the flow is driven either through the ISE GUI or by invoking `xst`, `ngdbuild`, `map`, `par`, and `bitgen` manually.

There is a small Makefile in `bin/make/project/`, but it is for project-side register/software generation and should not be interpreted as a complete, current top-level build flow for the active CPU+GPU integration.

The `bin/make/project/` directory is a staging workspace for bitfile generation and **may intentionally lag behind the active RTL** in `rtl/cpu_gpu_top/`. Do not treat it as the source of truth for architecture or debugging.

> `multest3.v` is simulation-only (Xilinx `MULT18X18S` primitive with `// synthesis translate_off` guards). Use the corresponding `.ngc` netlist for synthesis.

---

## Development Status

Three integration tracks are in progress:

| Track | Location | Status |
|-------|----------|--------|
| **CPU+GPU register bring-up** (active) | `rtl/cpu_gpu_top/top_level/` | Primary development target |
| **FIFO / packet-path RTL** | `rtl/fifo/` | Standalone; not yet reintegrated with CPU+GPU |
| **Legacy SmartNIC wrapper** | `rtl/top_level/` | Older experiment; partially complete |

The final intended system — FIFO + CPU + GPU in a single NF2.1-compatible top-level — still requires reassembly from the active tracks above.

---

## Related Repositories

| Repository | Role in this project |
|------------|---------------------|
| [HilbertYang/TinyGPGPU-Arch](https://github.com/HilbertYang/TinyGPGPU-Arch) | Source of the SIMD/Tensor GPU core (`gpu_core3`), BF16 tensor pipeline, and GPU ISA |
| [HilbertYang/mini-Processor](https://github.com/HilbertYang/mini-Processor) | Source of the multi-threaded ARM-like CPU (`cpu_arm_mt`), register file, and CPU ISA |
