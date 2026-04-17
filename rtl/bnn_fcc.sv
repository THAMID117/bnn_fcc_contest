module bnn_fcc #(
    parameter int INPUT_DATA_WIDTH  = 8,
    parameter int INPUT_BUS_WIDTH   = 64,
    parameter int CONFIG_BUS_WIDTH  = 64,
    parameter int OUTPUT_DATA_WIDTH = 4,
    parameter int OUTPUT_BUS_WIDTH  = 8,

    parameter int TOTAL_LAYERS = 4,
    parameter int TOPOLOGY[TOTAL_LAYERS] = '{0: 784, 1: 256, 2: 256, 3: 10, default: 0},

    parameter int PARALLEL_INPUTS = 8,
    parameter int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{default: 8}
) (
    input logic clk,
    input logic rst,

    // AXI streaming configuration interface (consumer)
    input  logic                          config_valid,
    output logic                          config_ready,
    input  logic [  CONFIG_BUS_WIDTH-1:0] config_data,
    input  logic [CONFIG_BUS_WIDTH/8-1:0] config_keep,
    input  logic                          config_last,

    // AXI streaming image input interface (consumer)
    input  logic                         data_in_valid,
    output logic                         data_in_ready,
    input  logic [  INPUT_BUS_WIDTH-1:0] data_in_data,
    input  logic [INPUT_BUS_WIDTH/8-1:0] data_in_keep,
    input  logic                         data_in_last,

    // AXI streaming classification output interface (producer)
    output logic                          data_out_valid,
    input  logic                          data_out_ready,
    output logic [  OUTPUT_BUS_WIDTH-1:0] data_out_data,
    output logic [OUTPUT_BUS_WIDTH/8-1:0] data_out_keep,
    output logic                          data_out_last
);

    localparam int NON_INPUT_LAYERS = TOTAL_LAYERS - 1;
    localparam int CONFIG_BYTES_PER_BEAT = CONFIG_BUS_WIDTH / 8;
    localparam int INPUT_BYTES_PER_BEAT  = INPUT_BUS_WIDTH / 8;
    localparam int OUTPUT_VALID_BYTES    = (OUTPUT_DATA_WIDTH + 7) / 8;
    localparam int WEIGHT_BYTES_PER_WORD = PARALLEL_INPUTS / 8;

    function automatic int ceil_div(input int value, input int divisor);
        ceil_div = (value + divisor - 1) / divisor;
    endfunction

    function automatic int max_layer_inputs();
        int max_val;
        max_val = 1;
        for (int i = 0; i < NON_INPUT_LAYERS; i++) begin
            if (TOPOLOGY[i] > max_val) max_val = TOPOLOGY[i];
        end
        return max_val;
    endfunction

    function automatic int max_layer_neurons();
        int max_val;
        max_val = 1;
        for (int i = 1; i < TOTAL_LAYERS; i++) begin
            if (TOPOLOGY[i] > max_val) max_val = TOPOLOGY[i];
        end
        return max_val;
    endfunction

    function automatic int max_parallel_neurons();
        int max_val;
        max_val = 1;
        for (int i = 0; i < NON_INPUT_LAYERS; i++) begin
            if (PARALLEL_NEURONS[i] > max_val) max_val = PARALLEL_NEURONS[i];
        end
        return max_val;
    endfunction

    function automatic int layer_word_count(input int layer_idx);
        layer_word_count = ceil_div(TOPOLOGY[layer_idx], PARALLEL_INPUTS);
    endfunction

    function automatic int popcount_word(input logic [PARALLEL_INPUTS-1:0] value);
        int count;
        count = 0;
        for (int i = 0; i < PARALLEL_INPUTS; i++) begin
            count += value[i];
        end
        return count;
    endfunction

    localparam int MAX_LAYER_INPUTS      = max_layer_inputs();
    localparam int MAX_LAYER_NEURONS     = max_layer_neurons();
    localparam int MAX_PARALLEL_NEURONS  = max_parallel_neurons();
    localparam int MAX_WEIGHT_WORDS      = ceil_div(MAX_LAYER_INPUTS, PARALLEL_INPUTS);
    localparam int ACC_WIDTH             = (MAX_LAYER_INPUTS > 0) ? $clog2(MAX_LAYER_INPUTS + 1) : 1;
    localparam int PIXEL_COUNT_WIDTH     = (MAX_LAYER_INPUTS > 0) ? $clog2(MAX_LAYER_INPUTS + 1) : 1;
    localparam int NEURON_COUNT_WIDTH    = (MAX_LAYER_NEURONS > 0) ? $clog2(MAX_LAYER_NEURONS + 1) : 1;
    localparam int WORD_COUNT_WIDTH      = (MAX_WEIGHT_WORDS > 0) ? $clog2(MAX_WEIGHT_WORDS + 1) : 1;
    localparam logic [OUTPUT_BUS_WIDTH/8-1:0] OUTPUT_KEEP_VALUE =
        (OUTPUT_VALID_BYTES == 0) ? '0 : ({(OUTPUT_BUS_WIDTH/8){1'b1}} >> ((OUTPUT_BUS_WIDTH/8) - OUTPUT_VALID_BYTES));

    typedef enum logic [2:0] {
        STATE_CONFIG,
        STATE_WAIT_IMAGE,
        STATE_COMPUTE_ACCUM,
        STATE_COMPUTE_WRITE,
        STATE_OUTPUT
    } state_t;

    state_t state;

    logic [PARALLEL_INPUTS-1:0] weight_mem[NON_INPUT_LAYERS][MAX_LAYER_NEURONS][MAX_WEIGHT_WORDS];
    logic [31:0] threshold_mem[NON_INPUT_LAYERS][MAX_LAYER_NEURONS];
    logic [PARALLEL_INPUTS-1:0] layer_input_mem[NON_INPUT_LAYERS][MAX_WEIGHT_WORDS];

    logic [ACC_WIDTH-1:0] accum[MAX_PARALLEL_NEURONS];

    logic [NON_INPUT_LAYERS-1:0] weights_loaded;
    logic [NON_INPUT_LAYERS-1:0] thresholds_loaded;
    logic                        all_layers_loaded;

    logic                         cfg_beat_pending;
    logic [  CONFIG_BUS_WIDTH-1:0] cfg_beat_data;
    logic [CONFIG_BYTES_PER_BEAT-1:0] cfg_beat_keep;
    logic                         cfg_beat_last;
    logic [$clog2(CONFIG_BYTES_PER_BEAT+1)-1:0] cfg_beat_byte_idx;

    logic                         cfg_in_payload;
    logic [3:0]                   cfg_header_byte_idx;
    logic [127:0]                 cfg_header;
    logic [7:0]                   cfg_msg_type;
    logic [7:0]                   cfg_layer_id;
    logic [15:0]                  cfg_layer_inputs;
    logic [15:0]                  cfg_num_neurons;
    logic [15:0]                  cfg_bytes_per_neuron;
    logic [31:0]                  cfg_total_bytes;
    logic [31:0]                  cfg_payload_bytes_left;
    logic [NEURON_COUNT_WIDTH-1:0] cfg_neuron_idx;
    logic [15:0]                  cfg_byte_in_neuron;
    logic [1:0]                   cfg_threshold_byte_idx;
    logic [31:0]                  cfg_threshold_shift;

    logic                        in_beat_pending;
    logic [  INPUT_BUS_WIDTH-1:0] in_beat_data;
    logic [INPUT_BYTES_PER_BEAT-1:0] in_beat_keep;
    logic                        in_beat_last;
    logic [$clog2(INPUT_BYTES_PER_BEAT+1)-1:0] in_beat_byte_idx;
    logic [PIXEL_COUNT_WIDTH-1:0] image_pixels_loaded;
    logic                        image_complete;

    logic [$clog2(NON_INPUT_LAYERS+1)-1:0] compute_layer;
    logic [NEURON_COUNT_WIDTH-1:0]         compute_neuron_base;
    logic [WORD_COUNT_WIDTH-1:0]           compute_word_idx;
    logic [ACC_WIDTH-1:0]                  best_score;
    logic [OUTPUT_DATA_WIDTH-1:0]          best_class;

    logic [OUTPUT_BUS_WIDTH-1:0]           out_data_reg;

    always_comb begin
        all_layers_loaded = 1'b1;
        for (int i = 0; i < NON_INPUT_LAYERS; i++) begin
            all_layers_loaded &= weights_loaded[i] & thresholds_loaded[i];
        end
    end

    assign config_ready  = (state == STATE_CONFIG) && !cfg_beat_pending && !all_layers_loaded;
    assign data_in_ready = (state == STATE_WAIT_IMAGE) && !in_beat_pending && !image_complete;

    assign data_out_valid = (state == STATE_OUTPUT);
    assign data_out_data  = out_data_reg;
    assign data_out_keep  = (state == STATE_OUTPUT) ? OUTPUT_KEEP_VALUE : '0;
    assign data_out_last  = (state == STATE_OUTPUT);

    initial begin
        assert (INPUT_DATA_WIDTH == 8)
        else $fatal(1, "bnn_fcc requires INPUT_DATA_WIDTH=8.");

        assert (CONFIG_BUS_WIDTH % 8 == 0)
        else $fatal(1, "CONFIG_BUS_WIDTH must be byte aligned.");

        assert (INPUT_BUS_WIDTH % 8 == 0)
        else $fatal(1, "INPUT_BUS_WIDTH must be byte aligned.");

        assert (PARALLEL_INPUTS > 0 && (PARALLEL_INPUTS % 8) == 0)
        else $fatal(1, "This implementation requires PARALLEL_INPUTS to be a positive multiple of 8.");

        for (int i = 0; i < NON_INPUT_LAYERS - 1; i++) begin
            assert (PARALLEL_NEURONS[i] == PARALLEL_INPUTS)
            else $fatal(1, "Hidden-layer PARALLEL_NEURONS must match PARALLEL_INPUTS for this architecture.");
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_CONFIG;

            cfg_beat_pending    <= 1'b0;
            cfg_beat_data       <= '0;
            cfg_beat_keep       <= '0;
            cfg_beat_last       <= 1'b0;
            cfg_beat_byte_idx   <= '0;
            cfg_in_payload      <= 1'b0;
            cfg_header_byte_idx <= '0;
            cfg_header          <= '0;
            cfg_msg_type        <= '0;
            cfg_layer_id        <= '0;
            cfg_layer_inputs    <= '0;
            cfg_num_neurons     <= '0;
            cfg_bytes_per_neuron <= '0;
            cfg_total_bytes     <= '0;
            cfg_payload_bytes_left <= '0;
            cfg_neuron_idx      <= '0;
            cfg_byte_in_neuron  <= '0;
            cfg_threshold_byte_idx <= '0;
            cfg_threshold_shift <= '0;

            in_beat_pending     <= 1'b0;
            in_beat_data        <= '0;
            in_beat_keep        <= '0;
            in_beat_last        <= 1'b0;
            in_beat_byte_idx    <= '0;
            image_pixels_loaded <= '0;
            image_complete      <= 1'b0;

            compute_layer       <= '0;
            compute_neuron_base <= '0;
            compute_word_idx    <= '0;
            best_score          <= '0;
            best_class          <= '0;
            out_data_reg        <= '0;

            for (int l = 0; l < NON_INPUT_LAYERS; l++) begin
                weights_loaded[l]    <= 1'b0;
                thresholds_loaded[l] <= (l == NON_INPUT_LAYERS - 1);

                for (int n = 0; n < MAX_LAYER_NEURONS; n++) begin
                    threshold_mem[l][n] <= '0;
                    for (int w = 0; w < MAX_WEIGHT_WORDS; w++) begin
                        weight_mem[l][n][w] <= {PARALLEL_INPUTS{1'b1}};
                    end
                end

                for (int w = 0; w < MAX_WEIGHT_WORDS; w++) begin
                    layer_input_mem[l][w] <= '0;
                end
            end

            for (int i = 0; i < MAX_PARALLEL_NEURONS; i++) begin
                accum[i] <= '0;
            end
        end else begin
            case (state)
                STATE_CONFIG: begin
                    if (cfg_beat_pending) begin
                        if (cfg_beat_byte_idx < CONFIG_BYTES_PER_BEAT) begin
                            if (cfg_beat_keep[cfg_beat_byte_idx]) begin
                                logic [7:0] cfg_byte;
                                cfg_byte = cfg_beat_data[cfg_beat_byte_idx*8+:8];

                                if (!cfg_in_payload) begin
                                    logic [127:0] next_header;
                                    next_header = cfg_header;
                                    next_header[cfg_header_byte_idx*8+:8] = cfg_byte;
                                    cfg_header <= next_header;

                                    if (cfg_header_byte_idx == 4'd15) begin
                                        cfg_in_payload         <= 1'b1;
                                        cfg_header_byte_idx    <= '0;
                                        cfg_msg_type           <= next_header[7:0];
                                        cfg_layer_id           <= next_header[15:8];
                                        cfg_layer_inputs       <= next_header[31:16];
                                        cfg_num_neurons        <= next_header[47:32];
                                        cfg_bytes_per_neuron   <= next_header[63:48];
                                        cfg_total_bytes        <= next_header[95:64];
                                        cfg_payload_bytes_left <= next_header[95:64];
                                        cfg_neuron_idx         <= '0;
                                        cfg_byte_in_neuron     <= '0;
                                        cfg_threshold_byte_idx <= '0;
                                        cfg_threshold_shift    <= '0;
                                    end else begin
                                        cfg_header_byte_idx <= cfg_header_byte_idx + 1'b1;
                                    end
                                end else begin
                                    if (cfg_msg_type == 8'd0) begin
                                        int word_idx;
                                        int byte_in_word;
                                        logic [PARALLEL_INPUTS-1:0] next_word;

                                        word_idx     = cfg_byte_in_neuron / WEIGHT_BYTES_PER_WORD;
                                        byte_in_word = cfg_byte_in_neuron % WEIGHT_BYTES_PER_WORD;
                                        next_word    = (byte_in_word == 0) ? {PARALLEL_INPUTS{1'b1}} : weight_mem[cfg_layer_id][cfg_neuron_idx][word_idx];
                                        next_word[byte_in_word*8+:8] = cfg_byte;
                                        weight_mem[cfg_layer_id][cfg_neuron_idx][word_idx] <= next_word;
                                    end else begin
                                        logic [31:0] next_threshold;
                                        next_threshold = cfg_threshold_shift;
                                        next_threshold[cfg_threshold_byte_idx*8+:8] = cfg_byte;
                                        cfg_threshold_shift <= next_threshold;

                                        if (cfg_threshold_byte_idx == 2'd3) begin
                                            threshold_mem[cfg_layer_id][cfg_neuron_idx] <= next_threshold;
                                            cfg_threshold_byte_idx <= '0;
                                            cfg_threshold_shift <= '0;
                                        end else begin
                                            cfg_threshold_byte_idx <= cfg_threshold_byte_idx + 1'b1;
                                        end
                                    end

                                    if (cfg_msg_type == 8'd0) begin
                                        if (cfg_byte_in_neuron == cfg_bytes_per_neuron - 1) begin
                                            cfg_byte_in_neuron <= '0;
                                            cfg_neuron_idx <= cfg_neuron_idx + 1'b1;
                                        end else begin
                                            cfg_byte_in_neuron <= cfg_byte_in_neuron + 1'b1;
                                        end
                                    end else begin
                                        if (cfg_threshold_byte_idx == 2'd3) begin
                                            cfg_neuron_idx <= cfg_neuron_idx + 1'b1;
                                        end
                                    end

                                    if (cfg_payload_bytes_left == 32'd1) begin
                                        cfg_in_payload         <= 1'b0;
                                        cfg_payload_bytes_left <= '0;
                                        cfg_header             <= '0;
                                        cfg_header_byte_idx    <= '0;
                                        cfg_neuron_idx         <= '0;
                                        cfg_byte_in_neuron     <= '0;
                                        cfg_threshold_byte_idx <= '0;
                                        cfg_threshold_shift    <= '0;

                                        if (cfg_msg_type == 8'd0) weights_loaded[cfg_layer_id] <= 1'b1;
                                        else thresholds_loaded[cfg_layer_id] <= 1'b1;
                                    end else begin
                                        cfg_payload_bytes_left <= cfg_payload_bytes_left - 1'b1;
                                    end
                                end
                            end

                            if (cfg_beat_byte_idx == CONFIG_BYTES_PER_BEAT - 1) begin
                                cfg_beat_pending  <= 1'b0;
                                cfg_beat_byte_idx <= '0;
                                cfg_beat_last     <= 1'b0;
                            end else begin
                                cfg_beat_byte_idx <= cfg_beat_byte_idx + 1'b1;
                            end
                        end
                    end else if (config_valid) begin
                        cfg_beat_pending  <= 1'b1;
                        cfg_beat_data     <= config_data;
                        cfg_beat_keep     <= config_keep;
                        cfg_beat_last     <= config_last;
                        cfg_beat_byte_idx <= '0;
                    end else if (all_layers_loaded) begin
                        state              <= STATE_WAIT_IMAGE;
                        image_pixels_loaded <= '0;
                        image_complete      <= 1'b0;
                    end
                end

                STATE_WAIT_IMAGE: begin
                    if (in_beat_pending) begin
                        if (in_beat_byte_idx < INPUT_BYTES_PER_BEAT) begin
                            if (in_beat_keep[in_beat_byte_idx] && image_pixels_loaded < TOPOLOGY[0]) begin
                                int word_idx;
                                int bit_idx;
                                logic [7:0] pixel_byte;
                                logic [PARALLEL_INPUTS-1:0] next_input_word;

                                pixel_byte = in_beat_data[in_beat_byte_idx*8+:8];
                                word_idx   = image_pixels_loaded / PARALLEL_INPUTS;
                                bit_idx    = image_pixels_loaded % PARALLEL_INPUTS;
                                next_input_word = (bit_idx == 0) ? '0 : layer_input_mem[0][word_idx];
                                next_input_word[bit_idx] = (pixel_byte >= 8'd128);
                                layer_input_mem[0][word_idx] <= next_input_word;

                                if (image_pixels_loaded == TOPOLOGY[0] - 1) begin
                                    image_complete <= 1'b1;
                                end
                                image_pixels_loaded <= image_pixels_loaded + 1'b1;
                            end

                            if (in_beat_byte_idx == INPUT_BYTES_PER_BEAT - 1) begin
                                in_beat_pending  <= 1'b0;
                                in_beat_byte_idx <= '0;
                            end else begin
                                in_beat_byte_idx <= in_beat_byte_idx + 1'b1;
                            end
                        end
                    end else if (image_complete) begin
                        state              <= STATE_COMPUTE_ACCUM;
                        compute_layer       <= '0;
                        compute_neuron_base <= '0;
                        compute_word_idx    <= '0;
                        best_score          <= '0;
                        best_class          <= '0;
                        for (int i = 0; i < MAX_PARALLEL_NEURONS; i++) begin
                            accum[i] <= '0;
                        end
                    end else if (data_in_valid) begin
                        in_beat_pending  <= 1'b1;
                        in_beat_data     <= data_in_data;
                        in_beat_keep     <= data_in_keep;
                        in_beat_last     <= data_in_last;
                        in_beat_byte_idx <= '0;
                    end
                end

                STATE_COMPUTE_ACCUM: begin
                    int active_neurons;
                    int input_words;
                    logic [PARALLEL_INPUTS-1:0] input_word;

                    active_neurons = PARALLEL_NEURONS[compute_layer];
                    input_words    = layer_word_count(compute_layer);
                    input_word     = layer_input_mem[compute_layer][compute_word_idx];

                    for (int slot = 0; slot < MAX_PARALLEL_NEURONS; slot++) begin
                        if ((slot < active_neurons) && ((compute_neuron_base + slot) < TOPOLOGY[compute_layer+1])) begin
                            logic [PARALLEL_INPUTS-1:0] xnor_word;
                            xnor_word = ~(weight_mem[compute_layer][compute_neuron_base + slot][compute_word_idx] ^ input_word);
                            accum[slot] <= accum[slot] + popcount_word(xnor_word);
                        end else begin
                            accum[slot] <= '0;
                        end
                    end

                    if (compute_word_idx + 1 >= input_words) begin
                        state <= STATE_COMPUTE_WRITE;
                    end else begin
                        compute_word_idx <= compute_word_idx + 1'b1;
                    end
                end

                STATE_COMPUTE_WRITE: begin
                    int active_neurons;
                    int layer_neurons;
                    logic [PARALLEL_INPUTS-1:0] activation_word;

                    active_neurons = PARALLEL_NEURONS[compute_layer];
                    layer_neurons  = TOPOLOGY[compute_layer+1];
                    activation_word = '0;

                    if (compute_layer == NON_INPUT_LAYERS - 1) begin
                        logic [ACC_WIDTH-1:0] temp_best_score;
                        logic [OUTPUT_DATA_WIDTH-1:0] temp_best_class;

                        temp_best_score = best_score;
                        temp_best_class = best_class;

                        for (int slot = 0; slot < MAX_PARALLEL_NEURONS; slot++) begin
                            if ((slot < active_neurons) && ((compute_neuron_base + slot) < layer_neurons)) begin
                                if (accum[slot] > temp_best_score) begin
                                    temp_best_score = accum[slot];
                                    temp_best_class = OUTPUT_DATA_WIDTH'(compute_neuron_base + slot);
                                end
                            end
                        end

                        best_score <= temp_best_score;
                        best_class <= temp_best_class;

                        if (compute_neuron_base + active_neurons >= layer_neurons) begin
                            state <= STATE_OUTPUT;
                            out_data_reg <= OUTPUT_BUS_WIDTH'(temp_best_class);
                            image_pixels_loaded <= '0;
                            image_complete <= 1'b0;
                        end else begin
                            compute_neuron_base <= compute_neuron_base + active_neurons;
                            compute_word_idx    <= '0;
                            state               <= STATE_COMPUTE_ACCUM;
                        end
                    end else begin
                        for (int slot = 0; slot < PARALLEL_INPUTS; slot++) begin
                            if ((slot < active_neurons) && ((compute_neuron_base + slot) < layer_neurons)) begin
                                activation_word[slot] = (accum[slot] >= threshold_mem[compute_layer][compute_neuron_base + slot]);
                            end
                        end

                        layer_input_mem[compute_layer+1][compute_neuron_base / PARALLEL_INPUTS] <= activation_word;

                        if (compute_neuron_base + active_neurons >= layer_neurons) begin
                            compute_layer       <= compute_layer + 1'b1;
                            compute_neuron_base <= '0;
                            compute_word_idx    <= '0;
                            state               <= STATE_COMPUTE_ACCUM;
                        end else begin
                            compute_neuron_base <= compute_neuron_base + active_neurons;
                            compute_word_idx    <= '0;
                            state               <= STATE_COMPUTE_ACCUM;
                        end
                    end

                    for (int slot = 0; slot < MAX_PARALLEL_NEURONS; slot++) begin
                        accum[slot] <= '0;
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
