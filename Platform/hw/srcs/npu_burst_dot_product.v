`timescale 1ns / 1ps
// Beat-rate signed byte dot product. Two in-order AXI bursts may be outstanding.
// Each operand has an independent cursor: bursts end ONLY at 256 beats, 4 KiB,
// or the operand's end (never at an artificial buffer/chunk boundary).
// Input raw words live in a circular distributed RAM. Filter bus lanes select
// the corresponding input bytes directly, including unequal byte alignments.
// Thus no realignment flush or per-word staging is needed: every usable filter
// beat enters the MAC on its handshake, and the last sum retires one cycle later.
//
// On an error, stop scheduling, but do not cancel a stalled ARVALID. Drain ALL
// accepted requests (including that held request) through their actual RLASTs.
// status: bit0 early RLAST, bit1 missing RLAST, bit2 non-OKAY RRESP.
//
// ptr1 operand reuse: while reuse_enable is high, the raw input words of the
// last successful COMPUTE stay valid in input_buffer when that vector fit the
// RAM (no ring wrap). A COMPUTE with the same input_address and byte_length
// then skips the ptr1 bursts and fetches only ptr2. The RAM is written only
// from accepted, error-free R beats, so reused bytes always come from earlier
// AXI bursts. reuse_clear (arm/disarm or an NPU AXI write) and any miss,
// error or call while disabled invalidate the copy.
module npu_burst_dot_product #(
    parameter integer MAX_BURST_BEATS = 256,
    parameter integer CHUNK_WORDS = 256 // retained parameter; RAM = 4x this size
) (
    input clk, input rst_n, input start,
    input [31:0] input_address, filter_address, byte_length,
    input [7:0] input_offset,
    input reuse_enable, input reuse_clear,
    output reg done,
    output reg [31:0] result,
    output reg [2:0] status,
    output reg [31:0] m_axi_araddr,
    output reg [7:0] m_axi_arlen,
    output reg m_axi_arvalid,
    input m_axi_arready,
    input [31:0] m_axi_rdata,
    input [1:0] m_axi_rresp,
    input m_axi_rlast, m_axi_rvalid,
    output m_axi_rready
);
    localparam integer BUFFER_WORDS = 4 * CHUNK_WORDS;
    localparam integer IB = $clog2(BUFFER_WORDS);
    // synthesis translate_off
    initial begin
        if (MAX_BURST_BEATS < 1 || MAX_BURST_BEATS > 256 ||
            BUFFER_WORDS < 2*MAX_BURST_BEATS+2 ||
            (BUFFER_WORDS & (BUFFER_WORDS-1)) != 0)
            $fatal(1,"invalid burst limit or circular RAM size");
    end
    // synthesis translate_on
    reg active;
    reg [7:0] offset_r;
    reg [1:0] input_low, filter_low;
    reg [31:0] length_r;
    reg [31:0] input_next, filter_next;
    reg [30:0] input_left, filter_left;
    reg [30:0] input_issued, filter_issued;
    reg [30:0] input_received, filter_received;
    reg ar_filter;
    reg reuse_valid;
    reg [31:0] reuse_address, reuse_length;
    wire reuse_hit = reuse_enable && reuse_valid &&
                     (input_address == reuse_address) &&
                     (byte_length == reuse_length);

    /* verilator lint_off UNUSEDSIGNAL */
    function [30:0] covering_words;
        input [31:0] n;
        input [1:0] low;
        reg [32:0] span;
        begin
            span = {1'b0,n} + {31'd0,low} + 33'd3;
            covering_words = span[32:2];
        end
    endfunction
    function [8:0] burst_size;
        input [31:0] addr;
        input [30:0] left;
        reg [10:0] boundary;
        reg [30:0] beats;
        begin
            boundary = 11'd1024 - {1'b0,addr[11:2]};
            beats = left;
            if (beats > MAX_BURST_BEATS[30:0]) beats = MAX_BURST_BEATS[30:0];
            if (beats > {20'd0,boundary}) beats = {20'd0,boundary};
            burst_size = beats[8:0];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    wire [8:0] input_beats = burst_size(input_next, input_left);
    wire [8:0] filter_beats = burst_size(filter_next, filter_left);
    // Work in words, not bytes, on the scheduling critical path. Before the
    // final burst, ceil((4*F - filter_low + input_low)/4) is exactly F plus
    // (input_low > filter_low). The final burst instead requires all input
    // requests to have been scheduled, because its unused tail is masked.
    // This avoids a byte subtract, length clamp and byte-to-word carry chain.
    wire [9:0] needed_increment = {1'b0,filter_beats} +
                                  {9'd0,(input_low > filter_low)};
    wire [30:0] needed_words = filter_issued + {21'd0,needed_increment};
    wire final_filter_burst = (filter_left == {22'd0,filter_beats});
    wire choose_filter = (filter_left != 0) &&
                         (final_filter_burst ? (input_left == 0) :
                                               (input_issued >= needed_words));
    // Conservative credit: retain the preceding input word for a cross-word
    // lane selection. Credits change on R, not AR, so queued filters are safe.
    wire [30:0] freed_words = (filter_received > 1) ? filter_received - 1 : 0;
    wire input_room = ({1'b0,input_issued} - {1'b0,freed_words} +
                       {23'd0,input_beats} <= BUFFER_WORDS);
    wire can_schedule = choose_filter || ((input_left != 0) && input_room);
    wire [30:0] input_cover = covering_words(byte_length,input_address[1:0]);
    wire [30:0] filter_cover = covering_words(byte_length,filter_address[1:0]);
    wire [8:0] first_beats = burst_size({input_address[31:2],2'b00}, input_cover);

    // Two-entry descriptor FIFO. The AXI ID is fixed, so responses are ordered.
    reg [8:0] q_beats [0:1];
    reg q_filter [0:1];
    reg q_head, q_tail;
    reg [1:0] q_count;
    reg [8:0] beat_index;
    reg discard; // missing RLAST: never use additional beats
    wire ar_fire = m_axi_arvalid && m_axi_arready;
    // Descriptor contents, like operand RAM, need no reset: q_count is the
    // validity mask. Keep these writes outside the async-reset control block
    // so synthesis does not infer ambiguous set/reset behavior for the array.
    always @(posedge clk) begin
        if (ar_fire) begin
            q_beats[q_tail] <= {1'b0,m_axi_arlen} + 1'b1;
            q_filter[q_tail] <= ar_filter;
        end
    end
    assign m_axi_rready = active && (q_count != 0);
    wire r_fire = m_axi_rvalid && m_axi_rready;
    wire pop = r_fire && m_axi_rlast;
    wire expected_last = (beat_index == q_beats[q_head] - 1'b1);
    wire early_last = r_fire && !discard && m_axi_rlast && !expected_last;
    wire missing_last = r_fire && !discard && !m_axi_rlast && expected_last;
    wire bad_resp = r_fire && (m_axi_rresp != 0);
    wire error_now = early_last || missing_last || bad_resp;
    wire failed = (status != 0) || error_now;
    wire [2:0] count_after = {1'b0,q_count} + {2'd0,ar_fire} - {2'd0,pop};
    wire is_filter = q_filter[q_head];
    // Exposed for simulation's no-write-after-error assertion.
    wire emit_valid = r_fire && !discard && !failed;

    // Raw input words, two asynchronous read ports, single synchronous write.
    // The arithmetic index is filter_received + floor((input_low-filter_low)/4).
    // The first word can refer to -1; those leading filter lanes are disabled.
    (* ram_style = "distributed" *) reg [31:0] input_buffer [0:BUFFER_WORDS-1];
    wire borrow_word = (input_low < filter_low);
    wire [1:0] shift_bytes = input_low - filter_low;
    wire [IB-1:0] read_index = filter_received[IB-1:0] - {{(IB-1){1'b0}},borrow_word};
    wire [IB-1:0] read_index_hi = read_index + 1'b1;
    wire [63:0] input_pair = {input_buffer[read_index_hi],input_buffer[read_index]};
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] shifted_pair = input_pair >> {shift_bytes,3'b000};
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] input_word = shifted_pair[31:0];
    always @(posedge clk) begin
        if (emit_valid && !is_filter)
            input_buffer[input_received[IB-1:0]] <= m_axi_rdata;
    end

    wire [32:0] filter_position = {filter_received,2'b00};
    wire [32:0] filter_limit = {1'b0,length_r} + {31'd0,filter_low};
    wire [3:0] lane_valid;
    genvar lane;
    generate for (lane=0; lane<4; lane=lane+1) begin: lanes
        assign lane_valid[lane] = (filter_position + lane >= {31'd0,filter_low}) &&
                                 (filter_position + lane < filter_limit);
    end endgenerate
    function [16:0] product;
        input [7:0] a, b, off;
        input valid;
        reg signed [8:0] x;
        reg signed [16:0] p;
        begin
            x = $signed({a[7],a}) + $signed({off[7],off});
            p = x * $signed(b);
            product = valid ? p : 17'd0;
        end
    endfunction
    wire [16:0] p0 = product(input_word[7:0],m_axi_rdata[7:0],offset_r,lane_valid[0]);
    wire [16:0] p1 = product(input_word[15:8],m_axi_rdata[15:8],offset_r,lane_valid[1]);
    wire [16:0] p2 = product(input_word[23:16],m_axi_rdata[23:16],offset_r,lane_valid[2]);
    wire [16:0] p3 = product(input_word[31:24],m_axi_rdata[31:24],offset_r,lane_valid[3]);
    wire [18:0] lane_sum = {{2{p0[16]}},p0} + {{2{p1[16]}},p1} +
                           {{2{p2[16]}},p2} + {{2{p3[16]}},p3};
    reg mac_valid;
    reg [18:0] mac_sum;
    reg [31:0] accumulator;
    wire [31:0] accumulated = accumulator + (mac_valid ? {{13{mac_sum[18]}},mac_sum} : 32'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; done <= 0; result <= 0; status <= 0;
            offset_r <= 0; input_low <= 0; filter_low <= 0; length_r <= 0;
            input_next <= 0; filter_next <= 0; input_left <= 0; filter_left <= 0;
            input_issued <= 0; filter_issued <= 0;
            input_received <= 0; filter_received <= 0;
            m_axi_arvalid <= 0; m_axi_araddr <= 0; m_axi_arlen <= 0; ar_filter <= 0;
            q_head <= 0; q_tail <= 0; q_count <= 0; beat_index <= 0; discard <= 0;
            mac_valid <= 0; mac_sum <= 0; accumulator <= 0;
            reuse_valid <= 0; reuse_address <= 0; reuse_length <= 0;
        end else begin
            done <= 0;
            mac_valid <= emit_valid && is_filter;
            mac_sum <= lane_sum;
            accumulator <= accumulated;
            if (reuse_clear) reuse_valid <= 0;
            if (start && !active && reuse_hit) begin
                // All ptr1 words are already in input_buffer[0..]. Only ptr2
                // is fetched; the scheduler issues its first AR next cycle.
                active <= 1; status <= 0; accumulator <= 0; mac_valid <= 0;
                offset_r <= input_offset;
                input_low <= input_address[1:0]; filter_low <= filter_address[1:0];
                length_r <= byte_length;
                filter_next <= {filter_address[31:2],2'b00};
                input_left <= 0;
                filter_left <= filter_cover;
                input_issued <= input_cover;
                input_received <= input_cover;
                filter_issued <= 0; filter_received <= 0;
                m_axi_arvalid <= 0;
                q_head <= 0; q_tail <= 0; q_count <= 0; beat_index <= 0; discard <= 0;
            end else if (start && !active) begin
                // A miss overwrites the RAM: invalidate, record the new key.
                reuse_valid <= 0;
                reuse_address <= input_address; reuse_length <= byte_length;
                active <= 1; status <= 0; accumulator <= 0; mac_valid <= 0;
                offset_r <= input_offset;
                input_low <= input_address[1:0]; filter_low <= filter_address[1:0];
                length_r <= byte_length;
                input_next <= {input_address[31:2],2'b00} + {21'd0,first_beats,2'b00};
                filter_next <= {filter_address[31:2],2'b00};
                input_left <= (byte_length == 0) ? 0 : input_cover - {22'd0,first_beats};
                filter_left <= (byte_length == 0) ? 0 : filter_cover;
                input_issued <= (byte_length == 0) ? 0 : {22'd0,first_beats};
                filter_issued <= 0; input_received <= 0; filter_received <= 0;
                m_axi_araddr <= {input_address[31:2],2'b00};
                m_axi_arlen <= first_beats[7:0] - 1'b1;
                m_axi_arvalid <= (byte_length != 0); ar_filter <= 0;
                q_head <= 0; q_tail <= 0; q_count <= 0; beat_index <= 0; discard <= 0;
            end else if (active) begin
                q_count <= count_after[1:0];
                if (ar_fire) begin
                    q_tail <= ~q_tail;
                    m_axi_arvalid <= 0;
                end
                // A held request is immutable even after a response error.
                if ((!m_axi_arvalid || ar_fire) && (count_after < 2) &&
                    !failed && can_schedule) begin
                    m_axi_arvalid <= 1;
                    ar_filter <= choose_filter;
                    if (choose_filter) begin
                        m_axi_araddr <= filter_next;
                        m_axi_arlen <= filter_beats[7:0] - 1'b1;
                        filter_next <= filter_next + {21'd0,filter_beats,2'b00};
                        filter_left <= filter_left - {22'd0,filter_beats};
                        filter_issued <= filter_issued + {22'd0,filter_beats};
                    end else begin
                        m_axi_araddr <= input_next;
                        m_axi_arlen <= input_beats[7:0] - 1'b1;
                        input_next <= input_next + {21'd0,input_beats,2'b00};
                        input_left <= input_left - {22'd0,input_beats};
                        input_issued <= input_issued + {22'd0,input_beats};
                    end
                end
                if (r_fire) begin
                    if (early_last) status[0] <= 1;
                    if (missing_last) begin status[1] <= 1; discard <= 1; end
                    if (bad_resp) status[2] <= 1;
                    if (pop) begin
                        q_head <= ~q_head; beat_index <= 0; discard <= 0;
                    end else if (!discard) beat_index <= beat_index + 1'b1;
                    if (emit_valid) begin
                        if (is_filter) filter_received <= filter_received + 1'b1;
                        else input_received <= input_received + 1'b1;
                    end
                end
                // The sum of the final R beat is included on this edge. No
                // separate drain/empty/result/done states on the normal path.
                if ((q_count == 0) && !m_axi_arvalid &&
                    ((status != 0) || ((input_left == 0) && (filter_left == 0)))) begin
                    result <= accumulated;
                    done <= 1;
                    // Keep (or make) the ptr1 words reusable only after an
                    // error-free armed call whose words did not wrap the RAM.
                    reuse_valid <= reuse_enable && !reuse_clear && (status == 0) &&
                                   (length_r != 0) &&
                                   ({1'b0,input_received} <= BUFFER_WORDS);
                    active <= 0;
                end
            end
        end
    end
endmodule
