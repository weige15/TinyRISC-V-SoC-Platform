`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// npu_burst_dot_product
//
// Signed int8 dot product of two byte vectors in memory, fetched with AXI4
// INCR read bursts:
//
//     result = sum_{i = 0}^{byte_length - 1} int8(input[i]) * int8(filter[i])
//
// The sum wraps modulo 2^32, like the SIMD MAC accumulator.
//
// Data flow
//   The vectors are processed in chunks of up to CHUNK_WORDS words
//   (CHUNK_WORDS * 4 bytes). For every chunk the read-address side requests
//   the input segment first and the filter segment right after it, so both
//   requests can be in flight together. The read-data side stores the input
//   words of the chunk in a small buffer, then multiplies every filter word
//   with the buffered input word at the same position as it arrives
//   (4 int8 lanes per cycle, one AXI beat per cycle).
//
// Addresses and lengths that are not multiples of 4 bytes
//   Each segment fetches the word-aligned span that covers it. A funnel
//   shifter realigns the byte stream so that vector byte j sits in lane j % 4
//   of aligned word j / 4, independently for the input and the filter. Lanes
//   past the end of the vector are zeroed.
//
// 4 KB rule
//   A burst never crosses a 4 KB boundary: its length is the minimum of the
//   words left in the segment, MAX_BURST_BEATS, and the words left before the
//   next 4 KB boundary.
//
// R-channel flow control
//   RREADY is high while a segment streams. It is low for the one-cycle setup
//   of every segment, and for one cycle at the end of a misaligned segment
//   whose last aligned word has no following raw word (the funnel shifter
//   emits that word on its own).
//
// Coherence
//   The engine reads memory directly. Software must write back (cbo.clean)
//   every data-cache line that overlaps either vector before starting it.
//////////////////////////////////////////////////////////////////////////////////
module npu_burst_dot_product #(
    parameter integer MAX_BURST_BEATS = 256,  // AXI4 INCR limit (ARLEN = 255)
    parameter integer CHUNK_WORDS     = 256   // buffered input words per chunk
) (
    input             clk,
    input             rst_n,

    // Command: start is a one-cycle pulse; done is a one-cycle pulse with the
    // result.
    input             start,
    input      [31:0] input_address,
    input      [31:0] filter_address,
    input      [31:0] byte_length,
    output reg        done,
    output reg [31:0] result,

    // AXI4 read address channel (ARSIZE = 4 bytes, ARBURST = INCR are set by
    // the NPU top level).
    output reg [31:0] m_axi_araddr,
    output reg [ 7:0] m_axi_arlen,
    output reg        m_axi_arvalid,
    input             m_axi_arready,

    // AXI4 read data channel
    input      [31:0] m_axi_rdata,
    input             m_axi_rvalid,
    output            m_axi_rready
);
    localparam integer CHUNK_BYTES  = CHUNK_WORDS * 4;
    localparam integer INDEX_BITS   = $clog2(CHUNK_WORDS);
    // Raw words per segment go up to CHUNK_WORDS + 1; bytes up to CHUNK_BYTES.
    localparam integer COUNT_BITS   = INDEX_BITS + 2;
    localparam integer LENGTH_BITS  = INDEX_BITS + 3;
    localparam [10:0]  MAX_BURST_BEATS_WIDE = MAX_BURST_BEATS;

    // Operands latched at start.
    reg [31:0] input_base_r;
    reg [31:0] filter_base_r;
    reg [31:0] length_r;

    // Bytes in the chunk that starts chunk_offset bytes into vectors of
    // total_length bytes.
    function [LENGTH_BITS-1:0] chunk_length;
        input [31:0] total_length;
        input [31:0] chunk_offset;
        reg   [31:0] remaining;
        begin
            remaining = total_length - chunk_offset;
            if (remaining > CHUNK_BYTES) begin
                chunk_length = CHUNK_BYTES;
            end else begin
                chunk_length = remaining[LENGTH_BITS-1:0];
            end
        end
    endfunction

    // Word-aligned words covering chunk_bytes bytes that start at byte
    // offset byte_offset inside a word.
    function [COUNT_BITS-1:0] covering_words;
        input [1:0]             byte_offset;
        input [LENGTH_BITS-1:0] chunk_bytes;
        reg   [LENGTH_BITS:0]   last_byte;
        begin
            last_byte      = {{(LENGTH_BITS-1){1'b0}}, byte_offset} + chunk_bytes - 1'b1;
            covering_words = last_byte[LENGTH_BITS:2] + 1'b1;
        end
    endfunction

    // Bytes byte_offset .. byte_offset + 3 of the little-endian pair {high, low}.
    function [31:0] realign_word;
        input [31:0] high;
        input [31:0] low;
        input [1:0]  byte_offset;
        begin
            case (byte_offset)
                2'd0:    realign_word = low;
                2'd1:    realign_word = {high[ 7:0], low[31: 8]};
                2'd2:    realign_word = {high[15:0], low[31:16]};
                default: realign_word = {high[23:0], low[31:24]};
            endcase
        end
    endfunction

    // Keep the first valid_lanes (1..4) byte lanes of the last aligned word.
    function [31:0] mask_tail_lanes;
        input [31:0] word;
        input [2:0]  valid_lanes;
        begin
            case (valid_lanes)
                3'd1:    mask_tail_lanes = {24'd0, word[ 7:0]};
                3'd2:    mask_tail_lanes = {16'd0, word[15:0]};
                3'd3:    mask_tail_lanes = { 8'd0, word[23:0]};
                default: mask_tail_lanes = word;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Read-address side: walks chunk -> {input segment, filter segment} ->
    // bursts, one burst request at a time.
    // ------------------------------------------------------------------
    localparam [1:0] AR_IDLE    = 2'd0;
    localparam [1:0] AR_SEGMENT = 2'd1;  // set up the next segment
    localparam [1:0] AR_BURST   = 2'd2;  // size the next burst, raise ARVALID
    localparam [1:0] AR_ADDRESS = 2'd3;  // hold ARVALID until ARREADY

    reg [1:0]            ar_state;
    reg                  ar_filter_segment;
    reg [31:0]           ar_chunk_offset;
    reg [31:0]           ar_word_address;
    reg [COUNT_BITS-1:0] ar_words_left;
    reg [COUNT_BITS-1:0] ar_burst_beats;

    wire [31:0] ar_segment_address =
        (ar_filter_segment ? filter_base_r : input_base_r) + ar_chunk_offset;
    wire [LENGTH_BITS-1:0] ar_chunk_length = chunk_length(length_r, ar_chunk_offset);
    wire [COUNT_BITS-1:0]  ar_segment_words =
        covering_words(ar_segment_address[1:0], ar_chunk_length);

    // Words before the next 4 KB boundary: 1 .. 1024.
    wire [10:0] ar_words_to_boundary =
        11'd1024 - {1'b0, ar_word_address[11:2]};
    wire [10:0] ar_words_left_wide = {{(11-COUNT_BITS){1'b0}}, ar_words_left};
    wire [10:0] ar_beats_limited =
        (ar_words_left_wide < MAX_BURST_BEATS_WIDE) ? ar_words_left_wide
                                                    : MAX_BURST_BEATS_WIDE;
    wire [10:0] ar_next_beats =
        (ar_beats_limited < ar_words_to_boundary) ? ar_beats_limited
                                                  : ar_words_to_boundary;
    wire ar_more_chunks = (ar_chunk_offset + CHUNK_BYTES) < length_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_state          <= AR_IDLE;
            ar_filter_segment <= 1'b0;
            ar_chunk_offset   <= 32'd0;
            ar_word_address   <= 32'd0;
            ar_words_left     <= {COUNT_BITS{1'b0}};
            ar_burst_beats    <= {COUNT_BITS{1'b0}};
            m_axi_araddr      <= 32'd0;
            m_axi_arlen       <= 8'd0;
            m_axi_arvalid     <= 1'b0;
        end else begin
            case (ar_state)
                AR_IDLE: begin
                    if (start && (byte_length != 32'd0)) begin
                        ar_filter_segment <= 1'b0;
                        ar_chunk_offset   <= 32'd0;
                        ar_state          <= AR_SEGMENT;
                    end
                end

                AR_SEGMENT: begin
                    ar_word_address <= {ar_segment_address[31:2], 2'b00};
                    ar_words_left   <= ar_segment_words;
                    ar_state        <= AR_BURST;
                end

                AR_BURST: begin
                    m_axi_araddr   <= ar_word_address;
                    m_axi_arlen    <= ar_next_beats[7:0] - 8'd1;
                    m_axi_arvalid  <= 1'b1;
                    ar_burst_beats <= ar_next_beats[COUNT_BITS-1:0];
                    ar_state       <= AR_ADDRESS;
                end

                AR_ADDRESS: begin
                    if (m_axi_arready) begin
                        m_axi_arvalid   <= 1'b0;
                        ar_word_address <= ar_word_address + {ar_burst_beats, 2'b00};
                        ar_words_left   <= ar_words_left - ar_burst_beats;
                        if (ar_words_left != ar_burst_beats) begin
                            ar_state <= AR_BURST;
                        end else if (!ar_filter_segment) begin
                            ar_filter_segment <= 1'b1;
                            ar_state          <= AR_SEGMENT;
                        end else begin
                            ar_filter_segment <= 1'b0;
                            if (ar_more_chunks) begin
                                ar_chunk_offset <= ar_chunk_offset + CHUNK_BYTES;
                                ar_state        <= AR_SEGMENT;
                            end else begin
                                ar_state <= AR_IDLE;
                            end
                        end
                    end
                end

                default: ar_state <= AR_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Read-data side: follows the same chunk/segment order as the address
    // side (R data returns in request order), realigns every segment, and
    // feeds the multiply pipeline.
    // ------------------------------------------------------------------
    localparam [2:0] R_IDLE    = 3'd0;
    localparam [2:0] R_SEGMENT = 3'd1;  // set up the next segment
    localparam [2:0] R_STREAM  = 3'd2;  // accept the raw words of the segment
    localparam [2:0] R_FLUSH   = 3'd3;  // emit the last realigned word
    localparam [2:0] R_DRAIN   = 3'd4;  // wait for the multiply pipeline

    reg [2:0]            r_state;
    reg                  r_filter_segment;
    reg [31:0]           r_chunk_offset;
    reg [1:0]            r_byte_offset;
    reg [COUNT_BITS-1:0] r_raw_words;
    reg [COUNT_BITS-1:0] r_raw_count;
    reg [COUNT_BITS-1:0] r_aligned_words;
    reg [2:0]            r_tail_lanes;
    reg                  r_flush_needed;
    reg [31:0]           r_previous_word;

    wire [1:0] r_segment_byte_offset =
        r_filter_segment ? filter_base_r[1:0] : input_base_r[1:0];
    wire [LENGTH_BITS-1:0] r_chunk_length = chunk_length(length_r, r_chunk_offset);
    wire [COUNT_BITS-1:0]  r_segment_raw_words =
        covering_words(r_segment_byte_offset, r_chunk_length);
    wire [LENGTH_BITS:0]   r_chunk_length_plus_3 = r_chunk_length + 2'd3;
    wire [COUNT_BITS-1:0]  r_segment_aligned_words =
        r_chunk_length_plus_3[LENGTH_BITS:2];
    wire r_more_chunks = (r_chunk_offset + CHUNK_BYTES) < length_r;

    assign m_axi_rready = (r_state == R_STREAM);
    wire r_beat     = m_axi_rvalid && m_axi_rready;
    wire r_last_raw = (r_raw_count == (r_raw_words - 1'b1));

    // Realigned word produced this cycle (at most one per cycle).
    reg                  emit_valid;
    reg [31:0]           emit_unmasked_word;
    reg [COUNT_BITS-1:0] emit_index;
    always @(*) begin
        emit_valid         = 1'b0;
        emit_unmasked_word = 32'd0;
        emit_index         = {COUNT_BITS{1'b0}};
        if (r_state == R_STREAM && r_beat) begin
            if (r_byte_offset == 2'd0) begin
                emit_valid         = 1'b1;
                emit_unmasked_word = m_axi_rdata;
                emit_index         = r_raw_count;
            end else if (r_raw_count != {COUNT_BITS{1'b0}}) begin
                emit_valid         = 1'b1;
                emit_unmasked_word = realign_word(m_axi_rdata, r_previous_word,
                                                  r_byte_offset);
                emit_index         = r_raw_count - 1'b1;
            end
        end else if (r_state == R_FLUSH) begin
            emit_valid         = 1'b1;
            emit_unmasked_word = realign_word(32'd0, r_previous_word, r_byte_offset);
            emit_index         = r_aligned_words - 1'b1;
        end
    end
    wire emit_is_tail = (emit_index == (r_aligned_words - 1'b1));
    wire [31:0] emit_word = emit_is_tail
                          ? mask_tail_lanes(emit_unmasked_word, r_tail_lanes)
                          : emit_unmasked_word;

    // Multiply pipeline:
    //   s1: realigned word; input words are written to the buffer, filter
    //       words read the buffered input word at the same index
    //   s2: four signed 8x8 products summed
    //   s3: accumulate
    reg                  s1_valid;
    reg                  s1_filter;
    reg [INDEX_BITS-1:0] s1_index;
    reg [31:0]           s1_word;
    reg                  s2_valid;
    reg [31:0]           s2_filter_word;
    reg [31:0]           s2_input_word;
    reg                  s3_valid;
    reg signed [17:0]    s3_lane_sum;
    reg [31:0]           accumulator;

    reg [31:0] input_buffer [0:CHUNK_WORDS-1];
    always @(posedge clk) begin
        if (s1_valid && !s1_filter) begin
            input_buffer[s1_index] <= s1_word;
        end
        s2_input_word <= input_buffer[s1_index];
    end

    wire signed [7:0] input_lane0  = s2_input_word[ 7: 0];
    wire signed [7:0] input_lane1  = s2_input_word[15: 8];
    wire signed [7:0] input_lane2  = s2_input_word[23:16];
    wire signed [7:0] input_lane3  = s2_input_word[31:24];
    wire signed [7:0] filter_lane0 = s2_filter_word[ 7: 0];
    wire signed [7:0] filter_lane1 = s2_filter_word[15: 8];
    wire signed [7:0] filter_lane2 = s2_filter_word[23:16];
    wire signed [7:0] filter_lane3 = s2_filter_word[31:24];
    wire signed [15:0] lane_product0 = input_lane0 * filter_lane0;
    wire signed [15:0] lane_product1 = input_lane1 * filter_lane1;
    wire signed [15:0] lane_product2 = input_lane2 * filter_lane2;
    wire signed [15:0] lane_product3 = input_lane3 * filter_lane3;
    wire signed [17:0] lane_sum = lane_product0 + lane_product1 +
                                  lane_product2 + lane_product3;

    wire pipeline_empty = !s1_valid && !s2_valid && !s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done             <= 1'b0;
            result           <= 32'd0;
            input_base_r     <= 32'd0;
            filter_base_r    <= 32'd0;
            length_r         <= 32'd0;
            r_state          <= R_IDLE;
            r_filter_segment <= 1'b0;
            r_chunk_offset   <= 32'd0;
            r_byte_offset    <= 2'd0;
            r_raw_words      <= {COUNT_BITS{1'b0}};
            r_raw_count      <= {COUNT_BITS{1'b0}};
            r_aligned_words  <= {COUNT_BITS{1'b0}};
            r_tail_lanes     <= 3'd4;
            r_flush_needed   <= 1'b0;
            r_previous_word  <= 32'd0;
            s1_valid         <= 1'b0;
            s1_filter        <= 1'b0;
            s1_index         <= {INDEX_BITS{1'b0}};
            s1_word          <= 32'd0;
            s2_valid         <= 1'b0;
            s2_filter_word   <= 32'd0;
            s3_valid         <= 1'b0;
            s3_lane_sum      <= 18'sd0;
            accumulator      <= 32'd0;
        end else begin
            done <= 1'b0;

            s1_valid       <= emit_valid;
            s1_filter      <= r_filter_segment;
            s1_index       <= emit_index[INDEX_BITS-1:0];
            s1_word        <= emit_word;
            s2_valid       <= s1_valid && s1_filter;
            s2_filter_word <= s1_word;
            s3_valid       <= s2_valid;
            s3_lane_sum    <= lane_sum;
            if (s3_valid) begin
                accumulator <= accumulator + {{14{s3_lane_sum[17]}}, s3_lane_sum};
            end

            case (r_state)
                R_IDLE: begin
                    if (start) begin
                        input_base_r     <= input_address;
                        filter_base_r    <= filter_address;
                        length_r         <= byte_length;
                        accumulator      <= 32'd0;
                        r_filter_segment <= 1'b0;
                        r_chunk_offset   <= 32'd0;
                        r_state <= (byte_length == 32'd0) ? R_DRAIN : R_SEGMENT;
                    end
                end

                R_SEGMENT: begin
                    r_byte_offset   <= r_segment_byte_offset;
                    r_raw_words     <= r_segment_raw_words;
                    r_aligned_words <= r_segment_aligned_words;
                    r_tail_lanes    <= (r_chunk_length[1:0] == 2'd0)
                                       ? 3'd4 : {1'b0, r_chunk_length[1:0]};
                    r_flush_needed  <= (r_segment_byte_offset != 2'd0) &&
                                       (r_segment_raw_words == r_segment_aligned_words);
                    r_raw_count     <= {COUNT_BITS{1'b0}};
                    r_state         <= R_STREAM;
                end

                R_STREAM: begin
                    if (r_beat) begin
                        r_previous_word <= m_axi_rdata;
                        r_raw_count     <= r_raw_count + 1'b1;
                        if (r_last_raw) begin
                            if (r_flush_needed) begin
                                r_state <= R_FLUSH;
                            end else if (!r_filter_segment) begin
                                r_filter_segment <= 1'b1;
                                r_state          <= R_SEGMENT;
                            end else if (r_more_chunks) begin
                                r_filter_segment <= 1'b0;
                                r_chunk_offset   <= r_chunk_offset + CHUNK_BYTES;
                                r_state          <= R_SEGMENT;
                            end else begin
                                r_state <= R_DRAIN;
                            end
                        end
                    end
                end

                R_FLUSH: begin
                    if (!r_filter_segment) begin
                        r_filter_segment <= 1'b1;
                        r_state          <= R_SEGMENT;
                    end else if (r_more_chunks) begin
                        r_filter_segment <= 1'b0;
                        r_chunk_offset   <= r_chunk_offset + CHUNK_BYTES;
                        r_state          <= R_SEGMENT;
                    end else begin
                        r_state <= R_DRAIN;
                    end
                end

                R_DRAIN: begin
                    if (pipeline_empty) begin
                        result  <= accumulator;
                        done    <= 1'b1;
                        r_state <= R_IDLE;
                    end
                end

                default: r_state <= R_IDLE;
            endcase
        end
    end
endmodule
