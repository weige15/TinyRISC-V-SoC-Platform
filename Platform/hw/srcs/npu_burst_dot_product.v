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
//
// Filter cache (fcache_enable, only while reuse is armed): ptr2 words fetched
// by armed, error-free calls are written to a contiguous window
// [fc_lo, fc_hi) of word addresses held in eight 32-bit block-RAM banks. A
// call extends the window only if its ptr2 words start inside or right at
// the end of the window. A COMPUTE that hits ptr1 reuse, whose ptr2 words lie
// inside the window and whose ptr1/ptr2 byte alignments are equal issues no
// AXI request: eight input words (banked replica) and eight filter words
// are read per cycle into a 32-lane MAC. Any reuse_clear or error empties it.
module npu_burst_dot_product #(
    parameter integer MAX_BURST_BEATS = 256,
    parameter integer CHUNK_WORDS = 256 // retained parameter; RAM = 4x this size
) (
    input clk, input rst_n, input start,
    input [31:0] input_address, filter_address, byte_length,
    input [7:0] input_offset,
    input reuse_enable, input reuse_clear, input fcache_enable,
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
    localparam integer FC_WORDS = 32768;      // 128 KiB filter cache
    localparam integer FC_DEPTH = FC_WORDS/8; // words per bank
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

    // ---------------- filter cache bookkeeping ----------------
    reg fc_valid, fc_app;
    reg [29:0] fc_lo, fc_hi, fc_end_r;
    reg [14:0] fc_wbase;
    wire [29:0] fw0 = filter_address[31:2];
    wire [31:0] fw_end = {2'b00,fw0} + {1'b0,filter_cover};
    wire fc_inside = (fw0 >= fc_lo) && (fw_end <= {2'b00,fc_hi});
    wire fc_full_hit = fcache_enable && reuse_hit && fc_valid && fc_inside &&
                       (input_address[1:0] == filter_address[1:0]) &&
                       (byte_length != 0);
    wire [29:0] fc_base = fc_valid ? fc_lo : fw0;
    wire [31:0] fc_span = fw_end - {2'b00,fc_base};
    wire fc_can_app = fcache_enable && reuse_enable && (byte_length != 0) &&
                      (!fc_valid || ((fw0 >= fc_lo) && (fw0 <= fc_hi) &&
                                     (fw_end > {2'b00,fc_hi}))) &&
                      (fc_span <= FC_WORDS);
    /* verilator lint_off UNUSEDSIGNAL */
    wire [29:0] fc_rel0_full = fw0 - fc_lo; // < FC_WORDS when used
    /* verilator lint_on UNUSEDSIGNAL */
    // Fast (no-AXI) path state.
    reg fast;
    reg [8:0] fast_k, fast_rows, s1_k;
    reg [11:0] fast_row_base;
    reg [2:0] fast_rot;
    reg s1_valid, s2_valid;

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

    // Banked replica of input words 0..1023 (word i in bank i%8, row i/8),
    // read eight words per cycle by the fast path. Same write condition.
    wire in_rep_we = emit_valid && !is_filter && (input_received < 1024);
    wire [255:0] fast_in_row;
    wire [255:0] fast_fc_row;
    reg  [255:0] in_q;
    wire [14:0] fc_wrel = fc_wbase + filter_received[14:0];
    wire fc_we = emit_valid && is_filter && fc_app;
    wire [7:0] rot_mask = (8'd1 << fast_rot) - 8'd1; // banks below rot
    genvar bk;
    generate for (bk=0; bk<8; bk=bk+1) begin: banks
        (* ram_style = "distributed" *) reg [31:0] in_rep [0:127];
        always @(posedge clk)
            if (in_rep_we && input_received[2:0] == bk) in_rep[input_received[9:3]] <= m_axi_rdata;
        assign fast_in_row[32*bk +: 32] = in_rep[fast_k[6:0]];
        (* ram_style = "block" *) reg [31:0] fc_mem [0:FC_DEPTH-1];
        reg [31:0] fc_q;
        wire [11:0] raddr = fast_row_base + {3'd0,fast_k} + {11'd0,rot_mask[bk]};
        always @(posedge clk) begin
            if (fc_we && fc_wrel[2:0] == bk) fc_mem[fc_wrel[14:3]] <= m_axi_rdata;
            fc_q <= fc_mem[raddr];
        end
        assign fast_fc_row[32*bk +: 32] = fc_q;
    end endgenerate
    // Rotate cached words so word j of this row is filter word rel0+8k+j.
    reg [2:0] s1_rot;
    wire [511:0] fc_dbl = {fast_fc_row, fast_fc_row};
    /* verilator lint_off UNUSEDSIGNAL */
    wire [511:0] fc_rot_sh = fc_dbl >> {s1_rot,5'd0};
    /* verilator lint_on UNUSEDSIGNAL */
    wire [255:0] fc_word_row = fc_rot_sh[255:0];
    reg [16:0] fprod [0:31];
    wire [21:0] fast_sum;
    genvar fl;
    generate for (fl=0; fl<32; fl=fl+1) begin: flanes
        wire [13:0] pos = {s1_k, 5'd0} + fl;
        wire v = ({19'd0,pos} >= {31'd0,filter_low}) &&
                 ({19'd0,pos} < {1'b0,length_r} + {31'd0,filter_low});
        wire [16:0] pv = product(in_q[8*fl +: 8], fc_word_row[8*fl +: 8], offset_r, v);
        always @(posedge clk) fprod[fl] <= pv;
    end endgenerate
    function [21:0] sx; input [16:0] x; sx = {{5{x[16]}},x}; endfunction
    // 32 registered products summed in one cycle.
    reg [21:0] fsum_c;
    integer fi;
    always @(*) begin
        fsum_c = 22'd0;
        for (fi = 0; fi < 32; fi = fi + 1) fsum_c = fsum_c + sx(fprod[fi]);
    end
    assign fast_sum = fsum_c;

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
    reg [21:0] mac_sum;
    reg [31:0] accumulator;
    wire [31:0] accumulated = accumulator + (mac_valid ? {{10{mac_sum[21]}},mac_sum} : 32'd0);

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
            fc_valid <= 0; fc_app <= 0; fc_lo <= 0; fc_hi <= 0; fc_end_r <= 0; fc_wbase <= 0;
            fast <= 0; fast_k <= 0; fast_rows <= 0; fast_row_base <= 0; fast_rot <= 0;
            s1_valid <= 0; s2_valid <= 0; s1_k <= 0; s1_rot <= 0; in_q <= 0;
        end else begin
            done <= 0;
            mac_valid <= (emit_valid && is_filter) || s2_valid;
            mac_sum <= s2_valid ? fast_sum : {{3{lane_sum[18]}},lane_sum};
            accumulator <= accumulated;
            // Fast pipeline: S0 issue row reads, S1 multiply, S2 sum, then MAC.
            s1_valid <= fast && (fast_k != fast_rows);
            s1_k <= fast_k;
            s1_rot <= fast_rot;
            in_q <= fast_in_row;
            s2_valid <= s1_valid;
            if (fast && (fast_k != fast_rows)) fast_k <= fast_k + 1'b1;
            if (reuse_clear) begin reuse_valid <= 0; fc_valid <= 0; end
            if (fast && (fast_k == fast_rows) && !s1_valid && !s2_valid) begin
                result <= accumulated;
                done <= 1;
                fast <= 0;
            end
            if (start && !active && !fast && fc_full_hit) begin
                // Both operands are local: no AXI request at all.
                fast <= 1; fast_k <= 0;
                fast_rows <= {1'b0,filter_cover[10:3]} + {8'd0,(filter_cover[2:0] != 0)};
                fast_row_base <= fc_rel0_full[14:3]; fast_rot <= fc_rel0_full[2:0];
                status <= 0; accumulator <= 0; mac_valid <= 0;
                offset_r <= input_offset;
                input_low <= input_address[1:0]; filter_low <= filter_address[1:0];
                length_r <= byte_length;
            end else if (start && !active && !fast && reuse_hit) begin
                // All ptr1 words are already in input_buffer[0..]. Only ptr2
                // is fetched; the scheduler issues its first AR next cycle.
                active <= 1; status <= 0; accumulator <= 0; mac_valid <= 0;
                offset_r <= input_offset;
                input_low <= input_address[1:0]; filter_low <= filter_address[1:0];
                length_r <= byte_length;
                filter_next <= {filter_address[31:2],2'b00};
                fc_app <= fc_can_app;
                fc_wbase <= fc_valid ? fc_rel0_full[14:0] : 15'd0;
                fc_end_r <= fw_end[29:0];
                if (fc_can_app && !fc_valid) begin
                    fc_valid <= 1; fc_lo <= fw0; fc_hi <= fw0;
                end
                input_left <= 0;
                filter_left <= filter_cover;
                input_issued <= input_cover;
                input_received <= input_cover;
                filter_issued <= 0; filter_received <= 0;
                m_axi_arvalid <= 0;
                q_head <= 0; q_tail <= 0; q_count <= 0; beat_index <= 0; discard <= 0;
            end else if (start && !active && !fast) begin
                // A miss overwrites the RAM: invalidate, record the new key.
                reuse_valid <= 0;
                reuse_address <= input_address; reuse_length <= byte_length;
                active <= 1; status <= 0; accumulator <= 0; mac_valid <= 0;
                offset_r <= input_offset;
                input_low <= input_address[1:0]; filter_low <= filter_address[1:0];
                length_r <= byte_length;
                input_next <= {input_address[31:2],2'b00} + {21'd0,first_beats,2'b00};
                filter_next <= {filter_address[31:2],2'b00};
                fc_app <= fc_can_app;
                fc_wbase <= fc_valid ? fc_rel0_full[14:0] : 15'd0;
                fc_end_r <= fw_end[29:0];
                if (fc_can_app && !fc_valid) begin
                    fc_valid <= 1; fc_lo <= fw0; fc_hi <= fw0;
                end
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
                    // Extend the filter window only after an error-free call.
                    if (status != 0) fc_valid <= 0;
                    else if (fc_app) fc_hi <= fc_end_r;
                    fc_app <= 0;
                end
            end
        end
    end
endmodule
