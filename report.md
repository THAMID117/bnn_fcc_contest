# BNN_FCC Contest Report

## Executive Summary

| Item | Result |
| :--- | :--- |
| Required `bnn_fcc_tb` verification | `TBD` |
| Additional coverage testbench | `TBD` |
| Openflex verification (`bnn_fcc_verify.yml`) | `TBD` |
| Fmax (MHz) | `TBD` |
| Throughput (outputs/sec) | `TBD` |
| Avg latency (cycles/image) | `TBD` |
| LUTs | `TBD` |
| FFs | `TBD` |
| BRAM | `TBD` |
| DSPs | `TBD` |

## Targeted Use Case

This design targets a high-frequency, verification-conscious operating point rather than maximum raw spatial parallelism. The architecture keeps the critical path short by:

* Processing one layer at a time
* Reusing a bounded set of neuron lanes within the active layer
* Storing weights in `PARALLEL_INPUTS`-wide packed words
* Keeping hidden-layer interconnect simple by matching hidden-layer `PARALLEL_NEURONS` to `PARALLEL_INPUTS`

For the contest configuration, the implementation uses:

* `PARALLEL_INPUTS = 8`
* `PARALLEL_NEURONS = '{8, 8, 10}`

This is an intentional tradeoff: it reduces configuration and inter-layer complexity, keeps the XNOR/popcount/accumulate datapath narrow, and should be favorable for out-of-context `fmax` in the provided openflex flow.

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

Paste the relevant success banner for `bnn_fcc_coverage_tb` here and summarize the protocol/reset scenarios exercised.

### Openflex Timing and Area

Paste the final row from `bnn_fcc.csv` here and summarize the tradeoff.

## Notes / Limitations

* This implementation assumes `PARALLEL_INPUTS` is a positive multiple of 8.
* Hidden-layer `PARALLEL_NEURONS` are expected to match `PARALLEL_INPUTS` so that inter-layer packing remains simple and timing-friendly.
* The provided openflex timing wrapper in [`openflex/rtl/bnn_fcc_timing.sv`](openflex/rtl/bnn_fcc_timing.sv) has been aligned with the DUT parameters.
