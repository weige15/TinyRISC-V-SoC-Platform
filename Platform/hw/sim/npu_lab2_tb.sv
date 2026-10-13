`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// npu_lab2_tb
//
// Self-checking testbench for the Lab 2 CUSTOM-0 dot-product service of NPU:
//
//   funct3 = 100, funct7 = 0 : SET     N = rs1, input_offset = int8(rs2[7:0])
//   funct3 = 100, funct7 = 1 : COMPUTE rd = sum_{i<N} (int8(a[i]) + off) * int8(b[i]),
//                                      a = mem[rs1..], b = mem[rs2..]
//   funct3 = 100, funct7 = 2 : STATUS  rd = {bit2 bad RRESP, bit1 missing RLAST,
//                                           bit0 early RLAST} of the last COMPUTE
//   funct3 = 100, funct7 = 3 : REUSE   arm (rs1[0]=1) / disarm ptr1 reuse
//
// Reuse tests (section 7): unarmed calls with the same ptr1/N after the memory
// under ptr1 changed must refetch ptr1 (exact AR list) and see the new bytes;
// armed calls with an unchanged ptr1/N must issue ONLY ptr2 bursts and still
// match the reference; misses, errors, oversize vectors, re-arming and
// disarming must force a refetch.
//
// AXI slave memory model:
//   * ARREADY and RVALID are randomly stalled (per-command random rates).
//   * Every AR handshake is checked: ARADDR[1:0] == 0, 0x6000_0000 <= ARADDR,
//     ARADDR + 4B <= 0x6800_0000, ARADDR[11:0] + 4B <= 4096, ARLEN == B - 1,
//     ARSIZE == 3'b010, ARBURST == 2'b01, and ARVALID/ARADDR/ARLEN stable
//     until ARREADY. The (ARADDR, ARLEN) sequence must also equal the exact
//     expected burst list (covering span split only at 4 KiB boundaries), so
//     replacing a multi-beat burst with single beats is caught.
//   * Beats are sent in address order, little-endian, RDATA/RLAST/RRESP hold
//     while RVALID && !RREADY, and RDATA/RLAST/RRESP are random garbage
//     whenever RVALID is low (a beat taken without RVALID corrupts results).
//   * Error injection: early RLAST, beat B without RLAST (+ extra beats),
//     non-OKAY RRESP (SLVERR / DECERR).
// NPU_done monitor: exactly one pulse per command, never while idle.
//////////////////////////////////////////////////////////////////////////////////
module npu_lab2_tb;
    localparam integer TB_RAM_WORDS = 2048; // operand ring RAM words in the DUT

    // ------------------------------------------------------------------
    // Clock / reset / DUT
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg  [31:0] rs1_i = 32'd0;
    reg  [31:0] rs2_i = 32'd0;
    reg         npu_start = 1'b0;
    reg  [ 3:0] funct3_i = 4'd0;
    reg  [31:0] funct7_i = 32'd0;
    wire [31:0] npu_out;
    wire        npu_done;

    wire [31:0] awaddr;
    wire [ 7:0] awlen;
    wire [ 2:0] awsize;
    wire [ 1:0] awburst;
    wire        awlock;
    wire [ 3:0] awcache;
    wire [ 2:0] awprot;
    wire [ 3:0] awqos;
    wire [15:0] awuser;
    wire        awvalid;
    wire [31:0] wdata;
    wire [ 3:0] wstrb;
    wire        wlast;
    wire        wvalid;
    wire        bready;
    wire [31:0] araddr;
    wire [ 7:0] arlen;
    wire [ 2:0] arsize;
    wire [ 1:0] arburst;
    wire        arlock;
    wire [ 3:0] arcache;
    wire [ 2:0] arprot;
    wire [ 3:0] arqos;
    wire [15:0] aruser;
    wire        arvalid;
    reg         arready = 1'b0;
    reg  [31:0] rdata = 32'd0;
    reg  [ 1:0] rresp = 2'd0;
    reg         rlast = 1'b0;
    reg         rvalid = 1'b0;
    wire        rready;

    NPU dut (
        .clk(clk), .rst_n(rst_n),
        .rs1_i(rs1_i), .rs2_i(rs2_i), .NPU_out(npu_out),
        .NPU_start(npu_start), .NPU_done(npu_done),
        .funct3_i(funct3_i), .funct7_i(funct7_i),
        .M_AXI_AWADDR(awaddr), .M_AXI_AWLEN(awlen), .M_AXI_AWSIZE(awsize),
        .M_AXI_AWBURST(awburst), .M_AXI_AWLOCK(awlock), .M_AXI_AWCACHE(awcache),
        .M_AXI_AWPROT(awprot), .M_AXI_AWQOS(awqos), .M_AXI_AWUSER(awuser),
        .M_AXI_AWVALID(awvalid), .M_AXI_AWREADY(1'b0),
        .M_AXI_WDATA(wdata), .M_AXI_WSTRB(wstrb), .M_AXI_WLAST(wlast),
        .M_AXI_WVALID(wvalid), .M_AXI_WREADY(1'b0),
        .M_AXI_BRESP(2'b00), .M_AXI_BVALID(1'b0), .M_AXI_BREADY(bready),
        .M_AXI_ARADDR(araddr), .M_AXI_ARLEN(arlen), .M_AXI_ARSIZE(arsize),
        .M_AXI_ARBURST(arburst), .M_AXI_ARLOCK(arlock), .M_AXI_ARCACHE(arcache),
        .M_AXI_ARPROT(arprot), .M_AXI_ARQOS(arqos), .M_AXI_ARUSER(aruser),
        .M_AXI_ARVALID(arvalid), .M_AXI_ARREADY(arready),
        .M_AXI_RID(4'd0), .M_AXI_RDATA(rdata), .M_AXI_RRESP(rresp),
        .M_AXI_RLAST(rlast), .M_AXI_RVALID(rvalid), .M_AXI_RREADY(rready)
    );

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check(input bit ok, input string what);
        if (ok) begin
            pass_count = pass_count + 1;
        end else begin
            fail_count = fail_count + 1;
            if (fail_count <= 40) $display("[FAIL] t=%0t %s", $time, what);
        end
    endtask

    // ------------------------------------------------------------------
    // Memory: 64 KiB of bytes, aliased over the whole AXI window (index =
    // address[15:0]). The DUT and the reference both read through it.
    // ------------------------------------------------------------------
    reg [7:0] mem [0:65535];

    function automatic [31:0] mem_word(input [31:0] addr);
        mem_word = {mem[addr[15:0] + 16'd3], mem[addr[15:0] + 16'd2],
                    mem[addr[15:0] + 16'd1], mem[addr[15:0]]};
    endfunction

    // ------------------------------------------------------------------
    // Expected AR sequence of the current command
    // ------------------------------------------------------------------
    localparam integer MAX_EXP = 512;
    reg [31:0] exp_addr [0:MAX_EXP-1];
    reg [ 7:0] exp_len  [0:MAX_EXP-1];
    reg exp_filter [0:MAX_EXP-1];
    integer    exp_count = 0;
    bit        keep_p1 = 0;     // run_case: leave the bytes under ptr1 unchanged
    bit        expect_hit = 0;  // expected AR list: ptr1 words already held
    bit        keep_p2 = 0;     // run_case: leave the bytes under ptr2 unchanged
    integer    reuse_hits = 0, reuse_refetches = 0, reuse_data_changes = 0;
    integer    exp_index = 0;
    integer    split_segments = 0;     // segments fetched with > 1 burst
    integer    multi_beat_bursts = 0;  // AR handshakes with ARLEN > 0
    integer    boundary_bursts = 0;    // bursts ending exactly at 4 KiB

    // Independent reference cursors. Prefer a full filter burst as soon as
    // its input span has been requested. Each operand's bursts are maximal;
    // no chunk-size split or reread of alignment words is permitted.
    task automatic expected_bursts(input [31:0] p1, p2, input integer n);
        reg [31:0] a, b;
        integer al, bl, ai, bi, ab, bb, needed, bytes_end, ac, bc;
        bit f;
        begin
            exp_count = 0;
            a = p1 & 32'hfffffffc; b = p2 & 32'hfffffffc;
            al = (n == 0) ? 0 : (n + p1[1:0] + 3)/4;
            bl = (n == 0) ? 0 : (n + p2[1:0] + 3)/4;
            ai = 0; bi = 0; ac = 0; bc = 0;
            if (expect_hit) begin ai = al; al = 0; end
            while (al != 0 || bl != 0) begin
                ab = al; if (ab > 256) ab = 256;
                if (ab > 1024-a[11:2]) ab = 1024-a[11:2];
                bb = bl; if (bb > 256) bb = 256;
                if (bb > 1024-b[11:2]) bb = 1024-b[11:2];
                bytes_end = 4*(bi+bb) - p2[1:0];
                if (bytes_end > n) bytes_end = n;
                needed = (bytes_end + p1[1:0] + 3)/4;
                f = (bl != 0 && ai >= needed);
                exp_addr[exp_count] = f ? b : a;
                exp_len[exp_count] = (f ? bb : ab) - 1;
                exp_filter[exp_count] = f;
                if (f) begin b = b+4*bb; bl = bl-bb; bi = bi+bb; bc = bc+1; end
                else begin a = a+4*ab; al = al-ab; ai = ai+ab; ac = ac+1; end
                exp_count = exp_count + 1;
                if (exp_count >= MAX_EXP) $fatal(1,"expected burst list overflow");
            end
            if (ac > 1) split_segments = split_segments + 1;
            if (bc > 1) split_segments = split_segments + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // AXI slave
    // ------------------------------------------------------------------
    integer ar_ready_pct = 50;
    integer r_valid_pct  = 50;
    integer latency_mode = -1; // -1 regression, 0 zero wait, 1 random stalls
    integer cycle_number = 0, command_cycles = 0;
    integer first_r_cycle, last_r_cycle, last_input_cycle, first_filter_ar_cycle;
    integer first_filter_offer_cycle;
    integer last_beat_cycle, command_beats, command_gaps;
    integer latency_rows = 0;
    integer errors_with_prefetch = 0, errors_with_held_ar = 0, full_bursts = 0;
    bit perf_active = 0;
    bit error_seen = 0, held_on_error = 0;
    reg [31:0] held_error_addr;
    reg [7:0] held_error_len;
    always @(posedge clk) cycle_number <= cycle_number + 1;

    // Burst FIFO (AR handshakes waiting for data).
    reg [31:0] q_addr [0:15];
    reg [ 8:0] q_beats [0:15];
    reg q_filter [0:15];
    integer q_head = 0, q_tail = 0, q_count = 0;

    // Error injection for the current command.
    localparam integer INJ_NONE = 0, INJ_EARLY_LAST = 1, INJ_MISSING_LAST = 2,
                       INJ_BAD_RESP = 3;
    integer inj_mode = INJ_NONE;
    integer inj_burst = 0;       // burst index (within the command) to corrupt
    integer inj_param = 0;       // beat index / extra beats
    reg [1:0] inj_resp = 2'b10;
    integer cmd_burst_index = 0; // bursts started in this command

    // Current R burst.
    reg        r_act = 1'b0;
    reg        r_filter = 1'b0;
    reg [31:0] r_addr;
    integer    r_beat, r_b, r_last_at, r_bad_at;
    integer    extra_beats_taken = 0;

    // AR stability tracking.
    reg        ar_pending = 1'b0;
    reg [31:0] ar_prev_addr;
    reg [ 7:0] ar_prev_len;

    integer total_bursts = 0;
    integer total_beats  = 0;

    always @(posedge clk) begin : slave
        reg [32:0] end_addr;
        integer b;
        if (!rst_n) begin
            arready <= 1'b0;
            rvalid  <= 1'b0;
            r_act   = 1'b0;
            q_head = 0; q_tail = 0; q_count = 0;
            ar_pending = 1'b0;
        end else begin
            // ---------------- AR channel ----------------
            if (ar_pending) begin
                check(arvalid === 1'b1, "ARVALID dropped before ARREADY");
                check(araddr === ar_prev_addr, "ARADDR changed before ARREADY");
                check(arlen === ar_prev_len, "ARLEN changed before ARREADY");
            end
            if (perf_active && arvalid && exp_filter[exp_index] && first_filter_offer_cycle < 0)
                first_filter_offer_cycle = cycle_number;
            if (arvalid === 1'b1 && arready) begin
                b = arlen + 1;
                end_addr = {1'b0, araddr} + 33'd4 * b;
                total_bursts = total_bursts + 1;
                if (arlen != 0) multi_beat_bursts = multi_beat_bursts + 1;
                if (arlen == 255) full_bursts = full_bursts + 1;
                if (end_addr[11:0] == 12'd0) boundary_bursts = boundary_bursts + 1;
                check(araddr[1:0] == 2'b00, $sformatf("ARADDR %h not aligned", araddr));
                check(araddr >= 32'h6000_0000, $sformatf("ARADDR %h below window", araddr));
                check(end_addr <= 33'h0_6800_0000, $sformatf("burst %h+%0d beyond window", araddr, b));
                check({20'd0, araddr[11:0]} + 4 * b <= 4096,
                      $sformatf("burst %h len %0d crosses 4 KiB", araddr, b));
                check(arsize == 3'b010, "ARSIZE != 3'b010");
                check(arburst == 2'b01, "ARBURST != INCR");
                if (exp_index < exp_count) begin
                    check(araddr == exp_addr[exp_index] && arlen == exp_len[exp_index],
                          $sformatf("AR #%0d got %h/ARLEN %0d, expected %h/ARLEN %0d",
                                    exp_index, araddr, arlen,
                                    exp_addr[exp_index], exp_len[exp_index]));
                end else begin
                    check(1'b0, $sformatf("unexpected AR %h ARLEN %0d", araddr, arlen));
                end
                if (perf_active && exp_filter[exp_index] && first_filter_ar_cycle < 0)
                    first_filter_ar_cycle = cycle_number;
                if (error_seen) begin
                    check(held_on_error && araddr == held_error_addr && arlen == held_error_len,
                          "new AR issued after error instead of draining");
                    held_on_error = 0;
                end
                q_filter[q_tail] = exp_filter[exp_index];
                exp_index = exp_index + 1;
                check(q_count < 16, "slave request FIFO overflow");
                q_addr[q_tail]  = araddr;
                q_beats[q_tail] = b[8:0];
                q_tail = (q_tail + 1) % 16;
                q_count = q_count + 1;
            end
            ar_pending   = (arvalid === 1'b1) && !arready;
            ar_prev_addr = araddr;
            ar_prev_len  = arlen;
            arready <= (($urandom % 100) < ar_ready_pct);

            // ---------------- R channel ----------------
            if (rvalid) check(rready === 1'b1,"master stalled an arriving R beat");
            if (!(rvalid && rready))
                check(dut.u_burst_dot_product.emit_valid === 1'b0,
                      "storage/MAC consumed a beat without RVALID && RREADY");
            if (rvalid && rready === 1'b1) begin
                total_beats = total_beats + 1;
                if (perf_active) begin
                    if (first_r_cycle < 0) first_r_cycle = cycle_number;
                    if (last_beat_cycle >= 0 && cycle_number != last_beat_cycle+1)
                        command_gaps = command_gaps + cycle_number-last_beat_cycle-1;
                    last_beat_cycle = cycle_number;
                    last_r_cycle = cycle_number;
                    if (!r_filter) last_input_cycle = cycle_number;
                    command_beats = command_beats + 1;
                    check(dut.u_burst_dot_product.emit_valid === 1'b1,
                          "usable R beat not consumed in its arrival cycle");
                end
                if (error_seen)
                    check(dut.u_burst_dot_product.emit_valid === 1'b0,
                          "local storage/MAC written after an error");
                if (!error_seen && (rresp != 0 ||
                    (rlast && r_beat != r_b-1) || (!rlast && r_beat == r_b-1))) begin
                    error_seen = 1;
                    held_on_error = arvalid && !arready;
                    if (q_count > 0) errors_with_prefetch = errors_with_prefetch+1;
                    if (held_on_error) errors_with_held_ar = errors_with_held_ar+1;
                    held_error_addr = araddr; held_error_len = arlen;
                    check(dut.u_burst_dot_product.emit_valid === 1'b0,
                          "bad beat written to storage/MAC");
                end
                if (r_beat >= r_b) begin
                    // Beat past B (missing-RLAST injection): must be discarded.
                    extra_beats_taken = extra_beats_taken + 1;
                    check(dut.u_burst_dot_product.emit_valid === 1'b0,
                          "local storage written after beat B without RLAST");
                end
                r_beat = r_beat + 1;
                r_addr = r_addr + 4;
                if (rlast) r_act = 1'b0;
            end
            if (!r_act && q_count > 0) begin
                r_addr    = q_addr[q_head];
                r_b       = q_beats[q_head];
                r_filter  = q_filter[q_head];
                q_head    = (q_head + 1) % 16;
                q_count   = q_count - 1;
                r_beat    = 0;
                r_last_at = r_b - 1;
                r_bad_at  = -1;
                if (cmd_burst_index == inj_burst) begin
                    case (inj_mode)
                        INJ_EARLY_LAST:   r_last_at = inj_param % (r_b - 1);
                        INJ_MISSING_LAST: r_last_at = r_b - 1 + inj_param;
                        INJ_BAD_RESP:     r_bad_at  = inj_param % r_b;
                        default: ;
                    endcase
                end
                cmd_burst_index = cmd_burst_index + 1;
                r_act = 1'b1;
            end
            if (rvalid && rready !== 1'b1) begin
                // Hold RVALID/RDATA/RLAST/RRESP until RREADY.
            end else if (r_act && (($urandom % 100) < r_valid_pct)) begin
                rvalid <= 1'b1;
                rdata  <= mem_word(r_addr);
                rlast  <= (r_beat == r_last_at);
                rresp  <= (r_beat == r_bad_at) ? inj_resp : 2'b00;
            end else begin
                rvalid <= 1'b0;
                rdata  <= $urandom;
                rlast  <= $urandom;
                rresp  <= $urandom;
            end
        end
    end

    // ------------------------------------------------------------------
    // NPU_done monitor
    // ------------------------------------------------------------------
    reg     busy = 1'b0;
    integer start_count = 0;
    integer done_count = 0;
    integer back_to_back = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (npu_done === 1'b1) begin
                check(busy, "NPU_done high while idle / extra NPU_done pulse");
                busy = 1'b0;
                done_count = done_count + 1;
            end else begin
                check(npu_done === 1'b0, "NPU_done is X");
            end
            if (npu_start) begin
                check(!busy, "start while busy");
                if (npu_done === 1'b1) back_to_back = back_to_back + 1;
                busy = 1'b1;
                start_count = start_count + 1;
            end
            check(awvalid !== 1'b1 && wvalid !== 1'b1, "unexpected AXI write");
        end
    end

    // ------------------------------------------------------------------
    // Command driver. Called right after a clock edge; returns right after
    // the edge on which NPU_done is seen, so consecutive calls have no gap.
    // ------------------------------------------------------------------
    task automatic npu_cmd(input [31:0] f7, input [31:0] a, input [31:0] b,
                           output [31:0] rd);
        integer cycles;
        begin
            funct3_i  = 4'b0100;
            funct7_i  = f7;
            rs1_i     = a;
            rs2_i     = b;
            npu_start = 1'b1;
            @(posedge clk); #1;
            npu_start = 1'b0;
            rs1_i = $urandom; rs2_i = $urandom;  // operands only valid at start
            funct7_i = $urandom;
            cycles = 0;
            while (npu_done !== 1'b1) begin
                @(posedge clk); #1;
                cycles = cycles + 1;
                if (cycles > 200000) begin
                    check(1'b0, "timeout waiting for NPU_done");
                    $display("RESULT: PASS=%0d FAIL=%0d (timeout)", pass_count, fail_count);
                    $fatal(1,"timeout");
                end
            end
            rd = npu_out;
            command_cycles = cycles;
        end
    endtask

    function automatic integer reference(input [31:0] p1, input [31:0] p2,
                                         input integer off, input integer n);
        integer i, acc;
        reg [31:0] x, y;
        begin
            acc = 0;
            for (i = 0; i < n; i = i + 1) begin
                x = p1 + i;
                y = p2 + i;
                acc = acc + ($signed(mem[x[15:0]]) + off) * $signed(mem[y[15:0]]);
            end
            reference = acc;
        end
    endfunction

    integer compute_count = 0;

    // One hw_simd_mac-style call: SET, COMPUTE, STATUS. With an error
    // injected, already issued/pending requests must drain before done;
    // status must be expected_status; otherwise result and status 0.
    task automatic run_case(input [31:0] p1, input [31:0] p2, input integer off,
                            input integer n, input integer mode,
                            input integer burst, input integer param,
                            input [2:0] expected_status, input string tag);
        reg [31:0] rd, st;
        integer i, expected;
        begin
            if (!keep_p1)
                for (i = 0; i < n; i = i + 1) begin
                    rd = p1 + i; mem[rd[15:0]] = $urandom;
                end
            if (!keep_p2)
                for (i = 0; i < n; i = i + 1) begin
                    rd = p2 + i; mem[rd[15:0]] = $urandom;
                end
            expected = reference(p1, p2, off, n);

            ar_ready_pct = (latency_mode == 0) ? 100 : 20 + ($urandom % 81);
            r_valid_pct  = (latency_mode == 0) ? 100 : 20 + ($urandom % 81);

            npu_cmd(32'd0, n, off, rd);
            check(rd == n, $sformatf("%s SET returned %h", tag, rd));

            exp_index = 0;
            expected_bursts(p1,p2,n);
            error_seen = 0; held_on_error = 0;
            first_r_cycle = -1; last_r_cycle = -1; last_input_cycle = -1;
            first_filter_ar_cycle = -1; first_filter_offer_cycle = -1; last_beat_cycle = -1;
            command_beats = 0; command_gaps = 0;
            perf_active = (latency_mode >= 0);
            inj_mode  = mode;
            inj_burst = burst;
            inj_param = param;
            cmd_burst_index = 0;
            npu_cmd(32'd1, p1, p2, rd);
            compute_count = compute_count + 1;
            perf_active = 0;
            check(!r_act && q_count == 0 && !rvalid && !arvalid,
                  "done before all accepted/held AXI requests drained");
            check((mode == INJ_NONE) ? (exp_index == exp_count) :
                                      (exp_index >= burst+1 && exp_index <= exp_count),
                  $sformatf("%s: %0d AR handshakes, expected %0d", tag, exp_index, exp_count));
            if (latency_mode >= 0) begin
                if (!expect_hit) latency_rows = latency_rows + 1;
                $display("%s mode=%s N=%0d align=%0d/%0d cycles=%0d beats=%0d gaps=%0d tail=%0d overlap=%0d offer_overlap=%0d",
                         expect_hit ? "REUSE_LATENCY" : "LATENCY", (latency_mode == 0) ? "zero" : "random", n, p1[1:0],p2[1:0],
                         command_cycles,command_beats,command_gaps,cycle_number-1-last_r_cycle,
                         last_input_cycle-first_filter_ar_cycle, last_input_cycle-first_filter_offer_cycle);
                if (!expect_hit)
                check(first_filter_offer_cycle >= 0 && first_filter_offer_cycle <= last_input_cycle,
                      "ptr2 ARVALID did not overlap ptr1 data (including random AR stalls)");
                check(cycle_number-1-last_r_cycle <= 2, "NPU_done more than 2 cycles after final RLAST");
                if (latency_mode == 0 && !expect_hit) begin
                    check(first_filter_ar_cycle <= last_input_cycle,
                          "ptr2 AR did not overlap ptr1 data");
                    check(command_gaps == 0, "zero-wait R stream has bubbles");
                    if (n == 300) check(command_cycles <= 170,"N=300 exceeds 170 cycles");
                end
            end
            if (expect_hit) reuse_hits = reuse_hits + 1;
            if (mode == INJ_NONE) begin
                check($signed(rd) == expected,
                      $sformatf("%s p1=%h p2=%h off=%0d N=%0d: got %0d expected %0d",
                                tag, p1, p2, off, n, $signed(rd), expected));
            end
            inj_mode = INJ_NONE;
            npu_cmd(32'd2, 32'd0, 32'd0, st);
            check(st == {29'd0, expected_status},
                  $sformatf("%s status %b expected %b", tag, st[2:0], expected_status));
        end
    endtask

    // Random placement inside the window; with near_boundary the vector
    // starts close to the end of a 4 KiB page so its span crosses it.
    function automatic [31:0] place(input integer n, input [1:0] low,
                                    input bit near_boundary);
        reg [31:0] page, a;
        integer back;
        begin
            page = 32'h6000_0000 + (($urandom % 32'h7ffe) << 12);
            if (near_boundary) begin
                back = 4 + 4 * ($urandom % ((n + 3) / 4 + 1));
                a = page + 32'h1000 - back;
            end else begin
                a = page + (($urandom % 1024) << 2);
            end
            place = {a[31:2], low};
        end
    endfunction

    function automatic integer pick_offset(input integer k);
        case (k % 6)
            0: pick_offset = -128;
            1: pick_offset = -1;
            2: pick_offset = 0;
            3: pick_offset = 1;
            4: pick_offset = 127;
            default: pick_offset = $signed($urandom % 256) - 128;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // ptr1 reuse helpers
    // ------------------------------------------------------------------
    task automatic reuse_arm(input bit on);
        reg [31:0] rd;
        begin
            npu_cmd(32'd3, {$urandom, on} , $urandom, rd);
            check(rd == {31'd0, on}, $sformatf("REUSE(%0d) returned %h", on, rd));
        end
    endtask

    // One call with the given expectations. keep: leave memory under ptr1
    // (and ptr2 if keep2) as is; hit: ptr1 must not be fetched.
    task automatic reuse_call(input [31:0] p1, input [31:0] p2, input integer off,
                              input integer n, input bit keep, input bit keep2,
                              input bit hit, input integer mode,
                              input integer burst, input integer param,
                              input [2:0] st, input string tag);
        begin
            keep_p1 = keep; keep_p2 = keep2; expect_hit = hit;
            if (!hit && keep) reuse_refetches = reuse_refetches + 1;
            run_case(p1, p2, off, n, mode, burst, param, st, tag);
            keep_p1 = 0; keep_p2 = 0; expect_hit = 0;
        end
    endtask

    // ptr1 in alias bytes [0x0000,0x7000), ptr2 in [0x8000,0xf000): disjoint.
    function automatic [31:0] reuse_place(input bit second, input integer n,
                                          input [1:0] low);
        reg [31:0] a;
        begin
            a = 32'h6000_0000 + (($urandom % 32'h7ff) << 16) +
                ((32'h7000 - n - 8 > 0) ? ($urandom % (32'h7000 - n - 8)) : 0);
            if (second) a = a + 32'h8000;
            reuse_place = {a[31:2], low};
        end
    endfunction

    // Change at least one byte under ptr1 (all bytes when full).
    task automatic mutate_p1(input [31:0] p1, input integer n, input bit full);
        reg [31:0] x;
        integer i;
        begin
            if (full)
                for (i = 0; i < n; i = i + 1) begin
                    x = p1 + i; mem[x[15:0]] = mem[x[15:0]] ^ (1 + $urandom % 255);
                end
            else begin
                x = p1 + ($urandom % n);
                mem[x[15:0]] = mem[x[15:0]] ^ (1 + $urandom % 255);
            end
        end
    endtask

    // Same ptr1/N/ptr2/offset after the memory under ptr1 changed, with reuse
    // in the given (non-reusing) state: the result must reflect the new data.
    task automatic changed_memory_refetch(input integer n, input string tag);
        reg [31:0] p1, p2;
        integer off, old_ref, new_ref;
        begin
            p1 = reuse_place(0, n, $urandom); p2 = reuse_place(1, n, $urandom);
            off = pick_offset($urandom);
            reuse_call(p1, p2, off, n, 0, 0, 0, INJ_NONE, 0, 0, 0, {tag, "-first"});
            old_ref = reference(p1, p2, off, n);
            mutate_p1(p1, n, $urandom % 2);
            new_ref = reference(p1, p2, off, n);
            if (new_ref != old_ref) reuse_data_changes = reuse_data_changes + 1;
            reuse_call(p1, p2, off, n, 1, 1, 0, INJ_NONE, 0, 0, 0, {tag, "-changed"});
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    integer n, o1, o2, k, i, off, inj, m;
    reg [31:0] p1, p2, rd;
    integer seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 20261007;
        k = $urandom(seed);
        for (i = 0; i < 65536; i = i + 1) mem[i] = $urandom;

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1 rst_n = 1'b1;
        // Idle: NPU_done must stay low (checked by the monitor).
        repeat (20) @(posedge clk);
        #1;

        // Latency matrix: every requested length, all 16 alignment pairs,
        // both a genuinely zero-wait slave and independently random AR/R stalls.
        for (latency_mode = 0; latency_mode <= 1; latency_mode = latency_mode+1)
            for (n = 1; n <= 300; n = (n == 1) ? 3 : (n == 3) ? 64 :
                                      (n == 64) ? 256 : (n == 256) ? 300 : 301)
                for (o1 = 0; o1 < 4; o1 = o1+1)
                    for (o2 = 0; o2 < 4; o2 = o2+1)
                        run_case(32'h60000100+o1,32'h60002100+o2,pick_offset(o1+o2),
                                 n,INJ_NONE,0,0,0,"latency");
        latency_mode = -1;
        check(latency_rows == 160,"latency matrix incomplete");
        run_case(32'h60000003,32'h60002001,-128,0,INJ_NONE,0,0,0,"zero-length");

        // 1. Directed: multi-word span fetched with ARLEN > 0.
        run_case(32'h6000_0100, 32'h6000_0200, 3, 64, INJ_NONE, 0, 0, 3'd0,
                 "directed-aligned-64");
        check(multi_beat_bursts > 0, "no multi-beat (ARLEN>0) burst observed");

        // 2. Directed 4 KiB splits.
        run_case(32'h6000_0FFD, 32'h6000_1F82, -7, 200, INJ_NONE, 0, 0, 3'd0,
                 "directed-4k-split");
        run_case(32'h6123_4FF0, 32'h6123_4FFF, 127, 256, INJ_NONE, 0, 0, 3'd0,
                 "directed-4k-split-2");
        check(split_segments >= 3 && boundary_bursts >= 3,
              "4 KiB split not exercised");

        // 3. Window edges.
        run_case(32'h6800_0000 - 256, 32'h6000_0000, -128, 256, INJ_NONE, 0, 0, 3'd0,
                 "window-top-256");
        run_case(32'h6000_0001, 32'h6800_0000 - 3, 1, 3, INJ_NONE, 0, 0, 3'd0,
                 "window-top-3");
        run_case(32'h6800_0000 - 1, 32'h67ff_fffe, 0, 1, INJ_NONE, 0, 0, 3'd0,
                 "window-top-1");

        // 4. Exhaustive sweep: N = 1..256 x ptr1[1:0] x ptr2[1:0].
        k = 0;
        for (n = 1; n <= 256; n = n + 1) begin
            for (o1 = 0; o1 < 4; o1 = o1 + 1) begin
                for (o2 = 0; o2 < 4; o2 = o2 + 1) begin
                    off = pick_offset(k);
                    p1 = place(n, o1[1:0], (k % 3) == 0);
                    p2 = place(n, o2[1:0], (k % 5) == 1);
                    run_case(p1, p2, off, n, INJ_NONE, 0, 0, 3'd0, "sweep");
                    k = k + 1;
                end
            end
        end
        $display("[INFO] sweep done: %0d calls, pass=%0d fail=%0d",
                 k, pass_count, fail_count);

        // 4b. Long vectors up to one full input-buffer chunk (1024 bytes):
        //     every N in
        //     257..1024 with rotating alignments, and N = 1021..1024 with
        //     all 16 alignment pairs (segments of 257 words need 2 bursts).
        for (n = 257; n <= 1024; n = n + 1) begin
            off = pick_offset(k);
            p1 = place(n, k[1:0], (k % 3) == 0);
            p2 = place(n, k[3:2], (k % 5) == 1);
            run_case(p1, p2, off, n, INJ_NONE, 0, 0, 3'd0, "long-sweep");
            k = k + 1;
        end
        for (n = 1021; n <= 1024; n = n + 1) begin
            for (o1 = 0; o1 < 4; o1 = o1 + 1) begin
                for (o2 = 0; o2 < 4; o2 = o2 + 1) begin
                    off = pick_offset(k);
                    p1 = place(n, o1[1:0], (k % 2) == 0);
                    p2 = place(n, o2[1:0], (k % 3) == 1);
                    run_case(p1, p2, off, n, INJ_NONE, 0, 0, 3'd0, "long-align");
                    k = k + 1;
                end
            end
        end
        $display("[INFO] long sweep done: %0d calls, pass=%0d fail=%0d",
                 k, pass_count, fail_count);

        // 4c. One SET/COMPUTE also handles multiple chunks. Check every
        // alignment pair around chunk boundaries, plus a 4-KiB-crossing span.
        for (n = 1025; n <= 4097; n = (n == 1025) ? 2047 :
                                      (n == 2047) ? 2048 :
                                      (n == 2048) ? 2049 :
                                      (n == 2049) ? 4097 : 4098) begin
            for (o1 = 0; o1 < 4; o1 = o1 + 1) begin
                for (o2 = 0; o2 < 4; o2 = o2 + 1) begin
                    run_case(32'h60000ffc + o1, 32'h60008ffc + o2,
                             pick_offset(k), n, INJ_NONE, 0, 0, 3'd0,
                             "multi-chunk");
                    k = k + 1;
                end
            end
        end

        // Wrap the circular buffer repeatedly, retaining maximal bursts.
        for (o1=0; o1<4; o1=o1+1)
            for (o2=0; o2<4; o2=o2+1)
                run_case(32'h60000000+o1,32'h60008000+o2,pick_offset(o1+o2),
                         16385,INJ_NONE,0,0,0,"ring-wrap");
        // Boundary/256-beat transitions must also sustain one R beat per cycle.
        latency_mode = 0;
        for (o1=0; o1<4; o1=o1+1)
            for (o2=0; o2<4; o2=o2+1) begin
                run_case(32'h60000ffc+o1,32'h60008ffc+o2,-128,300,
                         INJ_NONE,0,0,0,"boundary-latency");
                run_case(32'h600003fc+o1,32'h60008ffc+o2,127,8193,
                         INJ_NONE,0,0,0,"long-latency");
            end
        latency_mode = -1;

        // 5. Error injection, each followed by a normal call.
        for (inj = 0; inj < 60; inj = inj + 1) begin
            m = 1 + (inj % 3);
            n = 9 + ($urandom % 248);
            p1 = place(n, $urandom, (inj % 2) == 0);
            p2 = place(n, $urandom, (inj % 4) == 1);
            off = pick_offset(inj);
            begin : one_injection
                integer bursts_before_filter, target, param;
                reg [2:0] st;
                expected_bursts(p1,p2,n);
                bursts_before_filter = 0;
                while (!exp_filter[bursts_before_filter])
                    bursts_before_filter = bursts_before_filter + 1;
                // Alternate between input-segment and filter-segment bursts.
                target = ((inj / 3) % 2 == 0) ? 0 : bursts_before_filter;
                // Early RLAST needs B >= 2 at the target.
                if (m == INJ_EARLY_LAST && exp_len[target] == 0) target = target + 1;
                if (m == INJ_EARLY_LAST && exp_len[target] == 0) begin
                    n = 64; p1 = 32'h6000_4000 + inj; p2 = 32'h6000_6000 + inj;
                    expected_bursts(p1,p2,n);
                    target = 0;
                end
                case (m)
                    INJ_EARLY_LAST:   begin param = $urandom % 300; st = 3'b001; end
                    INJ_MISSING_LAST: begin param = 1 + ($urandom % 4); st = 3'b010; end
                    default:          begin param = $urandom % 300; st = 3'b100; end
                endcase
                inj_resp = (inj % 2) ? 2'b10 : 2'b11;
                run_case(p1, p2, off, n, m, target, param, st,
                         $sformatf("inject-%0d", m));
                // Follow-up normal call.
                run_case(place(n, $urandom, 1'b1), place(n, $urandom, 1'b0),
                         pick_offset(inj + 1), 1 + ($urandom % 256),
                         INJ_NONE, 0, 0, 3'd0, "after-inject");
            end
        end
        // Errors after multiple maximum-length bursts, with ring reuse.
        for (inj=0; inj<30; inj=inj+1) begin
            m = 1+(inj%3);
            run_case(32'h60000100,32'h60008100,-128,16385,m,3*(inj/3),
                     (m == INJ_MISSING_LAST) ? 3 : 17,
                     (m == INJ_EARLY_LAST) ? 3'b001 :
                     (m == INJ_MISSING_LAST) ? 3'b010 : 3'b100,"long-error");
            run_case(32'h60000ffd,32'h60008002,127,300,INJ_NONE,0,0,0,"after-long-error");
        end
        check(extra_beats_taken > 0, "missing-RLAST drain not exercised");
        check(errors_with_prefetch > 0,"no error with accepted prefetched AR");
        check(errors_with_held_ar > 0,"no error with stalled ARVALID");
        check(full_bursts > 0,"no 256-beat burst");
        $display("[INFO] error-prefetch=%0d error-held-AR=%0d full-256-bursts=%0d",
                 errors_with_prefetch,errors_with_held_ar,full_bursts);

        // 6. Random calls.
        for (i = 0; i < 400; i = i + 1) begin
            n = 1 + ($urandom % ((i % 2) ? 256 : 1024));
            run_case(place(n, $urandom, $urandom), place(n, $urandom, $urandom),
                     pick_offset($urandom), n, INJ_NONE, 0, 0, 3'd0, "random");
        end

        // 7. ptr1 operand reuse.
        begin : reuse_tests
            integer t, h, nn, lens [0:15];
            reg [31:0] q1, q2;
            // 7a. Never armed since reset, after arm+disarm, and after a
            // re-arm (arming invalidates): memory under ptr1 changes between
            // two calls with the same ptr1/N; ptr1 must be refetched.
            for (t = 0; t < 60; t = t + 1)
                changed_memory_refetch(1 + $urandom % ((t % 2) ? 300 : 1024), "unarmed-reset");
            reuse_arm(1); reuse_arm(0);
            for (t = 0; t < 60; t = t + 1)
                changed_memory_refetch(1 + $urandom % ((t % 2) ? 300 : 1024), "unarmed-disarmed");
            for (t = 0; t < 40; t = t + 1) begin
                // Armed call caches ptr1; disarm; memory changes; standalone
                // call must refetch and see the new bytes.
                nn = 1 + $urandom % 400;
                q1 = reuse_place(0, nn, $urandom); q2 = reuse_place(1, nn, $urandom);
                reuse_arm(1);
                reuse_call(q1, q2, 5, nn, 0, 0, 0, INJ_NONE, 0, 0, 0, "armed-cache");
                reuse_call(q1, q2, -3, nn, 1, 0, 1, INJ_NONE, 0, 0, 0, "armed-hit");
                reuse_arm(0);
                mutate_p1(q1, nn, t % 2);
                reuse_call(q1, q2, -3, nn, 1, 1, 0, INJ_NONE, 0, 0, 0, "disarmed-changed");
                // Unchanged memory, still disarmed: standalone call refetches.
                reuse_call(q1, q2, 7, nn, 1, 0, 0, INJ_NONE, 0, 0, 0, "disarmed-same");
                // Re-arming invalidates what was fetched while disarmed.
                reuse_arm(1);
                mutate_p1(q1, nn, t % 2);
                reuse_call(q1, q2, 9, nn, 1, 1, 0, INJ_NONE, 0, 0, 0, "rearmed-changed");
                reuse_call(q1, q2, 11, nn, 1, 0, 1, INJ_NONE, 0, 0, 0, "rearmed-hit");
                reuse_arm(1);
                reuse_call(q1, q2, 13, nn, 1, 1, 0, INJ_NONE, 0, 0, 0, "rearm-twice");
                reuse_arm(0);
            end

            // 7b. Armed sequences: one miss, then hits with new ptr2 vectors
            // (all alignments), offsets and stalls; then key changes.
            lens[0]=1; lens[1]=2; lens[2]=3; lens[3]=4; lens[4]=5; lens[5]=64;
            lens[6]=255; lens[7]=256; lens[8]=299; lens[9]=300; lens[10]=301;
            lens[11]=1021; lens[12]=1024; lens[13]=4093; lens[14]=4096; lens[15]=0;
            reuse_arm(1);
            for (t = 0; t < 160; t = t + 1) begin
                nn = (t < 64) ? lens[t % 15] : 1 + $urandom % ((t % 3) ? 300 : 4000);
                q1 = reuse_place(0, nn, (nn >= 4093) ? 0 : t[1:0]);
                reuse_call(q1, reuse_place(1, nn, $urandom), pick_offset(t), nn,
                           0, 0, 0, INJ_NONE, 0, 0, 0, "armed-miss");
                for (h = 0; h < 4; h = h + 1)
                    reuse_call(q1, reuse_place(1, nn, h[1:0] ^ t[3:2]), pick_offset(t + h + 1),
                               nn, 1, 0, 1, INJ_NONE, 0, 0, 0, "armed-hit");
                // Same vector as both operands (ptr2 = ptr1 bytes, unchanged).
                reuse_call(q1, q1, pick_offset(t + 7), nn, 1, 1, 1, INJ_NONE, 0, 0, 0,
                           "armed-hit-self");
                // Different N with the same ptr1: miss; then the old N misses too.
                if (nn > 1) begin
                    reuse_call(q1, reuse_place(1, nn, $urandom), 3, nn - 1,
                               1, 0, 0, INJ_NONE, 0, 0, 0, "armed-shorter");
                    reuse_call(q1, reuse_place(1, nn, $urandom), 3, nn - 1,
                               1, 0, 1, INJ_NONE, 0, 0, 0, "armed-shorter-hit");
                    reuse_call(q1, reuse_place(1, nn, $urandom), 4, nn,
                               1, 0, 0, INJ_NONE, 0, 0, 0, "armed-old-n");
                    // Neighbouring ptr1 with the same N: miss.
                    mutate_p1(q1 + 1, nn, 1);
                    reuse_call(q1 + 1, reuse_place(1, nn, $urandom), -5, nn,
                               1, 0, 0, INJ_NONE, 0, 0, 0, "armed-next-ptr");
                end
            end
            // Same p1 and N, but the earlier vector wrapped / overflowed the
            // RAM (more than TB_RAM_WORDS words): never reused.
            for (t = 0; t < 8; t = t + 1) begin
                // t < 4: N = 4*TB_RAM_WORDS-2+t at byte offset 3-t covers
                // TB_RAM_WORDS+1 words.
                nn = (t < 4) ? 4*TB_RAM_WORDS - 2 + t : 16385;
                q1 = 32'h6000_0000 + (t << 16) + (3 - (t % 4));
                reuse_call(q1, q1 + 32'h8000, 1, nn, 0, 0, 0, INJ_NONE, 0, 0, 0, "armed-oversize");
                reuse_call(q1, q1 + 32'h8000, 2, nn, 1, 0, 0, INJ_NONE, 0, 0, 0, "armed-oversize-again");
            end

            // 7c. Errors invalidate: input-burst error on a miss, ptr2 error
            // on a hit; the next same-key call refetches, then hits again.
            for (t = 0; t < 30; t = t + 1) begin
                nn = 64 + $urandom % 400;
                q1 = reuse_place(0, nn, $urandom); q2 = reuse_place(1, nn, $urandom);
                m = 1 + (t % 3);
                inj_resp = (t % 2) ? 2'b10 : 2'b11;
                reuse_call(q1, q2, 1, nn, 0, 0, 0, m, 0,
                           (m == INJ_MISSING_LAST) ? 2 : 1 + $urandom % 12,
                           (m == INJ_EARLY_LAST) ? 3'b001 :
                           (m == INJ_MISSING_LAST) ? 3'b010 : 3'b100, "armed-input-error");
                reuse_call(q1, q2, 2, nn, 1, 0, 0, INJ_NONE, 0, 0, 0, "after-input-error");
                reuse_call(q1, q2, 3, nn, 1, 0, 1, INJ_NONE, 0, 0, 0, "hit-before-error");
                reuse_call(q1, q2, 4, nn, 1, 0, 1, m, 0,
                           (m == INJ_MISSING_LAST) ? 2 : 1 + $urandom % 12,
                           (m == INJ_EARLY_LAST) ? 3'b001 :
                           (m == INJ_MISSING_LAST) ? 3'b010 : 3'b100, "hit-filter-error");
                reuse_call(q1, q2, 5, nn, 1, 0, 0, INJ_NONE, 0, 0, 0, "after-filter-error");
                reuse_call(q1, q2, 6, nn, 1, 0, 1, INJ_NONE, 0, 0, 0, "hit-after-recovery");
            end

            // 7d. Hit latency with a zero-wait slave, all ptr2 alignments.
            latency_mode = 0;
            for (o1 = 0; o1 < 4; o1 = o1 + 1) begin
                reuse_call(32'h60000100 + o1, 32'h60008100, 1, 300, 0, 0, 0,
                           INJ_NONE, 0, 0, 0, "reuse-latency-miss");
                for (o2 = 0; o2 < 4; o2 = o2 + 1)
                    reuse_call(32'h60000100 + o1, 32'h60008100 + o2, -128, 300, 1, 0, 1,
                               INJ_NONE, 0, 0, 0, "reuse-latency");
            end
            latency_mode = -1;
            reuse_arm(0);
            // Disarmed again: unchanged memory, same key, both refetched.
            reuse_call(32'h60000103, 32'h60008101, 0, 300, 1, 0, 0, INJ_NONE, 0, 0, 0,
                       "final-disarmed");
            check(reuse_hits > 1000, "too few reuse hits exercised");
            check(reuse_data_changes > 100, "changed-memory cases did not change results");
            $display("[INFO] reuse: hits=%0d forced-refetches=%0d changed-data=%0d",
                     reuse_hits, reuse_refetches, reuse_data_changes);
        end

        // Drain and final accounting.
        repeat (10) @(posedge clk);
        check(start_count == done_count,
              $sformatf("starts %0d != done pulses %0d", start_count, done_count));
        check(back_to_back > 0, "no back-to-back command issued");
        check(busy == 1'b0, "command still pending at end");
        $display("[INFO] computes=%0d commands=%0d back-to-back=%0d bursts=%0d multi-beat=%0d split-segments=%0d 4k-boundary-bursts=%0d beats=%0d discarded=%0d",
                 compute_count, start_count, back_to_back, total_bursts,
                 multi_beat_bursts, split_segments, boundary_bursts,
                 total_beats, extra_beats_taken);
        $display("RESULT: PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1,"Lab 2 regression failed");
        $finish;
    end
endmodule
