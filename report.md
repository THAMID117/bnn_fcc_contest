# BNN_FCC Contest Report

## Executive Summary

| Item | Result |
| :--- | :--- |
| Required `bnn_fcc_tb` verification | `PASS` |
| Additional coverage testbench | `PASS` |
| Openflex verification (`bnn_fcc_verify.yml`) | `PASS` |
| Fmax (MHz) | `381.53` |
| Throughput (outputs/sec) | `TBD` |
| Avg latency (cycles/image) | `TBD` |
| LUTs | `3232` |
| FFs | `1815` |
| BRAM | `12.5` |
| DSPs | `0` |

## Targeted Use Case

This design targets a high-frequency, verification-conscious operating point rather than maximum raw spatial parallelism. The architecture keeps the critical path short by:

* Processing one layer at a time
* Reusing a bounded set of neuron lanes within the active layer
* Storing weights in `PARALLEL_INPUTS`-wide packed words
* Keeping hidden-layer interconnect simple by matching hidden-layer `PARALLEL_NEURONS` to `PARALLEL_INPUTS`

For the contest configuration, the implementation uses:

* `PARALLEL_INPUTS = 8`
* `PARALLEL_NEURONS = '{8, 8, 1}`

This is an intentional tradeoff: it reduces configuration and inter-layer complexity, keeps the XNOR/popcount/accumulate datapath narrow, serializes the small output layer to reduce timing pressure, and is favorable for out-of-context `fmax` in the provided openflex flow.

## RTL Overview

The top-level DUT is implemented in [`rtl/bnn_fcc.sv`](rtl/bnn_fcc.sv).

Key architectural choices:

* The configuration stream is parsed internally and stored into packed weight memory plus threshold memory.
* Configuration order is not hard-coded to a single layer/message sequence; messages are decoded from the provided headers.
* Images are accepted via AXI4-Stream, binarized against `8'd128`, and buffered before inference.
* Inference proceeds layer-by-layer.
* Hidden layers emit thresholded activations.
* The output layer emits population counts internally and performs argmax to select the class index.
* Output backpressure is fully respected by holding `data_out_valid` until `data_out_ready`.

## Verification Strategy

### Required Functional Verification

The baseline contest flow uses the provided [`verification/bnn_fcc_tb.sv`](verification/bnn_fcc_tb.sv), which validates:

* Full model configuration loading
* MNIST SFC correctness
* Randomized `config_valid` gaps
* Randomized `data_in_valid` gaps
* Randomized `data_out_ready` backpressure
* Performance statistics reported by the supplied testbench

### Additional Coverage-Oriented Verification

An extra testbench, [`verification/bnn_fcc_coverage_tb.sv`](verification/bnn_fcc_coverage_tb.sv), was added to target protocol and corner-case coverage beyond the default flow.

It intentionally stresses:

* Reordered configuration messages
* Threshold-before-weight and reverse-order configuration patterns
* Partial `TKEEP` on configuration payloads
* Partial `TKEEP` on image streams
* Reset during configuration
* Reset during image traffic
* Continuous, random, and bursty `TVALID` patterns
* Continuous, random, and bursty `TREADY` patterns
* Repeated versus varying classification sequences
* All 10 output classes in a self-checking randomized scenario

The coverage testbench uses the same contest-candidate datapath parallelism (`PARALLEL_NEURONS = '{8, 8, 1}`) and prints a covergroup summary at the end of a passing run so that additional evaluation is easy to inspect.

## Reproduction Commands

### Questa compile

```tcl
vlog -sv verification/axi4_stream_if.sv \
         verification/bnn_fcc_tb_pkg.sv \
         rtl/bnn_fcc.sv \
         verification/bnn_fcc_tb.sv \
         verification/bnn_fcc_coverage_tb.sv \
         openflex/rtl/bnn_fcc_timing.sv
```

### Contest verification run

Run the required verification flow from [`openflex/`](openflex/):

```bash
openflex bnn_fcc_verify.yml
```

### Timing and area run

```bash
openflex bnn_fcc_timing.yml -c bnn_fcc.csv
```

## Results

### Baseline `bnn_fcc_tb`

Paste the relevant success banner and reported latency/throughput statistics here.

### Coverage Testbench

Run:

```bash
openflex bnn_fcc_coverage.yml
```

The expected pass condition is the `SUCCESS: bnn_fcc_coverage_tb completed ...` banner, followed by the printed covergroup summary from the testbench. This testbench is intended to be the additional evaluation point for protocol/reset/ordering coverage beyond the required contest flow.

### Openflex Timing and Area

Final `bnn_fcc.csv` row:

```text
8,64,64,4,8,4,381.53376573826785,3232,1728000,2464,1728000,768,791040,1815,3456000,27,216000,282,864000,112,432000,0,216000,12.5,2688,0,1280,0,12288,...
```

Summary:

* `fMax = 381.53 MHz`
* `LUT = 3232`
* `FF = 1815`
* `BRAM = 12.5`
* `DSP = 0`

This submission favors a believable, BRAM-backed high-frequency operating point over aggressive output-layer spatial parallelism. The output layer is serialized (`PN2 = 1`) to reduce the routed critical path while keeping the hidden layers at `8` lanes each.

## Notes / Limitations

* This implementation assumes `PARALLEL_INPUTS` is a positive multiple of 8.
* Hidden-layer `PARALLEL_NEURONS` are expected to match `PARALLEL_INPUTS` so that inter-layer packing remains simple and timing-friendly.
* The provided openflex timing wrapper in [`openflex/rtl/bnn_fcc_timing.sv`](openflex/rtl/bnn_fcc_timing.sv) has been aligned with the DUT parameters.
