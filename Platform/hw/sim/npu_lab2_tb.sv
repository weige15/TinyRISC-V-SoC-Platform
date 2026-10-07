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
    localparam integer MAX_EXP = 64;
    reg [31:0] exp_addr [0:MAX_EXP-1];
    reg [ 7:0] exp_len  [0:MAX_EXP-1];
    integer    exp_count = 0;
    integer    exp_index = 0;
    integer    split_segments = 0;     // segments fetched with > 1 burst
    integer    multi_beat_bursts = 0;  // AR handshakes with ARLEN > 0
    integer    boundary_bursts = 0;    // bursts ending exactly at 4 KiB

    task automatic add_segment(input [31:0] ptr, input integer n);
        reg [31:0] wa;
        integer words, b, to_boundary, bursts;
        begin
            wa = {ptr[31:2], 2'b00};
            words = (ptr[1:0] + n + 3) / 4;
            bursts = 0;
            while (words > 0) begin
                to_boundary = 1024 - wa[11:2];
                b = words;
                if (b > 256) b = 256;
                if (b > to_boundary) b = to_boundary;
                exp_addr[exp_count] = wa;
                exp_len[exp_count]  = b - 1;
                exp_count = exp_count + 1;
                wa = wa + 4 * b;
                words = words - b;
                bursts = bursts + 1;
            end
            if (bursts > 1) split_segments = split_segments + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // AXI slave
    // ------------------------------------------------------------------
    integer ar_ready_pct = 50;
    integer r_valid_pct  = 50;

    // Burst FIFO (AR handshakes waiting for data).
    reg [31:0] q_addr [0:15];
    reg [ 8:0] q_beats [0:15];
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
            if (arvalid === 1'b1 && arready) begin
                b = arlen + 1;
                end_addr = {1'b0, araddr} + 33'd4 * b;
                total_bursts = total_bursts + 1;
                if (arlen != 0) multi_beat_bursts = multi_beat_bursts + 1;
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
                exp_index = exp_index + 1;
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
            if (rvalid && rready === 1'b1) begin
                total_beats = total_beats + 1;
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
                if (cycles > 20000) begin
                    check(1'b0, "timeout waiting for NPU_done");
                    $display("RESULT: PASS=%0d FAIL=%0d (timeout)", pass_count, fail_count);
                    $finish;
                end
            end
            rd = npu_out;
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
    // injected, the expected AR list ends at the corrupted burst and the
    // status must be expected_status; otherwise result and status 0.
    task automatic run_case(input [31:0] p1, input [31:0] p2, input integer off,
                            input integer n, input integer mode,
                            input integer burst, input integer param,
                            input [2:0] expected_status, input string tag);
        reg [31:0] rd, st;
        integer i, expected;
        begin
            for (i = 0; i < n; i = i + 1) begin
                rd = p1 + i; mem[rd[15:0]] = $urandom;
            end
            for (i = 0; i < n; i = i + 1) begin
                rd = p2 + i; mem[rd[15:0]] = $urandom;
            end
            expected = reference(p1, p2, off, n);

            ar_ready_pct = 20 + ($urandom % 81);
            r_valid_pct  = 20 + ($urandom % 81);

            npu_cmd(32'd0, n, off, rd);
            check(rd == n, $sformatf("%s SET returned %h", tag, rd));

            exp_count = 0;
            exp_index = 0;
            add_segment(p1, n);
            add_segment(p2, n);
            if (mode != INJ_NONE) exp_count = burst + 1;
            inj_mode  = mode;
            inj_burst = burst;
            inj_param = param;
            cmd_burst_index = 0;
            npu_cmd(32'd1, p1, p2, rd);
            compute_count = compute_count + 1;
            check(exp_index == exp_count,
                  $sformatf("%s: %0d AR handshakes, expected %0d", tag, exp_index, exp_count));
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
                exp_count = 0;
                add_segment(p1, n);
                bursts_before_filter = exp_count;
                add_segment(p2, n);
                // Alternate between input-segment and filter-segment bursts.
                target = ((inj / 3) % 2 == 0) ? 0 : bursts_before_filter;
                // Early RLAST needs B >= 2 at the target.
                if (m == INJ_EARLY_LAST && exp_len[target] == 0) target = target + 1;
                if (m == INJ_EARLY_LAST && exp_len[target] == 0) begin
                    n = 64; p1 = 32'h6000_4000 + inj; p2 = 32'h6000_6000 + inj;
                    exp_count = 0;
                    add_segment(p1, n);
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
        check(extra_beats_taken > 0, "missing-RLAST drain not exercised");

        // 6. Random calls.
        for (i = 0; i < 400; i = i + 1) begin
            n = 1 + ($urandom % 256);
            run_case(place(n, $urandom, $urandom), place(n, $urandom, $urandom),
                     pick_offset($urandom), n, INJ_NONE, 0, 0, 3'd0, "random");
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
        $finish;
    end
endmodule
