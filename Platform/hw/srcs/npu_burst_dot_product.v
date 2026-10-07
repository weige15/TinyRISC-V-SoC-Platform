`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// npu_burst_dot_product
//
// Signed int8 dot product with an input offset over two byte vectors in
// memory, fetched only with AXI4 INCR read bursts:
//
//   result = sum_{i < byte_length} (int8(input[i]) + int8(input_offset))
//                                  * int8(filter[i])
//
// The sum wraps modulo 2^32 (exact for the Lab 2 domain N <= 256).
//
// Data flow
//   The vectors are processed in chunks of up to CHUNK_WORDS words. For every
//   chunk the input segment is fetched first and stored in a local buffer,
//   then the filter segment is streamed and multiplied with the buffered
//   input word at the same position (4 int8 lanes per beat).
//
// Unaligned addresses / partial words
//   Every segment fetches the word-aligned span covering it. A funnel shifter
//   realigns the byte stream so vector byte j sits in lane j % 4 of aligned
//   word j / 4. Lanes past the end of the vector are zeroed (filter lane = 0
//   makes the product 0 even with a non-zero input offset).
//
// Bursts
//   ARSIZE = 4 bytes, ARBURST = INCR (driven by the NPU top level). A burst
//   never crosses a 4 KiB boundary: its length is the minimum of the words
//   left in the segment, MAX_BURST_BEATS and the words left before the next
//   4 KiB boundary. One burst is outstanding at a time; the next address is
//   issued only after the previous burst completed with RLAST.
//
// Error handling (status bits are cleared by every start)
//   status[0] early RLAST      : RLAST before beat B. The command finishes.
//   status[1] missing RLAST    : beat B without RLAST. Local storage is no
//                                longer written, later beats are accepted
//                                and discarded until RLAST, then the command
//                                finishes.
//   status[2] non-OKAY RRESP   : the beat is not used, the rest of the burst
//                                is consumed (not stored), then the command
//                                finishes.
//   done pulses exactly once per start in every case.
//////////////////////////////////////////////////////////////////////////////////
module npu_burst_dot_product #(
    parameter integer MAX_BURST_BEATS = 256,  // AXI4 INCR limit (ARLEN = 255)
    parameter integer CHUNK_WORDS     = 256   // buffered input words per chunk
) (
    input             clk,
    input             rst_n,

    // Command: start is a one-cycle pulse; done is a one-cycle pulse with the
    // result and status.
    input             start,
    input      [31:0] input_address,
    input      [31:0] filter_address,
    input      [31:0] byte_length,
    input      [ 7:0] input_offset,
    output reg        done,
    output reg [31:0] result,
    output reg [ 2:0] status,

    // AXI4 read address channel
    output reg [31:0] m_axi_araddr,
    output reg [ 7:0] m_axi_arlen,
    output reg        m_axi_arvalid,
    input             m_axi_arready,

    // AXI4 read data channel
    input      [31:0] m_axi_rdata,
    input      [ 1:0] m_axi_rresp,
    input             m_axi_rlast,
    input             m_axi_rvalid,
    output            m_axi_rready
);
    localparam integer INDEX_BITS  = $clog2(CHUNK_WORDS);
    // Raw words per segment go up to CHUNK_WORDS + 1; bytes up to CHUNK_BYTES.
    localparam integer COUNT_BITS  = INDEX_BITS + 2;
    localparam integer LENGTH_BITS = INDEX_BITS + 3;
    /* verilator lint_off WIDTHTRUNC */
    localparam [LENGTH_BITS-1:0] CHUNK_BYTES          = CHUNK_WORDS * 4;
    localparam [10:0]            MAX_BURST_BEATS_WIDE = MAX_BURST_BEATS;
    /* verilator lint_on WIDTHTRUNC */
    localparam [31:0] CHUNK_BYTES_WIDE = {{(32-LENGTH_BITS){1'b0}}, CHUNK_BYTES};
    localparam [COUNT_BITS-1:0] COUNT_ONE  = {{(COUNT_BITS-1){1'b0}}, 1'b1};
    localparam [COUNT_BITS-1:0] COUNT_ZERO = {COUNT_BITS{1'b0}};

    // Operands latched at start.
    reg [31:0] input_base_r;
    reg [31:0] filter_base_r;
    reg [31:0] length_r;
    reg [ 7:0] offset_r;

    // Bytes in the chunk that starts chunk_offset bytes into the vectors.
    function [LENGTH_BITS-1:0] chunk_length;
        input [31:0] total_length;
        input [31:0] chunk_offset;
        reg   [31:0] remaining;
        begin
            remaining = total_length - chunk_offset;
            if (remaining > CHUNK_BYTES_WIDE) begin
                chunk_length = CHUNK_BYTES;
            end else begin
                chunk_length = remaining[LENGTH_BITS-1:0];
            end
        end
    endfunction

    /* verilator lint_off UNUSEDSIGNAL */
    // Word-aligned words covering chunk_bytes bytes that start at byte
    // offset byte_offset inside a word.
    function [COUNT_BITS-1:0] covering_words;
        input [1:0]             byte_offset;
        input [LENGTH_BITS-1:0] chunk_bytes;
        reg   [LENGTH_BITS:0]   last_byte;
        begin
            last_byte      = {{(LENGTH_BITS-1){1'b0}}, byte_offset} +
                             {1'b0, chunk_bytes} - {{LENGTH_BITS{1'b0}}, 1'b1};
            covering_words = last_byte[LENGTH_BITS:2] + COUNT_ONE;
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
    /* verilator lint_on UNUSEDSIGNAL */

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

    // R-side events used by the address side (defined below).
    wire r_burst_complete;  // last beat of a burst accepted, RLAST, no error
    wire r_abort;           // command ends early because of an error

    // ------------------------------------------------------------------
    // Read-address side: chunk -> {input segment, filter segment} -> bursts,
    // one outstanding burst at a time.
    // ------------------------------------------------------------------
    localparam [2:0] AR_IDLE    = 3'd0;
    localparam [2:0] AR_SEGMENT = 3'd1;  // set up the next segment
    localparam [2:0] AR_BURST   = 3'd2;  // size the next burst, raise ARVALID
    localparam [2:0] AR_ADDRESS = 3'd3;  // hold ARVALID until ARREADY
    localparam [2:0] AR_WAIT    = 3'd4;  // wait for the burst's data

    reg [2:0]            ar_state;
    reg                  ar_filter_segment;
    reg [31:0]           ar_chunk_offset;
    reg [31:0]           ar_word_address;
    reg [COUNT_BITS-1:0] ar_words_left;
    reg [COUNT_BITS-1:0] ar_burst_beats;   // B of the outstanding burst

    wire [31:0] ar_segment_address =
        (ar_filter_segment ? filter_base_r : input_base_r) + ar_chunk_offset;
    wire [LENGTH_BITS-1:0] ar_chunk_length = chunk_length(length_r, ar_chunk_offset);
    wire [COUNT_BITS-1:0]  ar_segment_words =
        covering_words(ar_segment_address[1:0], ar_chunk_length);

    // Words before the next 4 KiB boundary: 1 .. 1024.
    wire [10:0] ar_words_to_boundary =
        11'd1024 - {1'b0, ar_word_address[11:2]};
    wire [10:0] ar_words_left_wide = {{(11-COUNT_BITS){1'b0}}, ar_words_left};
    wire [10:0] ar_beats_limited =
        (ar_words_left_wide < MAX_BURST_BEATS_WIDE) ? ar_words_left_wide
                                                    : MAX_BURST_BEATS_WIDE;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [10:0] ar_next_beats =
        (ar_beats_limited < ar_words_to_boundary) ? ar_beats_limited
                                                  : ar_words_to_boundary;
    /* verilator lint_on UNUSEDSIGNAL */
    wire ar_more_chunks = (ar_chunk_offset + CHUNK_BYTES_WIDE) < length_r;
    wire [31:0] ar_burst_bytes =
        {{(30-COUNT_BITS){1'b0}}, ar_burst_beats, 2'b00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_state          <= AR_IDLE;
            ar_filter_segment <= 1'b0;
            ar_chunk_offset   <= 32'd0;
            ar_word_address   <= 32'd0;
            ar_words_left     <= COUNT_ZERO;
            ar_burst_beats    <= COUNT_ZERO;
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
                    // ARVALID, ARADDR and ARLEN stay stable until ARREADY.
                    if (m_axi_arready) begin
                        m_axi_arvalid   <= 1'b0;
                        ar_word_address <= ar_word_address + ar_burst_bytes;
                        ar_words_left   <= ar_words_left - ar_burst_beats;
                        ar_state        <= AR_WAIT;
                    end
                end

                AR_WAIT: begin
                    if (r_abort) begin
                        ar_filter_segment <= 1'b0;
                        ar_state          <= AR_IDLE;
                    end else if (r_burst_complete) begin
                        if (ar_words_left != COUNT_ZERO) begin
                            ar_state <= AR_BURST;
                        end else if (!ar_filter_segment) begin
                            ar_filter_segment <= 1'b1;
                            ar_state          <= AR_SEGMENT;
                        end else begin
                            ar_filter_segment <= 1'b0;
                            if (ar_more_chunks) begin
                                ar_chunk_offset <= ar_chunk_offset + CHUNK_BYTES_WIDE;
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
    // Read-data side
    // ------------------------------------------------------------------
    localparam [2:0] R_IDLE    = 3'd0;
    localparam [2:0] R_SEGMENT = 3'd1;  // set up the next segment
    localparam [2:0] R_STREAM  = 3'd2;  // accept the raw words of the segment
    localparam [2:0] R_FLUSH   = 3'd3;  // emit the last realigned word
    localparam [2:0] R_DRAIN   = 3'd4;  // wait for the multiply pipeline
    localparam [2:0] R_DISCARD = 3'd5;  // missing RLAST: discard until RLAST

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
    reg [COUNT_BITS-1:0] r_burst_count;   // beats accepted in this burst

    wire [1:0] r_segment_byte_offset =
        r_filter_segment ? filter_base_r[1:0] : input_base_r[1:0];
    wire [LENGTH_BITS-1:0] r_chunk_length = chunk_length(length_r, r_chunk_offset);
    wire [COUNT_BITS-1:0]  r_segment_raw_words =
        covering_words(r_segment_byte_offset, r_chunk_length);
    /* verilator lint_off UNUSEDSIGNAL */
    wire [LENGTH_BITS:0]   r_chunk_length_plus_3 =
        {1'b0, r_chunk_length} + {{(LENGTH_BITS-1){1'b0}}, 2'd3};
    wire [COUNT_BITS-1:0]  r_segment_aligned_words =
        r_chunk_length_plus_3[LENGTH_BITS:2];
    /* verilator lint_on UNUSEDSIGNAL */
    wire r_more_chunks = (r_chunk_offset + CHUNK_BYTES_WIDE) < length_r;

    assign m_axi_rready = (r_state == R_STREAM) || (r_state == R_DISCARD);
    wire r_beat     = m_axi_rvalid && m_axi_rready;
    wire r_last_raw = (r_raw_count == (r_raw_words - COUNT_ONE));

    // Burst-level protocol checks for the beat on the bus.
    wire r_last_expected = (r_burst_count == (ar_burst_beats - COUNT_ONE));
    wire r_resp_bad      = (m_axi_rresp != 2'b00);
    wire r_early_last    = m_axi_rlast && !r_last_expected;
    wire r_missing_last  = r_last_expected && !m_axi_rlast;
    wire r_burst_end     = r_last_expected && m_axi_rlast;
    wire r_resp_failed   = r_resp_bad || status[2];
    wire r_stream_beat   = (r_state == R_STREAM) && r_beat;

    assign r_burst_complete = r_stream_beat && r_burst_end && !r_resp_failed;
    assign r_abort =
        (r_stream_beat && (r_early_last || (r_burst_end && r_resp_failed))) ||
        ((r_state == R_DISCARD) && r_beat && m_axi_rlast);

    // A beat may be written to local storage only if it is in range and OK.
    wire r_beat_usable = r_stream_beat && !r_resp_failed && !r_early_last;

    // Realigned word produced this cycle (at most one per cycle). emit_valid
    // is the local-storage / pipeline write enable.
    reg                  emit_valid;
    reg [31:0]           emit_unmasked_word;
    reg [COUNT_BITS-1:0] emit_index;
    always @(*) begin
        emit_valid         = 1'b0;
        emit_unmasked_word = 32'd0;
        emit_index         = COUNT_ZERO;
        if (r_beat_usable) begin
            if (r_byte_offset == 2'd0) begin
                emit_valid         = 1'b1;
                emit_unmasked_word = m_axi_rdata;
                emit_index         = r_raw_count;
            end else if (r_raw_count != COUNT_ZERO) begin
                emit_valid         = 1'b1;
                emit_unmasked_word = realign_word(m_axi_rdata, r_previous_word,
                                                  r_byte_offset);
                emit_index         = r_raw_count - COUNT_ONE;
            end
        end else if (r_state == R_FLUSH) begin
            emit_valid         = 1'b1;
            emit_unmasked_word = realign_word(32'd0, r_previous_word, r_byte_offset);
            emit_index         = r_aligned_words - COUNT_ONE;
        end
    end
    wire emit_is_tail = (emit_index == (r_aligned_words - COUNT_ONE));
    wire [31:0] emit_word = emit_is_tail
                          ? mask_tail_lanes(emit_unmasked_word, r_tail_lanes)
                          : emit_unmasked_word;

    // Multiply pipeline:
    //   s1: realigned word; input words are written to the buffer, filter
    //       words read the buffered input word at the same index
    //   s2: four (input + offset) * filter products summed
    //   s3: accumulate
    reg                  s1_valid;
    reg                  s1_filter;
    reg [INDEX_BITS-1:0] s1_index;
    reg [31:0]           s1_word;
    reg                  s2_valid;
    reg [31:0]           s2_filter_word;
    reg [31:0]           s2_input_word;
    reg                  s3_valid;
    reg [18:0]           s3_lane_sum;
    reg [31:0]           accumulator;

    reg [31:0] input_buffer [0:CHUNK_WORDS-1];
    always @(posedge clk) begin
        if (s1_valid && !s1_filter) begin
            input_buffer[s1_index] <= s1_word;
        end
        s2_input_word <= input_buffer[s1_index];
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // (int8 a + int8 offset) fits in 9 signed bits; times int8 b fits in 17.
    function [16:0] offset_product;
        input [7:0] a;
        input [7:0] offset;
        input [7:0] b;
        reg signed [8:0]  a_plus_offset;
        reg signed [8:0]  b_wide;
        reg signed [17:0] product;
        begin
            a_plus_offset  = $signed({a[7], a}) + $signed({offset[7], offset});
            b_wide         = $signed({b[7], b});
            product        = a_plus_offset * b_wide;
            offset_product = product[16:0];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    wire [16:0] lane_product0 = offset_product(s2_input_word[ 7: 0], offset_r, s2_filter_word[ 7: 0]);
    wire [16:0] lane_product1 = offset_product(s2_input_word[15: 8], offset_r, s2_filter_word[15: 8]);
    wire [16:0] lane_product2 = offset_product(s2_input_word[23:16], offset_r, s2_filter_word[23:16]);
    wire [16:0] lane_product3 = offset_product(s2_input_word[31:24], offset_r, s2_filter_word[31:24]);
    wire [18:0] lane_sum = {{2{lane_product0[16]}}, lane_product0} +
                           {{2{lane_product1[16]}}, lane_product1} +
                           {{2{lane_product2[16]}}, lane_product2} +
                           {{2{lane_product3[16]}}, lane_product3};

    wire pipeline_empty = !s1_valid && !s2_valid && !s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done             <= 1'b0;
            result           <= 32'd0;
            status           <= 3'd0;
            input_base_r     <= 32'd0;
            filter_base_r    <= 32'd0;
            length_r         <= 32'd0;
            offset_r         <= 8'd0;
            r_state          <= R_IDLE;
            r_filter_segment <= 1'b0;
            r_chunk_offset   <= 32'd0;
            r_byte_offset    <= 2'd0;
            r_raw_words      <= COUNT_ZERO;
            r_raw_count      <= COUNT_ZERO;
            r_aligned_words  <= COUNT_ZERO;
            r_tail_lanes     <= 3'd4;
            r_flush_needed   <= 1'b0;
            r_previous_word  <= 32'd0;
            r_burst_count    <= COUNT_ZERO;
            s1_valid         <= 1'b0;
            s1_filter        <= 1'b0;
            s1_index         <= {INDEX_BITS{1'b0}};
            s1_word          <= 32'd0;
            s2_valid         <= 1'b0;
            s2_filter_word   <= 32'd0;
            s3_valid         <= 1'b0;
            s3_lane_sum      <= 19'd0;
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
                accumulator <= accumulator + {{13{s3_lane_sum[18]}}, s3_lane_sum};
            end

            case (r_state)
                R_IDLE: begin
                    if (start) begin
                        input_base_r     <= input_address;
                        filter_base_r    <= filter_address;
                        length_r         <= byte_length;
                        offset_r         <= input_offset;
                        status           <= 3'd0;
                        accumulator      <= 32'd0;
                        r_filter_segment <= 1'b0;
                        r_chunk_offset   <= 32'd0;
                        r_burst_count    <= COUNT_ZERO;
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
                    r_raw_count     <= COUNT_ZERO;
                    r_state         <= R_STREAM;
                end

                R_STREAM: begin
                    if (r_beat) begin
                        r_previous_word <= m_axi_rdata;
                        r_raw_count     <= r_raw_count + COUNT_ONE;
                        r_burst_count   <= r_last_expected ? COUNT_ZERO
                                                           : r_burst_count + COUNT_ONE;
                        if (r_resp_bad) begin
                            status[2] <= 1'b1;
                        end
                        if (r_early_last) begin
                            status[0] <= 1'b1;
                            r_state   <= R_DRAIN;
                        end else if (r_missing_last) begin
                            status[1] <= 1'b1;
                            r_state   <= R_DISCARD;
                        end else if (r_resp_failed) begin
                            // Keep consuming (not storing) until the end of
                            // the burst, then finish.
                            if (r_burst_end) begin
                                r_state <= R_DRAIN;
                            end
                        end else if (r_last_raw) begin
                            if (r_flush_needed) begin
                                r_state <= R_FLUSH;
                            end else if (!r_filter_segment) begin
                                r_filter_segment <= 1'b1;
                                r_state          <= R_SEGMENT;
                            end else if (r_more_chunks) begin
                                r_filter_segment <= 1'b0;
                                r_chunk_offset   <= r_chunk_offset + CHUNK_BYTES_WIDE;
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
                        r_chunk_offset   <= r_chunk_offset + CHUNK_BYTES_WIDE;
                        r_state          <= R_SEGMENT;
                    end else begin
                        r_state <= R_DRAIN;
                    end
                end

                R_DISCARD: begin
                    if (r_beat) begin
                        if (r_resp_bad) begin
                            status[2] <= 1'b1;
                        end
                        if (m_axi_rlast) begin
                            r_state <= R_DRAIN;
                        end
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
