# Binary Neural Net (BNN) Fully Connected Classifier (FCC) Testbench (bnn_fcc_tb)

This folder contains a parameterized SystemVerilog testbench for verifying the fully connected binary neural network classifier. It supports both a fixed SFC topology (784-256-256-10) for MNIST digit recognition and user-defined custom topologies.

## Features
* **Dual Mode Operation**: Toggle between trained MNIST weights or randomized models for architectural exploration.
* **AXI4-Stream Integration**: Fully compliant handshaking with configurable bus widths and randomized back-pressure/validity.
* **Automated Reference Model**: Includes a SystemVerilog-based reference model to verify hardware outputs against expected Python-generated results.
* **Parameterized Parallelism**: Configurable neuron and input parallelism to match your specific DUT implementation.
* **Benchmarking**: Tracks latency and throughput.

---

## Getting Started

### Prerequisites
* **Simulator**: Siemens Questa/ModelSim (recommended) or any IEEE 1800-2012 compliant simulator.
* **Data Files**: Ensure the Python model data and test vectors are located in the directory specified by `BASE_DIR`.


### Running the Simulation

#### GUI Mode

1. Create a project in your simulator.
1. Add all files in the rtl/ and verification/ folder.
1. Edit the parameters in bnn_fcc_tb.sv to customize your simulation.
1. Compile all files.
1. Start a simulation using the bnn_fcc_tb testbench.

#### Script Mode

TO BE UPDATED

<!--1. Open your simulator and navigate to the `sim/` directory.
2. Compile the package, DUT, and testbench:
```tcl
vlog -sv ../rtl/bnn_fcc.sv
vlog -sv ../verification/bnn_fcc_tb_pkg.sv
vlog -sv ../verification/bnn_fcc_tb.sv
```
3. Initialize and run the simulation:
```tcl
vsim -gBASE_DIR="../python" -gNUM_TEST_IMAGES=100 -gDATA_IN_VALID_PROBABILITY=0.8 work.bnn_fcc_tb
run -all
```
-->
---

## Additional Coverage Testbench

This repository also includes [`bnn_fcc_coverage_tb.sv`](bnn_fcc_coverage_tb.sv), a separate coverage-oriented testbench intended to complement the provided top-level verification flow.

It uses a custom topology chosen to stress:
* Message reordering for configuration traffic
* Intermittent and bursty `TVALID` patterns
* Intermittent and bursty `TREADY` backpressure
* Partial `TKEEP` cases on both configuration and image streams
* Reset during configuration and reset during image traffic
* Repeated outputs versus varying outputs
* All 10 output classes within a single randomized-yet-self-checking scenario

Use `bnn_fcc_tb.sv` for the required correctness/performance flow and use `bnn_fcc_coverage_tb.sv` to demonstrate stronger verification quality in your report.

## Testbench Parameters

The testbench is highly configurable via SystemVerilog parameters. They are grouped into the following categories:

### Configuration
| Parameter | Description |
| :--- | :--- |
| `USE_CUSTOM_TOPOLOGY` | `0`: Use MNIST SFC (784->256->256->10). `1`: Use `CUSTOM_TOPOLOGY` array. |
| `CUSTOM_LAYERS` | The number of layers (input, hidden, and output) in the custom topolgoy. |
| `CUSTOM_TOPOLOGY` | Array specifying all layers. 0: number of inputs, 1 to CUSTOM_LAYERS-1: number of neurons in layer. |
| `NUM_TEST_IMAGES` | Total images to stream during simulation. |
| `VERIFY_MODEL` | Cross-check SV results against Python model (only applicable to USE_CUSTOM_TOPOLOGY=1'b0) |
| `BASE_DIR` |  Path to Python model data and test vectors (must be set relative to your simulator's working directory) |
| `TOGGLE_DATA_OUT_READY`| Randomly toggles data_out_ready to simulate back-pressure. Must be enabled to fully pass tests for contest. Disable to measure throughput and latency. |
| `CONFIG_VALID_PROBABILITY` |  Real value from 0.0 to 1.0 that specifies the probability of the configuration bus providing valid data while the DUT is ready. Used to simulate a slow upstream producer. Must be set to a value less than 1.0 to full pass testing, but should be set to 1 to measure performance. |
| `DATA_IN_VALID_PROBABILITY` | Real value from 0.0 to 1.0 that specifies the probability of the data_in bus providing valid pixels while the DUT is ready. Used to simulate a slow upstream producer. Must be set to a value less than 1.0 to fully pass testing, but should be set to 1 to measure performance. |
| `TIMEOUT` | Realtime value that specifies the maximum amount of time the testbench is allowed to run before being terminated. Adjust based on the expected performance of your design. |
| `CLK_PERIOD` | Realtime value specifying the clock period. Set based on Vivado fmax to get correct latency and throughput stats. |
| `DEBUG` | Set to print model details and an inference trace for each layer. |

### Bus Configuration
| Parameter | Default | Description |
| :--- | :--- | :--- |
| `CONFIG_BUS_WIDTH` | `64` | Bit-width for the AXI-Stream configuration bus. |
| `INPUT_BUS_WIDTH` | `64` | Bit-width for the AXI-Stream input pixel bus. |
| `OUTPUT_BUS_WIDTH` | `8` | Bit-width for the AXI-Stream inference output bus. |

These should not be changed without permission. If you are able to achieve
sufficient throughput where the INPUT_BUS_WIDTH becomes the bottleneck, you can
increase INPUT_BUS_WIDTH to achieve higher throughputs. In any case, these exact values
should be used for verification, even if modifying the values for performance measurements.

### App Configuration

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `INPUT_DATA_WIDTH` | `8` | **Fixed at 8**. Bit-width of individual pixels. |
| `OUTPUT_DATA_WIDTH` | `4` | **Fixed at 4**. Bit-width of inference output. |

These should not be changed for the contest. The code is untested for other widths.

### DUT Configuration

| Parameter | Description |
| :--- | :--- |
| `PARALLEL_INPUTS` | Number of inputs/weights processed in parallel in the first hidden layer. |
| `PARALLEL_NEURONS` | Number of neurons processed in parallel in each non-input layer. |

These parameters can be modifed, extended, and/or removed to support your design.

---

## Suggested Parameter Combinations

### Basic Testing
For basic testing and debugging, I'd recommend the following parameter settings: 
* `TOGGLE_DATA_OUT_READY = 0` (disable backpressure)
* `DATA_IN_VALID_PROBABILITY = 1.0` (disable gaps in input)
* `DEBUG = 1` (print model and inference trace)

### Performance Measurements
To measure latency and throughput, you should use avoid penalities from outside sources: 
* `TOGGLE_DATA_OUT_READY = 0`
* `DATA_IN_VALID_PROBABILITY = 1.0`

### Stress Testing (Contest Requirements)
To fully verify your design's robustness against back-pressure and inputs gaps, use these values:
* `USE_CUSTOM_TOPOLOGY = 0`
* `TOGGLE_DATA_OUT_READY = 1`
* `CONFIG_VALID_PROBABILITY = 0.8`
* `DATA_IN_VALID_PROBABILITY = 0.8`

---

