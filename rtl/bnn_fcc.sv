module bnn_fcc #(
    parameter int INPUT_DATA_WIDTH  = 8,
    parameter int INPUT_BUS_WIDTH   = 64,
    parameter int CONFIG_BUS_WIDTH  = 64,
    parameter int OUTPUT_DATA_WIDTH = 4,
    parameter int OUTPUT_BUS_WIDTH  = 8,

    parameter int TOTAL_LAYERS = 4,
    parameter int TOPOLOGY[TOTAL_LAYERS] = '{0: 784, 1: 256, 2: 256, 3: 10, default: 0},

    parameter int PARALLEL_INPUTS = 8,
    parameter int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{8, 8, 1}
) (
    input logic clk,
    input logic rst,

    input  logic                          config_valid,
    output logic                          config_ready,
    input  logic [  CONFIG_BUS_WIDTH-1:0] config_data,
    input  logic [CONFIG_BUS_WIDTH/8-1:0] config_keep,
    input  logic                          config_last,

    input  logic                         data_in_valid,
    output logic                         data_in_ready,
    input  logic [  INPUT_BUS_WIDTH-1:0] data_in_data,
    input  logic [INPUT_BUS_WIDTH/8-1:0] data_in_keep,
    input  logic                         data_in_last,

    output logic                          data_out_valid,
    input  logic                          data_out_ready,
    output logic [  OUTPUT_BUS_WIDTH-1:0] data_out_data,
    output logic [OUTPUT_BUS_WIDTH/8-1:0] data_out_keep,
    output logic                          data_out_last
);

    function automatic int ceil_div(input int value, input int divisor);
        ceil_div = (value + divisor - 1) / divisor;
    endfunction

    function automatic int max2(input int a, input int b);
        max2 = (a > b) ? a : b;
    endfunction

    function automatic int max3(input int a, input int b, input int c);
        max3 = max2(max2(a, b), c);
    endfunction

    // Keep the 8-bit XNOR/popcount tree shallow; this is the fixed contest datapath width.
    function automatic logic [3:0] popcount8(input logic [PARALLEL_INPUTS-1:0] value);
        logic [1:0] pair0;
        logic [1:0] pair1;
        logic [1:0] pair2;
        logic [1:0] pair3;
        logic [2:0] half0;
        logic [2:0] half1;

        pair0 = {1'b0, value[0]} + {1'b0, value[1]};
        pair1 = {1'b0, value[2]} + {1'b0, value[3]};
        pair2 = {1'b0, value[4]} + {1'b0, value[5]};
        pair3 = {1'b0, value[6]} + {1'b0, value[7]};

        half0 = {1'b0, pair0} + {1'b0, pair1};
        half1 = {1'b0, pair2} + {1'b0, pair3};
        popcount8 = {1'b0, half0} + {1'b0, half1};
    endfunction

    localparam int NON_INPUT_LAYERS = TOTAL_LAYERS - 1;
    localparam int CONFIG_BYTES_PER_BEAT = CONFIG_BUS_WIDTH / 8;
    localparam int INPUT_BYTES_PER_BEAT  = INPUT_BUS_WIDTH / 8;
    localparam int OUTPUT_VALID_BYTES    = (OUTPUT_DATA_WIDTH + 7) / 8;

    localparam int L0_INPUTS  = TOPOLOGY[0];
    localparam int L1_INPUTS  = TOPOLOGY[1];
    localparam int L2_INPUTS  = TOPOLOGY[2];
    localparam int L3_OUTPUTS = TOPOLOGY[3];

    localparam int PN0 = PARALLEL_NEURONS[0];
    localparam int PN1 = PARALLEL_NEURONS[1];
    localparam int PN2 = PARALLEL_NEURONS[2];

    localparam int L0_WORDS = ceil_div(L0_INPUTS, PARALLEL_INPUTS);
    localparam int L1_WORDS = ceil_div(L1_INPUTS, PARALLEL_INPUTS);
    localparam int L2_WORDS = ceil_div(L2_INPUTS, PARALLEL_INPUTS);

    localparam int L0_GROUPS = ceil_div(L1_INPUTS, PN0);
    localparam int L1_GROUPS = ceil_div(L2_INPUTS, PN1);
    localparam int L2_GROUPS = ceil_div(L3_OUTPUTS, PN2);

    localparam int L0_SLOT_DEPTH = L0_GROUPS * L0_WORDS;
    localparam int L1_SLOT_DEPTH = L1_GROUPS * L1_WORDS;
    localparam int L2_SLOT_DEPTH = L2_GROUPS * L2_WORDS;

    localparam int MAX_INPUTS = max3(L0_INPUTS, L1_INPUTS, L2_INPUTS);
    localparam int MAX_WORDS  = max3(L0_WORDS, L1_WORDS, L2_WORDS);
    localparam int MAX_GROUPS = max3(L0_GROUPS, L1_GROUPS, L2_GROUPS);
    localparam int MAX_PN     = max3(PN0, PN1, PN2);

    localparam int MAX_NEURONS        = max3(L1_INPUTS, L2_INPUTS, L3_OUTPUTS);
    localparam int ACC_WIDTH          = (MAX_INPUTS > 0) ? $clog2(MAX_INPUTS + 1) : 1;
    localparam int PIXEL_COUNT_WIDTH  = (L0_INPUTS > 0) ? $clog2(L0_INPUTS + 1) : 1;
    localparam int NEURON_COUNT_WIDTH = (MAX_NEURONS > 0) ? $clog2(MAX_NEURONS + 1) : 1;
    localparam int WORD_COUNT_WIDTH   = (MAX_WORDS > 1) ? $clog2(MAX_WORDS) : 1;
    localparam int GROUP_COUNT_WIDTH  = (MAX_GROUPS > 1) ? $clog2(MAX_GROUPS) : 1;
    localparam int L0_ADDR_WIDTH      = (L0_SLOT_DEPTH > 1) ? $clog2(L0_SLOT_DEPTH) : 1;
    localparam int L1_ADDR_WIDTH      = (L1_SLOT_DEPTH > 1) ? $clog2(L1_SLOT_DEPTH) : 1;
    localparam int L2_ADDR_WIDTH      = (L2_SLOT_DEPTH > 1) ? $clog2(L2_SLOT_DEPTH) : 1;
    localparam int BYTE_IDX_WIDTH    = (CONFIG_BYTES_PER_BEAT > 1) ? $clog2(CONFIG_BYTES_PER_BEAT) : 1;
    localparam int IN_BYTE_IDX_WIDTH = (INPUT_BYTES_PER_BEAT > 1) ? $clog2(INPUT_BYTES_PER_BEAT) : 1;
    localparam int MSG_BYTES_WIDTH   = (max3(L0_WORDS, L1_WORDS, L2_WORDS) * 8 > 1) ? $clog2(max3(L0_WORDS, L1_WORDS, L2_WORDS) * 8 + 1) : 1;

    localparam logic [OUTPUT_BUS_WIDTH/8-1:0] OUTPUT_KEEP_VALUE =
        ({(OUTPUT_BUS_WIDTH/8){1'b1}} >> ((OUTPUT_BUS_WIDTH/8) - OUTPUT_VALID_BYTES));

    typedef enum logic [2:0] {
        STATE_CONFIG,
        STATE_WAIT_IMAGE,
        STATE_COMPUTE_READ,
        STATE_COMPUTE_ACCUM,
        STATE_COMPUTE_WRITE,
        STATE_OUTPUT
    } state_t;

    state_t state;

    logic [PN0-1:0]                      l0_weight_wr_en;
    logic [PN1-1:0]                      l1_weight_wr_en;
    logic [PN2-1:0]                      l2_weight_wr_en;
    logic [PN0-1:0]                      l0_weight_rd_en;
    logic [PN1-1:0]                      l1_weight_rd_en;
    logic [PN2-1:0]                      l2_weight_rd_en;
    logic [PN0-1:0][L0_ADDR_WIDTH-1:0]   l0_weight_wr_addr;
    logic [PN1-1:0][L1_ADDR_WIDTH-1:0]   l1_weight_wr_addr;
    logic [PN2-1:0][L2_ADDR_WIDTH-1:0]   l2_weight_wr_addr;
    logic [PN0-1:0][L0_ADDR_WIDTH-1:0]   l0_weight_rd_addr;
    logic [PN1-1:0][L1_ADDR_WIDTH-1:0]   l1_weight_rd_addr;
    logic [PN2-1:0][L2_ADDR_WIDTH-1:0]   l2_weight_rd_addr;
    logic [PN0-1:0][PARALLEL_INPUTS-1:0] l0_weight_wr_data;
    logic [PN1-1:0][PARALLEL_INPUTS-1:0] l1_weight_wr_data;
    logic [PN2-1:0][PARALLEL_INPUTS-1:0] l2_weight_wr_data;

    logic [ACC_WIDTH-1:0] threshold_mem_l0[0:L1_INPUTS-1];
    logic [ACC_WIDTH-1:0] threshold_mem_l1[0:L2_INPUTS-1];

    logic [PARALLEL_INPUTS-1:0] input_buf_l0[0:L0_WORDS-1];
    logic [PARALLEL_INPUTS-1:0] input_buf_l1[0:L1_WORDS-1];
    logic [PARALLEL_INPUTS-1:0] input_buf_l2[0:L2_WORDS-1];

    logic [PN0-1:0][PARALLEL_INPUTS-1:0] weight_rd_data_l0;
    logic [PN1-1:0][PARALLEL_INPUTS-1:0] weight_rd_data_l1;
    logic [PN2-1:0][PARALLEL_INPUTS-1:0] weight_rd_data_l2;

    logic [ACC_WIDTH-1:0] accum[0:MAX_PN-1];
    logic [ACC_WIDTH-1:0] best_score;
    logic [OUTPUT_DATA_WIDTH-1:0] best_class;
    logic [PARALLEL_INPUTS-1:0] compute_input_word;

    logic weights_loaded_l0;
    logic weights_loaded_l1;
    logic weights_loaded_l2;
    logic thresholds_loaded_l0;
    logic thresholds_loaded_l1;
    logic all_layers_loaded;

    logic [CONFIG_BUS_WIDTH-1:0] cfg_beat_data;
    logic [CONFIG_BYTES_PER_BEAT-1:0] cfg_beat_keep;
    logic cfg_beat_pending;
    logic [BYTE_IDX_WIDTH-1:0] cfg_beat_byte_idx;

    logic cfg_in_payload;
    logic [3:0] cfg_header_byte_idx;
    logic [127:0] cfg_header;
    logic [7:0] cfg_msg_type;
    logic [7:0] cfg_layer_id;
    logic [15:0] cfg_bytes_per_neuron;
    logic [31:0] cfg_payload_bytes_left;
    logic [NEURON_COUNT_WIDTH-1:0] cfg_neuron_idx;
    logic [MSG_BYTES_WIDTH-1:0] cfg_byte_in_neuron;
    logic [1:0] cfg_threshold_byte_idx;
    logic [31:0] cfg_threshold_shift;

    logic [INPUT_BUS_WIDTH-1:0] in_beat_data;
    logic [INPUT_BYTES_PER_BEAT-1:0] in_beat_keep;
    logic in_beat_pending;
    logic [IN_BYTE_IDX_WIDTH-1:0] in_beat_byte_idx;
    logic [PIXEL_COUNT_WIDTH-1:0] image_pixels_loaded;
    logic image_complete;

    logic [1:0] compute_layer;
    logic [GROUP_COUNT_WIDTH-1:0] compute_group_idx;
    logic [WORD_COUNT_WIDTH-1:0]  compute_word_idx;

    logic [OUTPUT_BUS_WIDTH-1:0] out_data_reg;
    logic [7:0] cfg_byte_cur;

    function automatic int input_words_for_layer(input logic [1:0] layer_id);
        case (layer_id)
            2'd0: input_words_for_layer = L0_WORDS;
            2'd1: input_words_for_layer = L1_WORDS;
            default: input_words_for_layer = L2_WORDS;
        endcase
    endfunction

    function automatic int groups_for_layer(input logic [1:0] layer_id);
        case (layer_id)
            2'd0: groups_for_layer = L0_GROUPS;
            2'd1: groups_for_layer = L1_GROUPS;
            default: groups_for_layer = L2_GROUPS;
        endcase
    endfunction

    function automatic int neurons_for_layer(input logic [1:0] layer_id);
        case (layer_id)
            2'd0: neurons_for_layer = L1_INPUTS;
            2'd1: neurons_for_layer = L2_INPUTS;
            default: neurons_for_layer = L3_OUTPUTS;
        endcase
    endfunction

    function automatic int parallel_neurons_for_layer(input logic [1:0] layer_id);
        case (layer_id)
            2'd0: parallel_neurons_for_layer = PN0;
            2'd1: parallel_neurons_for_layer = PN1;
            default: parallel_neurons_for_layer = PN2;
        endcase
    endfunction

    assign cfg_byte_cur = cfg_beat_data[cfg_beat_byte_idx*8+:8];

    generate
        for (genvar slot = 0; slot < PN0; slot++) begin : gen_l0_weight_bank
            bnn_weight_bank #(
                .WIDTH(PARALLEL_INPUTS),
                .DEPTH(L0_SLOT_DEPTH)
            ) bank (
                .clk    (clk),
                .wr_en  (l0_weight_wr_en[slot]),
                .wr_addr(l0_weight_wr_addr[slot]),
                .wr_data(l0_weight_wr_data[slot]),
                .rd_en  (l0_weight_rd_en[slot]),
                .rd_addr(l0_weight_rd_addr[slot]),
                .rd_data(weight_rd_data_l0[slot])
            );
        end

        for (genvar slot = 0; slot < PN1; slot++) begin : gen_l1_weight_bank
            bnn_weight_bank #(
                .WIDTH(PARALLEL_INPUTS),
                .DEPTH(L1_SLOT_DEPTH)
            ) bank (
                .clk    (clk),
                .wr_en  (l1_weight_wr_en[slot]),
                .wr_addr(l1_weight_wr_addr[slot]),
                .wr_data(l1_weight_wr_data[slot]),
                .rd_en  (l1_weight_rd_en[slot]),
                .rd_addr(l1_weight_rd_addr[slot]),
                .rd_data(weight_rd_data_l1[slot])
            );
        end

        for (genvar slot = 0; slot < PN2; slot++) begin : gen_l2_weight_bank
            bnn_weight_bank #(
                .WIDTH(PARALLEL_INPUTS),
                .DEPTH(L2_SLOT_DEPTH)
            ) bank (
                .clk    (clk),
                .wr_en  (l2_weight_wr_en[slot]),
                .wr_addr(l2_weight_wr_addr[slot]),
                .wr_data(l2_weight_wr_data[slot]),
                .rd_en  (l2_weight_rd_en[slot]),
                .rd_addr(l2_weight_rd_addr[slot]),
                .rd_data(weight_rd_data_l2[slot])
            );
        end
    endgenerate

    // Present one independent RAM bank per neuron lane so Vivado can infer real memories.
    always_comb begin
        l0_weight_wr_en   = '0;
        l1_weight_wr_en   = '0;
        l2_weight_wr_en   = '0;
        l0_weight_rd_en   = '0;
        l1_weight_rd_en   = '0;
        l2_weight_rd_en   = '0;
        l0_weight_wr_addr = '0;
        l1_weight_wr_addr = '0;
        l2_weight_wr_addr = '0;
        l0_weight_rd_addr = '0;
        l1_weight_rd_addr = '0;
        l2_weight_rd_addr = '0;
        l0_weight_wr_data = '0;
        l1_weight_wr_data = '0;
        l2_weight_wr_data = '0;

        if (state == STATE_CONFIG &&
            cfg_beat_pending &&
            cfg_beat_keep[cfg_beat_byte_idx] &&
            cfg_in_payload &&
            cfg_msg_type == 8'd0) begin
            int cfg_slot;
            int cfg_group;
            int cfg_addr;

            case (cfg_layer_id)
                8'd0: begin
                    cfg_slot = cfg_neuron_idx % PN0;
                    cfg_group = cfg_neuron_idx / PN0;
                    cfg_addr = cfg_group * L0_WORDS + cfg_byte_in_neuron;
                    l0_weight_wr_en[cfg_slot] = 1'b1;
                    l0_weight_wr_addr[cfg_slot] = L0_ADDR_WIDTH'(cfg_addr);
                    l0_weight_wr_data[cfg_slot] = cfg_byte_cur;
                end
                8'd1: begin
                    cfg_slot = cfg_neuron_idx % PN1;
                    cfg_group = cfg_neuron_idx / PN1;
                    cfg_addr = cfg_group * L1_WORDS + cfg_byte_in_neuron;
                    l1_weight_wr_en[cfg_slot] = 1'b1;
                    l1_weight_wr_addr[cfg_slot] = L1_ADDR_WIDTH'(cfg_addr);
                    l1_weight_wr_data[cfg_slot] = cfg_byte_cur;
                end
                default: begin
                    cfg_slot = cfg_neuron_idx % PN2;
                    cfg_group = cfg_neuron_idx / PN2;
                    cfg_addr = cfg_group * L2_WORDS + cfg_byte_in_neuron;
                    l2_weight_wr_en[cfg_slot] = 1'b1;
                    l2_weight_wr_addr[cfg_slot] = L2_ADDR_WIDTH'(cfg_addr);
                    l2_weight_wr_data[cfg_slot] = cfg_byte_cur;
                end
            endcase
        end

        if (state == STATE_COMPUTE_READ) begin
            int active_neurons;
            int layer_neurons;

            active_neurons = parallel_neurons_for_layer(compute_layer);
            layer_neurons  = neurons_for_layer(compute_layer);

            case (compute_layer)
                2'd0: begin
                    for (int slot = 0; slot < PN0; slot++) begin
                        if ((slot < active_neurons) && ((compute_group_idx * PN0 + slot) < layer_neurons)) begin
                            l0_weight_rd_en[slot] = 1'b1;
                            l0_weight_rd_addr[slot] = L0_ADDR_WIDTH'(compute_group_idx * L0_WORDS + compute_word_idx);
                        end
                    end
                end
                2'd1: begin
                    for (int slot = 0; slot < PN1; slot++) begin
                        if ((slot < active_neurons) && ((compute_group_idx * PN1 + slot) < layer_neurons)) begin
                            l1_weight_rd_en[slot] = 1'b1;
                            l1_weight_rd_addr[slot] = L1_ADDR_WIDTH'(compute_group_idx * L1_WORDS + compute_word_idx);
                        end
                    end
                end
                default: begin
                    for (int slot = 0; slot < PN2; slot++) begin
                        if ((slot < active_neurons) && ((compute_group_idx * PN2 + slot) < layer_neurons)) begin
                            l2_weight_rd_en[slot] = 1'b1;
                            l2_weight_rd_addr[slot] = L2_ADDR_WIDTH'(compute_group_idx * L2_WORDS + compute_word_idx);
                        end
                    end
                end
            endcase
        end
    end

    always_comb begin
        all_layers_loaded = weights_loaded_l0 & weights_loaded_l1 & weights_loaded_l2 &
            thresholds_loaded_l0 & thresholds_loaded_l1;
    end

    assign config_ready  = (state == STATE_CONFIG) && !cfg_beat_pending && !all_layers_loaded;
    assign data_in_ready = (state == STATE_WAIT_IMAGE) && !in_beat_pending && !image_complete;

    assign data_out_valid = (state == STATE_OUTPUT);
    assign data_out_data  = out_data_reg;
    assign data_out_keep  = (state == STATE_OUTPUT) ? OUTPUT_KEEP_VALUE : '0;
    assign data_out_last  = (state == STATE_OUTPUT);

    initial begin
        assert (TOTAL_LAYERS == 4)
        else $fatal(1, "This contest implementation expects TOTAL_LAYERS=4.");

        assert (INPUT_DATA_WIDTH == 8)
        else $fatal(1, "bnn_fcc requires INPUT_DATA_WIDTH=8.");

        assert (CONFIG_BUS_WIDTH == 64 && INPUT_BUS_WIDTH == 64 && OUTPUT_BUS_WIDTH == 8)
        else $fatal(1, "This contest implementation expects the default bus widths.");

        assert (PARALLEL_INPUTS == 8)
        else $fatal(1, "This implementation expects PARALLEL_INPUTS=8.");

        assert (PN0 == PARALLEL_INPUTS && PN1 == PARALLEL_INPUTS)
        else $fatal(1, "Hidden-layer PARALLEL_NEURONS must match PARALLEL_INPUTS.");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_CONFIG;

            weights_loaded_l0    <= 1'b0;
            weights_loaded_l1    <= 1'b0;
            weights_loaded_l2    <= 1'b0;
            thresholds_loaded_l0 <= 1'b0;
            thresholds_loaded_l1 <= 1'b0;

            cfg_beat_data        <= '0;
            cfg_beat_keep        <= '0;
            cfg_beat_pending     <= 1'b0;
            cfg_beat_byte_idx    <= '0;
            cfg_in_payload       <= 1'b0;
            cfg_header_byte_idx  <= '0;
            cfg_header           <= '0;
            cfg_msg_type         <= '0;
            cfg_layer_id         <= '0;
            cfg_bytes_per_neuron <= '0;
            cfg_payload_bytes_left <= '0;
            cfg_neuron_idx       <= '0;
            cfg_byte_in_neuron   <= '0;
            cfg_threshold_byte_idx <= '0;
            cfg_threshold_shift  <= '0;

            in_beat_data         <= '0;
            in_beat_keep         <= '0;
            in_beat_pending      <= 1'b0;
            in_beat_byte_idx     <= '0;
            image_pixels_loaded  <= '0;
            image_complete       <= 1'b0;

            compute_layer        <= '0;
            compute_group_idx    <= '0;
            compute_word_idx     <= '0;
            compute_input_word   <= '0;
            best_score           <= '0;
            best_class           <= '0;
            out_data_reg         <= '0;

            for (int i = 0; i < MAX_PN; i++) begin
                accum[i] <= '0;
            end

            for (int w = 0; w < L0_WORDS; w++) input_buf_l0[w] <= '0;
            for (int w = 0; w < L1_WORDS; w++) input_buf_l1[w] <= '0;
            for (int w = 0; w < L2_WORDS; w++) input_buf_l2[w] <= '0;
        end else begin
            case (state)
                STATE_CONFIG: begin
                    if (cfg_beat_pending) begin
                        if (cfg_beat_keep[cfg_beat_byte_idx]) begin
                            if (!cfg_in_payload) begin
                                logic [127:0] next_header;

                                next_header = cfg_header;
                                next_header[cfg_header_byte_idx*8+:8] = cfg_byte_cur;
                                cfg_header  <= next_header;

                                if (cfg_header_byte_idx == 4'd15) begin
                                    cfg_in_payload        <= 1'b1;
                                    cfg_header_byte_idx   <= '0;
                                    cfg_msg_type          <= next_header[7:0];
                                    cfg_layer_id          <= next_header[15:8];
                                    cfg_bytes_per_neuron  <= next_header[63:48];
                                    cfg_payload_bytes_left <= next_header[95:64];
                                    cfg_neuron_idx        <= '0;
                                    cfg_byte_in_neuron    <= '0;
                                    cfg_threshold_byte_idx <= '0;
                                    cfg_threshold_shift   <= '0;
                                end else begin
                                    cfg_header_byte_idx <= cfg_header_byte_idx + 1'b1;
                                end
                            end else begin
                                if (cfg_msg_type == 8'd0) begin
                                end else begin
                                    logic [31:0] next_threshold;

                                    next_threshold = cfg_threshold_shift;
                                    next_threshold[cfg_threshold_byte_idx*8+:8] = cfg_byte_cur;
                                    cfg_threshold_shift <= next_threshold;

                                    if (cfg_threshold_byte_idx == 2'd3) begin
                                        case (cfg_layer_id)
                                            8'd0: begin
                                                threshold_mem_l0[cfg_neuron_idx] <= ACC_WIDTH'(next_threshold);
                                            end
                                            default: begin
                                                threshold_mem_l1[cfg_neuron_idx] <= ACC_WIDTH'(next_threshold);
                                            end
                                        endcase
                                        cfg_threshold_byte_idx <= '0;
                                        cfg_threshold_shift    <= '0;
                                    end else begin
                                        cfg_threshold_byte_idx <= cfg_threshold_byte_idx + 1'b1;
                                    end
                                end

                                if (cfg_msg_type == 8'd0) begin
                                    if (cfg_byte_in_neuron + 1 >= cfg_bytes_per_neuron) begin
                                        cfg_byte_in_neuron <= '0;
                                        cfg_neuron_idx     <= cfg_neuron_idx + 1'b1;
                                    end else begin
                                        cfg_byte_in_neuron <= cfg_byte_in_neuron + 1'b1;
                                    end
                                end else if (cfg_threshold_byte_idx == 2'd3) begin
                                    cfg_neuron_idx <= cfg_neuron_idx + 1'b1;
                                end

                                if (cfg_payload_bytes_left == 32'd1) begin
                                    cfg_in_payload        <= 1'b0;
                                    cfg_header            <= '0;
                                    cfg_header_byte_idx   <= '0;
                                    cfg_payload_bytes_left <= '0;
                                    cfg_neuron_idx        <= '0;
                                    cfg_byte_in_neuron    <= '0;
                                    cfg_threshold_byte_idx <= '0;
                                    cfg_threshold_shift   <= '0;

                                    if (cfg_msg_type == 8'd0) begin
                                        case (cfg_layer_id)
                                            8'd0: weights_loaded_l0 <= 1'b1;
                                            8'd1: weights_loaded_l1 <= 1'b1;
                                            default: weights_loaded_l2 <= 1'b1;
                                        endcase
                                    end else begin
                                        case (cfg_layer_id)
                                            8'd0: thresholds_loaded_l0 <= 1'b1;
                                            default: thresholds_loaded_l1 <= 1'b1;
                                        endcase
                                    end
                                end else begin
                                    cfg_payload_bytes_left <= cfg_payload_bytes_left - 1'b1;
                                end
                            end
                        end

                        if (cfg_beat_byte_idx + 1 >= CONFIG_BYTES_PER_BEAT) begin
                            cfg_beat_pending  <= 1'b0;
                            cfg_beat_byte_idx <= '0;
                        end else begin
                            cfg_beat_byte_idx <= cfg_beat_byte_idx + 1'b1;
                        end
                    end else if (config_valid) begin
                        cfg_beat_pending  <= 1'b1;
                        cfg_beat_data     <= config_data;
                        cfg_beat_keep     <= config_keep;
                        cfg_beat_byte_idx <= '0;
                    end else if (all_layers_loaded) begin
                        state <= STATE_WAIT_IMAGE;
                    end
                end

                STATE_WAIT_IMAGE: begin
                    if (in_beat_pending) begin
                        if (in_beat_keep[in_beat_byte_idx] && image_pixels_loaded < L0_INPUTS) begin
                            int word_idx;
                            int bit_idx;
                            logic [7:0] pixel_byte;
                            logic [PARALLEL_INPUTS-1:0] next_input_word;

                            pixel_byte = in_beat_data[in_beat_byte_idx*8+:8];
                            word_idx   = image_pixels_loaded / PARALLEL_INPUTS;
                            bit_idx    = image_pixels_loaded % PARALLEL_INPUTS;
                            next_input_word = (bit_idx == 0) ? '0 : input_buf_l0[word_idx];
                            next_input_word[bit_idx] = (pixel_byte >= 8'd128);
                            input_buf_l0[word_idx] <= next_input_word;

                            if (image_pixels_loaded + 1 >= L0_INPUTS) image_complete <= 1'b1;
                            image_pixels_loaded <= image_pixels_loaded + 1'b1;
                        end

                        if (in_beat_byte_idx + 1 >= INPUT_BYTES_PER_BEAT) begin
                            in_beat_pending  <= 1'b0;
                            in_beat_byte_idx <= '0;
                        end else begin
                            in_beat_byte_idx <= in_beat_byte_idx + 1'b1;
                        end
                    end else if (image_complete) begin
                        state             <= STATE_COMPUTE_READ;
                        compute_layer     <= '0;
                        compute_group_idx <= '0;
                        compute_word_idx  <= '0;
                        compute_input_word <= '0;
                        best_score        <= '0;
                        best_class        <= '0;

                        for (int i = 0; i < MAX_PN; i++) accum[i] <= '0;
                    end else if (data_in_valid) begin
                        in_beat_pending  <= 1'b1;
                        in_beat_data     <= data_in_data;
                        in_beat_keep     <= data_in_keep;
                        in_beat_byte_idx <= '0;
                    end
                end

                STATE_COMPUTE_READ: begin
                    int input_words;
                    int active_neurons;
                    int layer_neurons;

                    input_words    = input_words_for_layer(compute_layer);
                    active_neurons = parallel_neurons_for_layer(compute_layer);
                    layer_neurons  = neurons_for_layer(compute_layer);

                    case (compute_layer)
                        2'd0: compute_input_word <= input_buf_l0[compute_word_idx];
                        2'd1: compute_input_word <= input_buf_l1[compute_word_idx];
                        default: compute_input_word <= input_buf_l2[compute_word_idx];
                    endcase

                    state <= STATE_COMPUTE_ACCUM;
                end

                STATE_COMPUTE_ACCUM: begin
                    int input_words;
                    int active_neurons;
                    int layer_neurons;

                    input_words    = input_words_for_layer(compute_layer);
                    active_neurons = parallel_neurons_for_layer(compute_layer);
                    layer_neurons  = neurons_for_layer(compute_layer);

                    case (compute_layer)
                        2'd0: begin
                            for (int slot = 0; slot < PN0; slot++) begin
                                if ((slot < active_neurons) && ((compute_group_idx * PN0 + slot) < layer_neurons)) begin
                                    accum[slot] <= accum[slot] + ACC_WIDTH'(popcount8(~(weight_rd_data_l0[slot] ^ compute_input_word)));
                                end else begin
                                    accum[slot] <= '0;
                                end
                            end
                        end
                        2'd1: begin
                            for (int slot = 0; slot < PN1; slot++) begin
                                if ((slot < active_neurons) && ((compute_group_idx * PN1 + slot) < layer_neurons)) begin
                                    accum[slot] <= accum[slot] + ACC_WIDTH'(popcount8(~(weight_rd_data_l1[slot] ^ compute_input_word)));
                                end else begin
                                    accum[slot] <= '0;
                                end
                            end
                        end
                        default: begin
                            for (int slot = 0; slot < PN2; slot++) begin
                                if ((slot < active_neurons) && ((compute_group_idx * PN2 + slot) < layer_neurons)) begin
                                    accum[slot] <= accum[slot] + ACC_WIDTH'(popcount8(~(weight_rd_data_l2[slot] ^ compute_input_word)));
                                end else begin
                                    accum[slot] <= '0;
                                end
                            end
                        end
                    endcase

                    if (compute_word_idx + 1 >= input_words) begin
                        state <= STATE_COMPUTE_WRITE;
                    end else begin
                        compute_word_idx <= compute_word_idx + 1'b1;
                        state <= STATE_COMPUTE_READ;
                    end
                end

                STATE_COMPUTE_WRITE: begin
                    int active_neurons;
                    int layer_neurons;
                    int total_groups;
                    logic [PARALLEL_INPUTS-1:0] activation_word;

                    active_neurons = parallel_neurons_for_layer(compute_layer);
                    layer_neurons  = neurons_for_layer(compute_layer);
                    total_groups   = groups_for_layer(compute_layer);
                    activation_word = '0;

                    if (compute_layer == 2'd2) begin
                        logic [ACC_WIDTH-1:0] temp_best_score;
                        logic [OUTPUT_DATA_WIDTH-1:0] temp_best_class;

                        temp_best_score = best_score;
                        temp_best_class = best_class;

                        for (int slot = 0; slot < PN2; slot++) begin
                            int neuron_idx;

                            neuron_idx = compute_group_idx * PN2 + slot;
                            if ((slot < active_neurons) && (neuron_idx < layer_neurons)) begin
                                if (accum[slot] > temp_best_score) begin
                                    temp_best_score = accum[slot];
                                    temp_best_class = OUTPUT_DATA_WIDTH'(neuron_idx);
                                end
                            end
                        end

                        best_score <= temp_best_score;
                        best_class <= temp_best_class;

                        if (compute_group_idx + 1 >= total_groups) begin
                            out_data_reg        <= OUTPUT_BUS_WIDTH'(temp_best_class);
                            image_pixels_loaded <= '0;
                            image_complete      <= 1'b0;
                            state               <= STATE_OUTPUT;
                        end else begin
                            compute_group_idx   <= compute_group_idx + 1'b1;
                            compute_word_idx    <= '0;
                            state               <= STATE_COMPUTE_READ;
                        end
                    end else begin
                        if (compute_layer == 2'd0) begin
                            for (int slot = 0; slot < PN0; slot++) begin
                                int neuron_idx;

                                neuron_idx = compute_group_idx * PN0 + slot;
                                if ((slot < active_neurons) && (neuron_idx < layer_neurons)) begin
                                    activation_word[slot] = (accum[slot] >= threshold_mem_l0[neuron_idx]);
                                end
                            end
                            input_buf_l1[compute_group_idx] <= activation_word;
                        end else begin
                            for (int slot = 0; slot < PN1; slot++) begin
                                int neuron_idx;

                                neuron_idx = compute_group_idx * PN1 + slot;
                                if ((slot < active_neurons) && (neuron_idx < layer_neurons)) begin
                                    activation_word[slot] = (accum[slot] >= threshold_mem_l1[neuron_idx]);
                                end
                            end
                            input_buf_l2[compute_group_idx] <= activation_word;
                        end

                        if (compute_group_idx + 1 >= total_groups) begin
                            compute_layer     <= compute_layer + 1'b1;
                            compute_group_idx <= '0;
                            compute_word_idx  <= '0;
                            state             <= STATE_COMPUTE_READ;
                        end else begin
                            compute_group_idx <= compute_group_idx + 1'b1;
                            compute_word_idx  <= '0;
                            state             <= STATE_COMPUTE_READ;
                        end
                    end

                    for (int i = 0; i < MAX_PN; i++) begin
                        accum[i] <= '0;
                    end
                end

                STATE_OUTPUT: begin
                    if (data_out_ready) begin
                        state <= STATE_WAIT_IMAGE;
                    end
                end

                default: state <= STATE_CONFIG;
            endcase
        end
    end

endmodule

module bnn_weight_bank #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 2
) (
    input  logic                    clk,
    input  logic                    wr_en,
    input  logic [$clog2(DEPTH)-1:0] wr_addr,
    input  logic [WIDTH-1:0]        wr_data,
    input  logic                    rd_en,
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic [WIDTH-1:0]        rd_data
);
    (* ram_style = "block" *) logic [WIDTH-1:0] mem[0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    always_ff @(posedge clk) begin
        if (rd_en) rd_data <= mem[rd_addr];
    end
endmodule
