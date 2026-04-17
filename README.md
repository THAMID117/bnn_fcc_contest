# BNN_FCC Hardware Design Contest

This repository contains a submission-ready implementation of the `bnn_fcc` binary neural network classifier for the Apple / EEL6935 design contest. The design targets the contest MNIST SFC topology `784 -> 256 -> 256 -> 10` and is verified with the provided AXI4-Stream-based infrastructure.

The top-level DUT is [rtl/bnn_fcc.sv](rtl/bnn_fcc.sv). Interface details are documented in [rtl/README.md](rtl/README.md). Testbench details are documented in [verification/README.md](verification/README.md). Openflex timing and verification flows are documented in [openflex/README.md](openflex/README.md).

## Submission Candidate

The canonical submission configuration used across the DUT, required verification testbench, coverage testbench, and timing wrapper is:

- `PARALLEL_INPUTS = 8`
- `PARALLEL_NEURONS = '{8, 8, 1}`

This is a deliberate high-frequency tradeoff. The hidden layers keep `8` lanes each to preserve simple packing and BRAM-friendly organization, while the output layer is serialized to reduce routed timing pressure.

## Repository Layout

```text
.
├── rtl/                     # DUT source and interface documentation
│   ├── bnn_fcc.sv
│   └── README.md
├── verification/            # Required and additional testbenches
│   ├── axi4_stream_if.sv
│   ├── bnn_fcc_tb_pkg.sv
│   ├── bnn_fcc_tb.sv
│   ├── bnn_fcc_coverage_tb.sv
│   ├── coverage_plan.txt
│   └── README.md
├── openflex/                # Openflex YAML flows, timing wrapper, helper patch
│   ├── bnn_fcc_verify.yml
│   ├── bnn_fcc_coverage.yml
│   ├── bnn_fcc_timing.yml
│   ├── patch_openflex_parser.py
│   ├── README.md
│   └── rtl/bnn_fcc_timing.sv
├── python/                  # Model data and reference test vectors
├── doc/                     # Background slides and supporting material
├── report.tex               # Canonical report source
└── report.md                # Short pointer to the LaTeX report source
```

## Tools and Target

- HDL: SystemVerilog (IEEE 1800-2012)
- Simulator: Siemens Questa/ModelSim or equivalent
- Synthesis / PnR: Xilinx Vivado
- FPGA target used for timing: `XCU250-FIGD2104-2L-E`

## Quick Start

### 1. Create a simulator working directory

From the repository root:

```bash
mkdir -p sim
cd sim
vlib work
```

### 2. Compile the RTL and testbenches

```bash
vlog -sv ../rtl/bnn_fcc.sv \
         ../verification/axi4_stream_if.sv \
         ../verification/bnn_fcc_tb_pkg.sv \
         ../verification/bnn_fcc_tb.sv \
         ../verification/bnn_fcc_coverage_tb.sv \
         ../openflex/rtl/bnn_fcc_timing.sv
```

### 3. Run the required functional testbench

This is the direct Questa flow corresponding to the provided top-level testbench:

```bash
vsim -c work.bnn_fcc_tb -do "run -all; quit -f" | tee tb_out.txt
grep -E "SUCCESS:|FAILED:|Avg latency|Avg throughput" tb_out.txt
```

### 4. Run the performance-oriented test

Use the measured `fMax` as the testbench clock period and disable external throttling:

```bash
vsim -c work.bnn_fcc_tb \
  -gCLK_PERIOD=2.497ns \
  -gTOGGLE_DATA_OUT_READY=0 \
  -gCONFIG_VALID_PROBABILITY=1.0 \
  -gDATA_IN_VALID_PROBABILITY=1.0 \
  -do "run -all; quit -f" | tee perf_out.txt

grep -E "SUCCESS:|Avg latency|Avg throughput" perf_out.txt
```

### 5. Run the additional coverage-oriented testbench

```bash
vsim -c work.bnn_fcc_coverage_tb -do "run -all; quit -f" | tee coverage_tb_out.txt
tail -n 40 coverage_tb_out.txt
```

### 6. Run the openflex verification and timing flows

From the repository root:

```bash
cd openflex
source ~/envs/openflex/bin/activate
```

If openflex crashes after a successful Vivado run with a parser error on fractional utilization such as `12.5`, patch the installed parser:

```bash
python patch_openflex_parser.py --check
python patch_openflex_parser.py
```

Then run:

```bash
openflex bnn_fcc_verify.yml | tee verify_out.txt
openflex bnn_fcc_coverage.yml | tee coverage_out.txt
openflex bnn_fcc_timing.yml -c bnn_fcc.csv | tee timing_out.txt
```

Useful summaries:

```bash
grep -E "SUCCESS:|FAILED:|FAILURE:" verify_out.txt
grep -E "SUCCESS:|Avg latency|Avg throughput" ../sim/perf_out.txt
grep -E "WNS|Post Physical Optimization Timing Summary|8-7052|8-7030|8-6904" timing_out.txt
cat bnn_fcc.csv
```

## Current Reported Results

The latest timing and resource result captured for the canonical submission candidate is:

- `fMax = 400.48057669203047 MHz`
- `LUT = 3066`
- `FF = 1818`
- `BRAM = 12.5`
- `DSP = 0`

The additional coverage-oriented testbench reported:

- `config_msg_cov = 95.8%`
- `keep_cov = 85.4%`
- `valid_mode_cov = 100.0%`
- `ready_mode_cov = 100.0%`
- `reset_cov = 100.0%`
- `output_cov = 100.0%`
- `output_seq_cov = 100.0%`
- `threshold_cov = 94.4%`
- `weight_cov = 88.9%`
- `average covergroup = 96.1%`

The LaTeX report source in [report.tex](report.tex) contains the full writeup, exact reproduction commands, and result tables.

Important: the required top-level testbench defaults were synchronized to the canonical submission candidate during final repo cleanup. Rerun the required functional testbench, the performance-oriented run, and `openflex bnn_fcc_verify.yml` before freezing the final `report.pdf`.

## Report Build

Build the submission PDF from the repository root with:

```bash
latexmk -pdf report.tex
```

If `latexmk` is not installed, use:

```bash
pdflatex report.tex
pdflatex report.tex
```

This produces `report.pdf`, which is the file intended for submission.

## Submission Checklist

Before submitting the repository:

1. Rerun the required functional testbench and confirm the success banner.
2. Rerun the coverage-oriented testbench and confirm the printed coverage summary.
3. Rerun `openflex bnn_fcc_verify.yml` and confirm a clean pass.
4. Rerun `openflex bnn_fcc_timing.yml -c bnn_fcc.csv` and confirm the reported timing and area figures.
5. Build `report.pdf` from [report.tex](report.tex).
6. Verify that the repository root contains the final report and that the commands in the report still match the repo contents.

## Upstream Syncing

If the organizers update the template repository and you need to merge those changes:

```bash
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```
