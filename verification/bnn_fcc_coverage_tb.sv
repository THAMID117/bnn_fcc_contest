`timescale 1ns / 100ps

// Contest submission owner:
// Khan Thamid Hasan
// UFID: 17308681
// Email: khanthamidhasan@ufl.edu

module bnn_fcc_coverage_tb #(
    parameter realtime CLK_PERIOD = 10ns,
    parameter realtime TIMEOUT    = 10ms,
    parameter int      INPUT_DATA_WIDTH  = 8,
    parameter int      INPUT_BUS_WIDTH   = 64,
    parameter int      CONFIG_BUS_WIDTH  = 64,
    parameter int      OUTPUT_DATA_WIDTH = 4,
    parameter int      OUTPUT_BUS_WIDTH  = 8
);
    import bnn_fcc_tb_pkg::*;

    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{13, 9, 11, 10};
    localparam int NON_INPUT_LAYERS = TOTAL_LAYERS - 1;
    localparam int NUM_CLASSES = TOPOLOGY[TOTAL_LAYERS-1];
    localparam int PARALLEL_INPUTS = 8;
    localparam int PARALLEL_NEURONS[NON_INPUT_LAYERS] = '{8, 8, 1};
    localparam int INPUTS_PER_BEAT = INPUT_BUS_WIDTH / INPUT_DATA_WIDTH;
    localparam int BYTES_PER_PIXEL = INPUT_DATA_WIDTH / 8;
    localparam int NUM_CONFIG_MSGS = (2 * NON_INPUT_LAYERS) - 1;
    localparam realtime HALF_CLK_PERIOD = CLK_PERIOD / 2.0;

    typedef bit [INPUT_DATA_WIDTH-1:0] pixel_t;
    typedef pixel_t image_t[];
    typedef bit [CONFIG_BUS_WIDTH-1:0] cfg_word_t;
    typedef bit [CONFIG_BUS_WIDTH/8-1:0] cfg_keep_t;
    typedef cfg_word_t cfg_stream_t[];
    typedef cfg_keep_t cfg_keep_stream_t[];

    typedef enum int {
        VALID_ALWAYS = 0,
        VALID_RANDOM = 1,
        VALID_BURSTY = 2
    } valid_mode_t;

    typedef enum int {
        READY_ALWAYS = 0,
        READY_RANDOM = 1,
        READY_BURSTY = 2
    } ready_mode_t;

    typedef enum int {
        RESET_AT_START      = 0,
        RESET_DURING_CONFIG = 1,
        RESET_DURING_IMAGE  = 2,
        RESET_BETWEEN_RUNS  = 3
    } reset_phase_t;

    logic clk = 1'b0;
    logic rst;

    axi4_stream_if #(
        .DATA_WIDTH(CONFIG_BUS_WIDTH)
    ) config_in (
        .aclk   (clk),
        .aresetn(!rst)
    );

    axi4_stream_if #(
        .DATA_WIDTH(INPUT_BUS_WIDTH)
    ) data_in (
        .aclk   (clk),
        .aresetn(!rst)
    );

    axi4_stream_if #(
        .DATA_WIDTH(OUTPUT_BUS_WIDTH)
    ) data_out (
        .aclk   (clk),
        .aresetn(!rst)
    );

    bnn_fcc #(
        .INPUT_DATA_WIDTH (INPUT_DATA_WIDTH),
        .INPUT_BUS_WIDTH  (INPUT_BUS_WIDTH),
        .CONFIG_BUS_WIDTH (CONFIG_BUS_WIDTH),
        .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH),
        .OUTPUT_BUS_WIDTH (OUTPUT_BUS_WIDTH),
        .TOTAL_LAYERS     (TOTAL_LAYERS),
        .TOPOLOGY         (TOPOLOGY),
        .PARALLEL_INPUTS  (PARALLEL_INPUTS),
        .PARALLEL_NEURONS (PARALLEL_NEURONS)
    ) dut (
        .clk(clk),
        .rst(rst),

        .config_valid(config_in.tvalid),
        .config_ready(config_in.tready),
        .config_data (config_in.tdata),
        .config_keep (config_in.tkeep),
        .config_last (config_in.tlast),

        .data_in_valid(data_in.tvalid),
        .data_in_ready(data_in.tready),
        .data_in_data (data_in.tdata),
        .data_in_keep (data_in.tkeep),
        .data_in_last (data_in.tlast),

        .data_out_valid(data_out.tvalid),
        .data_out_ready(data_out.tready),
        .data_out_data (data_out.tdata),
        .data_out_keep (data_out.tkeep),
        .data_out_last (data_out.tlast)
    );

    BNN_FCC_Model #(CONFIG_BUS_WIDTH) model;
    BNN_FCC_Stimulus #(INPUT_DATA_WIDTH) stim;

    cfg_stream_t      msg_streams[NUM_CONFIG_MSGS];
    cfg_keep_stream_t msg_keeps[NUM_CONFIG_MSGS];
    int               msg_type[NUM_CONFIG_MSGS];
    int               msg_layer[NUM_CONFIG_MSGS];

    image_t class_examples[NUM_CLASSES];
    bit     class_found[NUM_CLASSES];
    logic [OUTPUT_DATA_WIDTH-1:0] expected_outputs[$];

    ready_mode_t ready_mode;
    int          passed;
    int          failed;
    int          outputs_seen;
    int          prev_output_class;

    covergroup cg_config_msg with function sample(int order_id, int kind, int layer_id);
        coverpoint order_id {
            bins thresholds_first = {0};
            bins reverse_order    = {1};
            bins weights_first    = {2};
        }
        coverpoint kind {
            bins weights    = {0};
            bins thresholds = {1};
        }
        coverpoint layer_id {
            bins layers[] = {[0:NON_INPUT_LAYERS-1]};
        }
        cross order_id, kind, layer_id;
    endgroup

    covergroup cg_keep with function sample(bit is_config, bit is_last, int keep_ones);
        coverpoint is_config;
        coverpoint is_last;
        coverpoint keep_ones {
            bins tiny    = {[1:2]};
            bins partial = {[3:7]};
            bins full    = {8};
        }
        cross is_config, is_last, keep_ones;
    endgroup

    covergroup cg_valid_mode with function sample(int mode_id);
        coverpoint mode_id {
            bins always_on = {VALID_ALWAYS};
            bins random_on = {VALID_RANDOM};
            bins bursty_on = {VALID_BURSTY};
        }
    endgroup

    covergroup cg_ready_mode with function sample(int mode_id);
        coverpoint mode_id {
            bins always_ready = {READY_ALWAYS};
            bins random_ready = {READY_RANDOM};
            bins bursty_ready = {READY_BURSTY};
        }
    endgroup

    covergroup cg_reset_phase with function sample(int phase_id);
        coverpoint phase_id {
            bins at_start      = {RESET_AT_START};
            bins during_config = {RESET_DURING_CONFIG};
            bins during_image  = {RESET_DURING_IMAGE};
            bins between_runs  = {RESET_BETWEEN_RUNS};
        }
    endgroup

    covergroup cg_output_class with function sample(int class_id);
        coverpoint class_id {
            bins classes[] = {[0:NUM_CLASSES-1]};
        }
    endgroup

    covergroup cg_output_transition with function sample(bit same_class);
        coverpoint same_class {
            bins repeated = {1'b1};
            bins varying  = {1'b0};
        }
    endgroup

    covergroup cg_threshold_class with function sample(int layer_id, int class_id);
        coverpoint layer_id {
            bins hidden0 = {0};
            bins hidden1 = {1};
        }
        coverpoint class_id {
            bins low  = {0};
            bins mid  = {1};
            bins high = {2};
        }
        cross layer_id, class_id;
    endgroup

    covergroup cg_weight_density with function sample(int layer_id, int class_id);
        coverpoint layer_id {
            bins layer0 = {0};
            bins layer1 = {1};
            bins layer2 = {2};
        }
        coverpoint class_id {
            bins sparse = {0};
            bins mixed  = {1};
            bins dense  = {2};
        }
        cross layer_id, class_id;
    endgroup

    cg_config_msg       config_msg_cov = new();
    cg_keep             keep_cov       = new();
    cg_valid_mode       valid_mode_cov = new();
    cg_ready_mode       ready_mode_cov = new();
    cg_reset_phase      reset_cov      = new();
    cg_output_class     output_cov     = new();
    cg_output_transition output_seq_cov = new();
    cg_threshold_class  threshold_cov  = new();
    cg_weight_density   weight_cov     = new();

    function automatic int chance_percent(input int percent);
        chance_percent = ($urandom_range(0, 99) < percent);
    endfunction

    function automatic int popcount_keep(input bit [CONFIG_BUS_WIDTH/8-1:0] keep);
        int count;
        count = 0;
        for (int i = 0; i < CONFIG_BUS_WIDTH/8; i++) count += keep[i];
        return count;
    endfunction

    function automatic int threshold_class_id(input int threshold, input int fan_in);
        if (threshold <= (fan_in / 3)) return 0;
        if (threshold >= ((2 * fan_in) / 3)) return 2;
        return 1;
    endfunction

    function automatic int weight_density_id(input int ones_count, input int total_bits);
        if ((3 * ones_count) <= total_bits) return 0;
        if ((3 * ones_count) >= (2 * total_bits)) return 2;
        return 1;
    endfunction

    function automatic bit want_valid(input valid_mode_t mode, input int cycle_idx);
        case (mode)
            VALID_ALWAYS: return 1'b1;
            VALID_RANDOM: return chance_percent(65);
            VALID_BURSTY: return ((cycle_idx % 5) < 3);
            default:      return 1'b1;
        endcase
    endfunction

    task automatic clear_drivers();
        config_in.tvalid <= 1'b0;
        config_in.tdata  <= '0;
        config_in.tkeep  <= '0;
        config_in.tlast  <= 1'b0;
        config_in.tstrb  <= '0;
        config_in.tuser  <= '0;
        config_in.tid    <= '0;
        config_in.tdest  <= '0;

        data_in.tvalid   <= 1'b0;
        data_in.tdata    <= '0;
        data_in.tkeep    <= '0;
        data_in.tlast    <= 1'b0;
        data_in.tstrb    <= '0;
        data_in.tuser    <= '0;
        data_in.tid      <= '0;
        data_in.tdest    <= '0;
    endtask

    task automatic apply_reset(input reset_phase_t phase, input int cycles = 4);
        reset_cov.sample(phase);
        clear_drivers();
        expected_outputs.delete();
        rst <= 1'b1;
        repeat (cycles) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    task automatic build_message_cache();
        int msg_idx;
        msg_idx = 0;

        for (int layer = 0; layer < NON_INPUT_LAYERS; layer++) begin
            model.get_layer_config(layer, 1'b0, msg_streams[msg_idx], msg_keeps[msg_idx]);
            msg_type[msg_idx]  = 0;
            msg_layer[msg_idx] = layer;
            msg_idx++;

            if (layer < NON_INPUT_LAYERS - 1) begin
                model.get_layer_config(layer, 1'b1, msg_streams[msg_idx], msg_keeps[msg_idx]);
                msg_type[msg_idx]  = 1;
                msg_layer[msg_idx] = layer;
                msg_idx++;
            end
        end
    endtask

    task automatic sample_model_diversity();
        for (int layer = 0; layer < NON_INPUT_LAYERS; layer++) begin
            int fan_in;
            fan_in = TOPOLOGY[layer];

            for (int neuron = 0; neuron < TOPOLOGY[layer+1]; neuron++) begin
                int ones_count;
                ones_count = 0;
                for (int i = 0; i < fan_in; i++) begin
                    ones_count += model.weight[layer][neuron][i];
                end
                weight_cov.sample(layer, weight_density_id(ones_count, fan_in));

                if (layer < NON_INPUT_LAYERS - 1) begin
                    threshold_cov.sample(layer, threshold_class_id(model.threshold[layer][neuron], fan_in));
                end
            end
        end
    endtask

    task automatic build_coverable_model();
        int attempts;
        int discovered;
        image_t candidate;

        for (attempts = 0; attempts < 128; attempts++) begin
            model = new();
            model.create_random(TOPOLOGY);

            for (int c = 0; c < NUM_CLASSES; c++) begin
                class_found[c] = 1'b0;
                class_examples[c] = new[TOPOLOGY[0]];
            end

            discovered = 0;
            for (int sample = 0; sample < 4000 && discovered < NUM_CLASSES; sample++) begin
                int pred;
                stim.get_random_vector(candidate);
                pred = model.compute_reference(candidate);

                if (!class_found[pred]) begin
                    class_found[pred] = 1'b1;
                    class_examples[pred] = new[candidate.size()];
                    foreach (candidate[i]) class_examples[pred][i] = candidate[i];
                    discovered++;
                end
            end

            if (discovered == NUM_CLASSES) begin
                build_message_cache();
                sample_model_diversity();
                return;
            end
        end

        $fatal(1, "Coverage TB failed to find a random model that exercises all %0d output classes.", NUM_CLASSES);
    endtask

    task automatic send_config_message(
        input int order_id,
        input int msg_idx,
        input valid_mode_t mode
    );
        int gap_cycle;

        config_msg_cov.sample(order_id, msg_type[msg_idx], msg_layer[msg_idx]);
        valid_mode_cov.sample(mode);

        for (int word = 0; word < msg_streams[msg_idx].size(); word++) begin
            gap_cycle = 0;
            while (!want_valid(mode, gap_cycle)) begin
                config_in.tvalid <= 1'b0;
                @(posedge clk);
                gap_cycle++;
            end

            keep_cov.sample(1'b1, word == msg_streams[msg_idx].size() - 1, popcount_keep(msg_keeps[msg_idx][word]));
            config_in.tdata  <= msg_streams[msg_idx][word];
            config_in.tkeep  <= msg_keeps[msg_idx][word];
            config_in.tstrb  <= msg_keeps[msg_idx][word];
            config_in.tlast  <= (word == msg_streams[msg_idx].size() - 1);
            config_in.tvalid <= 1'b1;
            do @(posedge clk); while (!config_in.tready);
        end

        config_in.tvalid <= 1'b0;
        config_in.tlast  <= 1'b0;
        config_in.tkeep  <= '0;
        config_in.tstrb  <= '0;
        config_in.tdata  <= '0;
        @(posedge clk);
    endtask

    task automatic configure_with_order(
        input int order_id,
        input int order[NUM_CONFIG_MSGS],
        input valid_mode_t mode
    );
        for (int i = 0; i < NUM_CONFIG_MSGS; i++) begin
            send_config_message(order_id, order[i], mode);
        end

        wait (data_in.tready);
        repeat (2) @(posedge clk);
    endtask

    task automatic send_image(
        input image_t img,
        input valid_mode_t mode
    );
        int expected_pred;
        int gap_cycle;

        expected_pred = model.compute_reference(img);
        valid_mode_cov.sample(mode);

        for (int base = 0; base < img.size(); base += INPUTS_PER_BEAT) begin
            bit [INPUT_BUS_WIDTH-1:0] beat_data;
            bit [INPUT_BUS_WIDTH/8-1:0] beat_keep;

            beat_data = '0;
            beat_keep = '0;

            for (int k = 0; k < INPUTS_PER_BEAT; k++) begin
                if (base + k < img.size()) begin
                    beat_data[k*INPUT_DATA_WIDTH+:INPUT_DATA_WIDTH] = img[base+k];
                    beat_keep[k*BYTES_PER_PIXEL+:BYTES_PER_PIXEL]   = '1;
                end
            end

            gap_cycle = 0;
            while (!want_valid(mode, gap_cycle)) begin
                data_in.tvalid <= 1'b0;
                @(posedge clk);
                gap_cycle++;
            end

            keep_cov.sample(1'b0, base + INPUTS_PER_BEAT >= img.size(), popcount_keep(beat_keep));
            data_in.tdata  <= beat_data;
            data_in.tkeep  <= beat_keep;
            data_in.tstrb  <= beat_keep;
            data_in.tlast  <= (base + INPUTS_PER_BEAT >= img.size());
            data_in.tvalid <= 1'b1;
            do @(posedge clk); while (!data_in.tready);
        end

        data_in.tvalid <= 1'b0;
        data_in.tlast  <= 1'b0;
        data_in.tkeep  <= '0;
        data_in.tstrb  <= '0;
        data_in.tdata  <= '0;
        expected_outputs.push_back(expected_pred[OUTPUT_DATA_WIDTH-1:0]);
        @(posedge clk);
    endtask

    task automatic send_partial_image_then_reset(input image_t img);
        bit [INPUT_BUS_WIDTH-1:0] beat_data;
        bit [INPUT_BUS_WIDTH/8-1:0] beat_keep;

        beat_data = '0;
        beat_keep = '0;
        for (int k = 0; k < INPUTS_PER_BEAT; k++) begin
            if (k < img.size()) begin
                beat_data[k*INPUT_DATA_WIDTH+:INPUT_DATA_WIDTH] = img[k];
                beat_keep[k*BYTES_PER_PIXEL+:BYTES_PER_PIXEL]   = '1;
            end
        end

        data_in.tdata  <= beat_data;
        data_in.tkeep  <= beat_keep;
        data_in.tstrb  <= beat_keep;
        data_in.tlast  <= (img.size() <= INPUTS_PER_BEAT);
        data_in.tvalid <= 1'b1;
        do @(posedge clk); while (!data_in.tready);
        data_in.tvalid <= 1'b0;
        data_in.tlast  <= 1'b0;
        data_in.tkeep  <= '0;
        data_in.tstrb  <= '0;
        data_in.tdata  <= '0;

        apply_reset(RESET_DURING_IMAGE);
    endtask

    task automatic wait_for_outputs(input int count);
        wait (outputs_seen >= count);
        repeat (3) @(posedge clk);
    endtask

    task automatic print_coverage_summary();
        real avg_cov;

        avg_cov =
            (config_msg_cov.get_inst_coverage() +
             keep_cov.get_inst_coverage() +
             valid_mode_cov.get_inst_coverage() +
             ready_mode_cov.get_inst_coverage() +
             reset_cov.get_inst_coverage() +
             output_cov.get_inst_coverage() +
             output_seq_cov.get_inst_coverage() +
             threshold_cov.get_inst_coverage() +
             weight_cov.get_inst_coverage()) / 9.0;

        $display("\nCoverage summary:");
        $display("  config_msg_cov      : %0.1f%%", config_msg_cov.get_inst_coverage());
        $display("  keep_cov            : %0.1f%%", keep_cov.get_inst_coverage());
        $display("  valid_mode_cov      : %0.1f%%", valid_mode_cov.get_inst_coverage());
        $display("  ready_mode_cov      : %0.1f%%", ready_mode_cov.get_inst_coverage());
        $display("  reset_cov           : %0.1f%%", reset_cov.get_inst_coverage());
        $display("  output_cov          : %0.1f%%", output_cov.get_inst_coverage());
        $display("  output_seq_cov      : %0.1f%%", output_seq_cov.get_inst_coverage());
        $display("  threshold_cov       : %0.1f%%", threshold_cov.get_inst_coverage());
        $display("  weight_cov          : %0.1f%%", weight_cov.get_inst_coverage());
        $display("  average covergroup  : %0.1f%%", avg_cov);
    endtask

    initial begin : generate_clock
        forever #HALF_CLK_PERIOD clk <= ~clk;
    end

    initial begin : ready_driver
        int burst_len;

        ready_mode = READY_ALWAYS;
        data_out.tready <= 1'b1;
        burst_len = 0;

        forever begin
            @(posedge clk);
            if (rst) begin
                data_out.tready <= 1'b1;
                burst_len = 0;
            end else begin
                case (ready_mode)
                    READY_ALWAYS: data_out.tready <= 1'b1;
                    READY_RANDOM: data_out.tready <= $urandom_range(0, 1);
                    READY_BURSTY: begin
                        if (burst_len == 0) begin
                            burst_len = $urandom_range(1, 4);
                            data_out.tready <= ~data_out.tready;
                        end else begin
                            burst_len = burst_len - 1;
                        end
                    end
                    default: data_out.tready <= 1'b1;
                endcase
            end
        end
    end

    initial begin : output_monitor
        prev_output_class = -1;
        forever begin
            @(posedge clk);
            if (rst) begin
                prev_output_class = -1;
            end else if (data_out.tvalid && data_out.tready) begin
                int actual_class;
                logic [OUTPUT_DATA_WIDTH-1:0] expected_class;

                assert (expected_outputs.size() > 0)
                else $fatal(1, "Coverage TB saw an output without a queued expectation.");

                actual_class   = data_out.tdata[OUTPUT_DATA_WIDTH-1:0];
                expected_class = expected_outputs.pop_front();

                if (actual_class !== expected_class) begin
                    $error("Coverage TB mismatch: actual=%0d expected=%0d", actual_class, expected_class);
                    failed++;
                end else begin
                    passed++;
                end

                output_cov.sample(actual_class);
                if (prev_output_class != -1) output_seq_cov.sample(actual_class == prev_output_class);
                prev_output_class = actual_class;
                outputs_seen++;
            end
        end
    end

    initial begin : main
        int thresholds_first[NUM_CONFIG_MSGS];
        int reverse_order[NUM_CONFIG_MSGS];
        int weights_first[NUM_CONFIG_MSGS];
        int outputs_target;

        $timeformat(-9, 0, " ns", 0);
        model = new();
        stim  = new(TOPOLOGY[0]);
        passed = 0;
        failed = 0;
        outputs_seen = 0;

        thresholds_first = '{1, 0, 3, 2, 4};
        reverse_order    = '{4, 3, 2, 1, 0};
        weights_first    = '{0, 2, 4, 1, 3};

        clear_drivers();
        rst <= 1'b1;
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        build_coverable_model();

        apply_reset(RESET_AT_START);

        ready_mode = READY_RANDOM;
        ready_mode_cov.sample(READY_RANDOM);
        configure_with_order(0, thresholds_first, VALID_RANDOM);
        for (int c = 0; c < NUM_CLASSES; c++) begin
            send_image(class_examples[c], (c % 2) ? VALID_RANDOM : VALID_BURSTY);
        end
        send_image(class_examples[0], VALID_ALWAYS);
        send_image(class_examples[0], VALID_RANDOM);
        outputs_target = NUM_CLASSES + 2;
        wait_for_outputs(outputs_target);

        apply_reset(RESET_BETWEEN_RUNS);

        ready_mode = READY_BURSTY;
        ready_mode_cov.sample(READY_BURSTY);
        send_config_message(1, reverse_order[0], VALID_BURSTY);
        send_config_message(1, reverse_order[1], VALID_ALWAYS);
        apply_reset(RESET_DURING_CONFIG);
        configure_with_order(1, reverse_order, VALID_BURSTY);
        send_image(class_examples[3], VALID_RANDOM);
        send_image(class_examples[7], VALID_BURSTY);
        outputs_target += 2;
        wait_for_outputs(outputs_target);

        apply_reset(RESET_BETWEEN_RUNS);

        ready_mode = READY_ALWAYS;
        ready_mode_cov.sample(READY_ALWAYS);
        configure_with_order(2, weights_first, VALID_ALWAYS);
        send_partial_image_then_reset(class_examples[5]);
        configure_with_order(2, weights_first, VALID_RANDOM);
        send_image(class_examples[5], VALID_RANDOM);
        send_image(class_examples[2], VALID_BURSTY);
        outputs_target += 2;
        wait_for_outputs(outputs_target);

        repeat (5) @(posedge clk);
        print_coverage_summary();

        if (failed == 0) begin
            $display("[%0t] SUCCESS: bnn_fcc_coverage_tb completed with %0d passing checks.", $realtime, passed);
        end else begin
            $fatal(1, "[%0t] FAILURE: bnn_fcc_coverage_tb saw %0d mismatches.", $realtime, failed);
        end

        disable generate_clock;
        disable timeout_block;
    end

    initial begin : timeout_block
        #TIMEOUT;
        $fatal(1, "Coverage TB timed out after %0t.", TIMEOUT);
    end

endmodule
