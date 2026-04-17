# Openflex 

We are using the openflex tool to collect timing and area results, in addition to performing the final verification tests for the contest.

## Installation and Initialization Instructions

[To install openflex follow the instructions here](https://github.com/wespiard/openflex). However, I'd recommend the following changes to install it into ~/envs/openflex:

```bash
python -m venv ~/envs/openflex
source ~/envs/openflex/bin/activate
pip install -U pip        
pip install openflex     
```

When logging back into your account after installing, you can reactivate the openflex environment with:

```bash
source ~/envs/openflex/bin/activate
```

To deactivate at any time:

```bash
deactivate
```

## Collecting Timing and Area Results

Openflex uses a YAML file to specify the details of the project. This repository already includes a working [bnn_fcc_timing.yml](bnn_fcc_timing.yml) with the required source files for this submission candidate.

For out-of-context timing analysis, it is usually a good idea to ensure that the I/O is registered. I provide this for you in [rtl/bnn_fcc_timing.sv](rtl/bnn_fcc_timing.sv), which will be the top-level module for synthesis when collecting results.

IMPORTANT: keep the implementation-specific default parameter values in [rtl/bnn_fcc_timing.sv](rtl/bnn_fcc_timing.sv) aligned with the canonical submission candidate. For this repository, that means `PARALLEL_INPUTS = 8` and `PARALLEL_NEURONS = '{8, 8, 1}`.

Run openflex to collecting timing results with the following:

```bash
openflex bnn_fcc_timing.yml -c bnn_fcc.csv
```

This command will create a Vivado project, execute Vivado to synthesize, place, and route your design, and will then report maximum clock frequency and area numbers in bnn_fcc.csv.
You can see an example in [example.csv](example.csv).

If you get errors when running openflex here, make sure that Vivado is in your PATH, that the YAML file contains all required source files, and that openflex is activated.

If a timing run completes Vivado but then crashes with `ValueError: invalid literal for int() with base 10: '12.5'`, the installed `openflex` parser is choking on fractional utilization values reported by Vivado. From the activated environment, run:

```bash
python patch_openflex_parser.py
```

from this `openflex/` directory, then rerun the timing command.

## Verification

For verifying your final design, this repository already includes the required source list in [bnn_fcc_verify.yml](bnn_fcc_verify.yml). You do not need `bnn_fcc_timing.sv` here.

You could potentially verify your design like this:

```bash
openflex bnn_fcc_verify.yml
```

But, this requires you to manually scan the output and verify correctness. I've automated that with the simple bash script [verify.sh](verify.sh). To run it, simply do:

```bash
./verify.sh
```

If it doesn't run, first try:

```bash
chmod +x verify.sh
```

If your simulation is successful, it will report:

```bash
Verification PASSED
```

If your simulation fails, it will report:

```bash
Verification FAILED (see run.log)
```

where run.log contains the output from the simulation.

## Optional Coverage-Oriented Run

If you want to run the additional coverage-focused testbench, use:

```bash
openflex bnn_fcc_coverage.yml
```

This runs [`verification/bnn_fcc_coverage_tb.sv`](../verification/bnn_fcc_coverage_tb.sv), which is intended for reportable verification depth rather than the required contest pass/fail flow.






