`timescale 1ns / 1ps

// Testbench for the NPU burst dot product instruction (CUSTOM-0 funct3 = 100):
//   funct7 = 0 sets the vector length in bytes (rs1),
//   funct7 = 1 returns sum int8(mem[rs1 + i]) * int8(mem[rs2 + i]).
//
// The NPU is driven through its CPU interface and connected to an AXI4 read
// slave model with a byte-addressed memory. The slave accepts several
// outstanding bursts, returns their beats in order, and can stall ARREADY and
// insert RVALID gaps at random. It holds RDATA/RLAST while RVALID is high and
// RREADY is low.
//
// Covered: burst length 1 (ARLEN = 0) and the maximum burst (ARLEN = 255),
// bursts split at a 4 KB boundary, unaligned start addresses and tails,
// multi-chunk vectors, signed int8 extremes, AR and R backpressure, a zero
// length, and the single-word AXI read and SIMD MAC instructions after burst
// operations (shared read channel). Every result is compared with a
// reference computed from the memory model.
module npu_burst_dot_product_tb;
    localparam [31:0] MEMORY_BASE  = 32'h6000_0000;
    localparam integer MEMORY_BYTES = 32768;
    localparam integer QUEUE_DEPTH  = 64;
    localparam integer TIMEOUT_CYCLES = 200000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg [31:0] rs1_i = 32'd0;
    reg [31:0] rs2_i = 32'd0;
    reg NPU_start = 1'b0;
    wire [31:0] NPU_out;
    wire NPU_done;
    reg [3:0] funct3_i = 4'd0;
    reg [31:0] funct7_i = 32'd0;

    wire [31:0] M_AXI_ARADDR;
    wire [7:0]  M_AXI_ARLEN;
    wire [2:0]  M_AXI_ARSIZE;
    wire [1:0]  M_AXI_ARBURST;
    wire        M_AXI_ARVALID;
    reg         M_AXI_ARREADY = 1'b0;
    reg [31:0]  M_AXI_RDATA = 32'd0;
    reg         M_AXI_RLAST = 1'b0;
    reg         M_AXI_RVALID = 1'b0;
    wire        M_AXI_RREADY;

    NPU dut (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_i(rs1_i),
        .rs2_i(rs2_i),
        .NPU_out(NPU_out),
        .NPU_start(NPU_start),
        .NPU_done(NPU_done),
        .funct3_i(funct3_i),
        .funct7_i(funct7_i),
        .M_AXI_AWREADY(1'b0),
        .M_AXI_WREADY(1'b0),
        .M_AXI_BRESP(2'b00),
        .M_AXI_BVALID(1'b0),
        .M_AXI_ARADDR(M_AXI_ARADDR),
        .M_AXI_ARLEN(M_AXI_ARLEN),
        .M_AXI_ARSIZE(M_AXI_ARSIZE),
        .M_AXI_ARBURST(M_AXI_ARBURST),
        .M_AXI_ARVALID(M_AXI_ARVALID),
        .M_AXI_ARREADY(M_AXI_ARREADY),
        .M_AXI_RID(4'b0000),
        .M_AXI_RDATA(M_AXI_RDATA),
        .M_AXI_RRESP(2'b00),
        .M_AXI_RLAST(M_AXI_RLAST),
        .M_AXI_RVALID(M_AXI_RVALID),
        .M_AXI_RREADY(M_AXI_RREADY)
    );

    reg [7:0] memory [0:MEMORY_BYTES-1];

    integer failures = 0;
    integer checks = 0;

    // Slave behaviour knobs (percent per cycle / per beat).
    integer ar_stall_percent = 0;
    integer r_gap_percent = 0;

    // Coverage / protocol counters.
    integer bursts_total = 0;
    integer bursts_len1 = 0;        // ARLEN == 0
    integer bursts_max = 0;         // ARLEN == 255
    integer bursts_to_4k_edge = 0;  // bursts that end exactly on a 4 KB boundary
    integer bursts_from_4k_edge = 0;// bursts that start exactly on a 4 KB boundary
    integer ar_stall_cycles = 0;    // ARVALID high, ARREADY low
    integer r_gap_cycles = 0;       // slave has data pending but RVALID low
    integer r_master_stall_cycles = 0; // RVALID high, RREADY low
    integer op_bursts = 0;          // bursts of the current operation
    integer op_max_arlen = 0;
    integer op_min_arlen = 255;

    // Outstanding bursts (address, beats).
    reg [31:0] queue_address [0:QUEUE_DEPTH-1];
    integer    queue_beats   [0:QUEUE_DEPTH-1];
    integer queue_head = 0;
    integer queue_tail = 0;
    integer r_beat_in_burst = 0;

    // AR stability check state.
    reg        ar_waiting = 1'b0;
    reg [31:0] ar_waiting_address = 32'd0;
    reg [7:0]  ar_waiting_len = 8'd0;
    // R stability check state.
    reg        r_waiting = 1'b0;
    reg [31:0] r_waiting_data = 32'd0;
    reg        r_waiting_last = 1'b0;

    function [31:0] memory_word(input [31:0] address);
        integer index;
        begin
            index = address - MEMORY_BASE;
            if (index < 0 || index + 3 >= MEMORY_BYTES) begin
                memory_word = 32'hDEAD_BEEF;
            end else begin
                memory_word = {memory[index + 3], memory[index + 2],
                               memory[index + 1], memory[index]};
            end
        end
    endfunction

    task fail(input [8*160-1:0] message);
        begin
            failures = failures + 1;
            $display("[FAIL] %0s", message);
        end
    endtask

    // ------------------------------------------------------------------
    // AXI4 read slave
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            M_AXI_ARREADY <= 1'b0;
            ar_waiting <= 1'b0;
        end else begin
            if (M_AXI_ARVALID && M_AXI_ARREADY) begin
                bursts_total = bursts_total + 1;
                op_bursts = op_bursts + 1;
                if (M_AXI_ARLEN == 8'd0) bursts_len1 = bursts_len1 + 1;
                if (M_AXI_ARLEN == 8'd255) bursts_max = bursts_max + 1;
                if (M_AXI_ARLEN > op_max_arlen) op_max_arlen = M_AXI_ARLEN;
                if (M_AXI_ARLEN < op_min_arlen) op_min_arlen = M_AXI_ARLEN;
                if (M_AXI_ARADDR[1:0] != 2'b00) begin
                    $display("[FAIL] ARADDR 0x%08x is not word aligned", M_AXI_ARADDR);
                    failures = failures + 1;
                end
                if (M_AXI_ARSIZE != 3'b010 || M_AXI_ARBURST != 2'b01) begin
                    $display("[FAIL] ARSIZE=%0d ARBURST=%0d, expected 4-byte INCR",
                             M_AXI_ARSIZE, M_AXI_ARBURST);
                    failures = failures + 1;
                end
                if ({20'd0, M_AXI_ARADDR[11:0]} + ((M_AXI_ARLEN + 1) * 4) > 4096) begin
                    $display("[FAIL] burst ARADDR=0x%08x ARLEN=%0d crosses a 4 KB boundary",
                             M_AXI_ARADDR, M_AXI_ARLEN);
                    failures = failures + 1;
                end
                if ({20'd0, M_AXI_ARADDR[11:0]} + ((M_AXI_ARLEN + 1) * 4) == 4096) begin
                    bursts_to_4k_edge = bursts_to_4k_edge + 1;
                end
                if (M_AXI_ARADDR[11:0] == 12'd0) begin
                    bursts_from_4k_edge = bursts_from_4k_edge + 1;
                end
                if (queue_tail - queue_head >= QUEUE_DEPTH) begin
                    fail("slave burst queue overflow");
                end
                queue_address[queue_tail % QUEUE_DEPTH] = M_AXI_ARADDR;
                queue_beats[queue_tail % QUEUE_DEPTH]   = M_AXI_ARLEN + 1;
                queue_tail = queue_tail + 1;
                ar_waiting <= 1'b0;
            end else if (M_AXI_ARVALID) begin
                ar_stall_cycles = ar_stall_cycles + 1;
                if (ar_waiting && (M_AXI_ARADDR !== ar_waiting_address ||
                                   M_AXI_ARLEN !== ar_waiting_len)) begin
                    fail("ARADDR/ARLEN changed while ARVALID waited for ARREADY");
                end
                ar_waiting <= 1'b1;
                ar_waiting_address <= M_AXI_ARADDR;
                ar_waiting_len <= M_AXI_ARLEN;
            end else if (ar_waiting) begin
                fail("ARVALID dropped before ARREADY");
                ar_waiting <= 1'b0;
            end
            M_AXI_ARREADY <= ($urandom % 100) >= ar_stall_percent;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            M_AXI_RVALID <= 1'b0;
            M_AXI_RLAST  <= 1'b0;
            r_waiting    <= 1'b0;
        end else begin
            if (M_AXI_RVALID && !M_AXI_RREADY) begin
                // Master backpressure: data must stay put.
                r_master_stall_cycles = r_master_stall_cycles + 1;
                if (r_waiting && (M_AXI_RDATA !== r_waiting_data ||
                                  M_AXI_RLAST !== r_waiting_last)) begin
                    fail("slave model changed RDATA while RREADY was low");
                end
                r_waiting <= 1'b1;
                r_waiting_data <= M_AXI_RDATA;
                r_waiting_last <= M_AXI_RLAST;
            end else begin
                r_waiting <= 1'b0;
                if (M_AXI_RVALID && M_AXI_RREADY) begin
                    // Beat accepted.
                    r_beat_in_burst = r_beat_in_burst + 1;
                    if (r_beat_in_burst == queue_beats[queue_head % QUEUE_DEPTH]) begin
                        queue_head = queue_head + 1;
                        r_beat_in_burst = 0;
                    end
                end
                if (queue_tail != queue_head && ($urandom % 100) >= r_gap_percent) begin
                    M_AXI_RDATA  <= memory_word(queue_address[queue_head % QUEUE_DEPTH] +
                                                4 * r_beat_in_burst);
                    M_AXI_RLAST  <= (r_beat_in_burst + 1 ==
                                     queue_beats[queue_head % QUEUE_DEPTH]);
                    M_AXI_RVALID <= 1'b1;
                end else begin
                    if (queue_tail != queue_head) r_gap_cycles = r_gap_cycles + 1;
                    M_AXI_RVALID <= 1'b0;
                    M_AXI_RLAST  <= 1'b0;
                    M_AXI_RDATA  <= 32'hX;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // CPU-side helpers
    // ------------------------------------------------------------------
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task reset_dut;
        begin
            rst_n = 1'b0;
            NPU_start = 1'b0;
            repeat (3) tick();
            queue_head = 0;
            queue_tail = 0;
            r_beat_in_burst = 0;
            rst_n = 1'b1;
            tick();
        end
    endtask

    task npu_op(input [2:0] funct3, input [6:0] funct7, input [31:0] operand1,
                input [31:0] operand2, output [31:0] value);
        integer waited;
        begin
            funct3_i = {1'b0, funct3};
            funct7_i = {25'd0, funct7};
            rs1_i = operand1;
            rs2_i = operand2;
            NPU_start = 1'b1;
            tick();
            NPU_start = 1'b0;
            waited = 0;
            while (!NPU_done && waited < TIMEOUT_CYCLES) begin
                tick();
                waited = waited + 1;
            end
            if (!NPU_done) begin
                fail("timed out waiting for NPU_done");
            end
            value = NPU_out;
            tick();
        end
    endtask

    function integer reference_dot_product(input integer input_offset,
                                           input integer filter_offset,
                                           input integer length);
        integer i;
        integer sum;
        begin
            sum = 0;
            for (i = 0; i < length; i = i + 1) begin
                sum = sum + $signed(memory[input_offset + i]) *
                            $signed(memory[filter_offset + i]);
            end
            reference_dot_product = sum;
        end
    endfunction

    // Runs one burst dot product and checks the result and the bus state.
    task check_dot_product(input [8*48-1:0] label, input integer input_offset,
                           input integer filter_offset, input integer length);
        reg [31:0] value;
        reg [31:0] expected;
        begin
            op_bursts = 0;
            op_max_arlen = 0;
            op_min_arlen = 255;
            npu_op(3'b100, 7'd0, length, 0, value);
            if (value !== length) fail("set-length did not return the length");
            npu_op(3'b100, 7'd1, MEMORY_BASE + input_offset,
                   MEMORY_BASE + filter_offset, value);
            expected = reference_dot_product(input_offset, filter_offset, length);
            checks = checks + 1;
            if (value !== expected) begin
                $display("[FAIL] %0s: input+0x%0x filter+0x%0x length=%0d result=%0d expected=%0d",
                         label, input_offset, filter_offset, length,
                         $signed(value), $signed(expected));
                failures = failures + 1;
            end else if (label != "" && op_bursts == 0) begin
                $display("[PASS] %0s: input+0x%0x filter+0x%0x length=%0d result=%0d, no read bursts",
                         label, input_offset, filter_offset, length, $signed(value));
            end else if (label != "") begin
                $display("[PASS] %0s: input+0x%0x filter+0x%0x length=%0d result=%0d bursts=%0d ARLEN %0d..%0d",
                         label, input_offset, filter_offset, length,
                         $signed(value), op_bursts, op_min_arlen, op_max_arlen);
            end
            if (queue_tail != queue_head || M_AXI_RVALID) begin
                fail("read data still outstanding after NPU_done");
            end
        end
    endtask

    task fill_random(input integer offset, input integer length);
        integer i;
        begin
            for (i = 0; i < length; i = i + 1) memory[offset + i] = $urandom;
        end
    endtask

    task fill_constant(input integer offset, input integer length, input [7:0] value);
        integer i;
        begin
            for (i = 0; i < length; i = i + 1) memory[offset + i] = value;
        end
    endtask

    integer i;
    integer in_off;
    integer f_off;
    integer len;
    integer burst_len1_before;
    integer burst_max_before;
    integer edge_before;
    integer stall_before;
    integer gap_before;
    integer master_stall_before;
    integer lengths [0:11];
    integer failures_before;
    reg [31:0] value;
    integer seed;

    initial begin
        seed = 20260930;
        value = $urandom(seed);
        for (i = 0; i < MEMORY_BYTES; i = i + 1) memory[i] = $urandom;
        lengths[0] = 1;  lengths[1] = 2;   lengths[2] = 3;   lengths[3] = 4;
        lengths[4] = 5;  lengths[5] = 7;   lengths[6] = 8;   lengths[7] = 13;
        lengths[8] = 300; lengths[9] = 301; lengths[10] = 302; lengths[11] = 303;
        reset_dut();

        // 1. Burst length 1: one-word vectors -> ARLEN = 0 for both segments.
        burst_len1_before = bursts_len1;
        check_dot_product("burst length 1 (aligned, 1 byte)", 32'h0100, 32'h0200, 1);
        check_dot_product("burst length 1 (aligned, 4 bytes)", 32'h0104, 32'h0204, 4);
        if (bursts_len1 - burst_len1_before != 4 || op_max_arlen != 0) begin
            fail("one-word vectors did not use ARLEN = 0 bursts");
        end else begin
            $display("[PASS] burst length 1: %0d bursts with ARLEN = 0",
                     bursts_len1 - burst_len1_before);
        end

        // 2. Maximum burst: 1024-byte aligned vectors away from 4 KB edges ->
        //    one 256-beat burst (ARLEN = 255) per vector.
        burst_max_before = bursts_max;
        check_dot_product("max burst (1024 bytes, aligned)", 32'h0400, 32'h2400, 1024);
        if (bursts_max - burst_max_before != 2 || op_bursts != 2) begin
            fail("1024-byte aligned vectors were not fetched as two ARLEN = 255 bursts");
        end else begin
            $display("[PASS] max burst: 2 bursts with ARLEN = 255");
        end

        // 3. 4 KB boundary: vectors that straddle 0x...1000 and 0x...3000
        //    (unaligned start, unaligned tail) must be split at the boundary.
        edge_before = bursts_to_4k_edge;
        check_dot_product("4 KB crossing (unaligned)", 32'h0F02, 32'h2E81, 601);
        check_dot_product("4 KB crossing (max-size chunk)", 32'h0E03, 32'h2D00, 1024);
        if (bursts_to_4k_edge - edge_before < 4) begin
            fail("vectors across a 4 KB boundary were not split at the boundary");
        end else begin
            $display("[PASS] 4 KB crossing: %0d bursts end exactly on a 4 KB boundary",
                     bursts_to_4k_edge - edge_before);
        end

        // 4. Unaligned start addresses and tails: every input/filter byte
        //    offset pair with lengths 1..303.
        failures_before = failures;
        for (in_off = 0; in_off < 4; in_off = in_off + 1) begin
            for (f_off = 0; f_off < 4; f_off = f_off + 1) begin
                for (i = 0; i < 12; i = i + 1) begin
                    check_dot_product("", 32'h1400 + in_off, 32'h1C00 + f_off, lengths[i]);
                end
            end
        end
        if (failures == failures_before) begin
            $display("[PASS] unaligned start/tail: 16 offset pairs x 12 lengths (1..303)");
        end

        // 5. Signed extremes.
        fill_constant(32'h3000, 1024, 8'h80);
        fill_constant(32'h3800, 1024, 8'h80);
        check_dot_product("signed extremes (-128 x -128)", 32'h3000, 32'h3800, 1024);
        fill_constant(32'h3800, 1024, 8'h7F);
        check_dot_product("signed extremes (-128 x 127)", 32'h3001, 32'h3802, 1021);
        fill_constant(32'h3000, 1024, 8'h7F);
        check_dot_product("signed extremes (127 x 127)", 32'h3003, 32'h3800, 1021);
        for (i = 0; i < 1024; i = i + 1) begin
            memory[32'h3000 + i] = (i % 3 == 0) ? 8'h80 : ((i % 3 == 1) ? 8'h7F : 8'hFF);
            memory[32'h3800 + i] = (i % 2 == 0) ? 8'h80 : 8'h7F;
        end
        check_dot_product("signed extremes (mixed -128/127/-1)", 32'h3002, 32'h3801, 1000);
        fill_constant(32'h4000, 2600, 8'h80);
        fill_constant(32'h5000, 2600, 8'h80);
        check_dot_product("signed extremes (multi-chunk -128 x -128)", 32'h4001, 32'h5003, 2598);

        // 6. Multi-chunk random vectors (chunks of 1024 bytes).
        check_dot_product("multi-chunk (2500 bytes)", 32'h0103, 32'h1401, 2500);
        check_dot_product("multi-chunk (2048 bytes)", 32'h0400, 32'h1800, 2048);

        // 7. Zero length: no bus traffic, result 0.
        check_dot_product("zero length", 32'h0100, 32'h0200, 0);
        if (op_bursts != 0) fail("zero-length dot product issued read bursts");

        // 8. AR and R backpressure: heavy ARREADY stalls and RVALID gaps.
        failures_before = failures;
        stall_before = ar_stall_cycles;
        gap_before = r_gap_cycles;
        master_stall_before = r_master_stall_cycles;
        ar_stall_percent = 70;
        r_gap_percent = 60;
        check_dot_product("backpressure (aligned, max burst)", 32'h0400, 32'h2400, 1024);
        check_dot_product("backpressure (4 KB crossing)", 32'h0F02, 32'h2E81, 601);
        check_dot_product("backpressure (unaligned tail)", 32'h1401, 32'h1C03, 303);
        check_dot_product("backpressure (multi-chunk)", 32'h0103, 32'h1401, 2500);
        check_dot_product("backpressure (burst length 1)", 32'h0102, 32'h0201, 2);
        ar_stall_percent = 0;
        r_gap_percent = 0;
        if (ar_stall_cycles == stall_before) fail("no ARREADY stall cycles were exercised");
        if (r_gap_cycles == gap_before) fail("no RVALID gap cycles were exercised");
        if (r_master_stall_cycles == master_stall_before) begin
            fail("no RREADY-low cycles with RVALID high were exercised");
        end
        if (failures == failures_before) $display("[PASS] backpressure: %0d ARREADY stall cycles, %0d RVALID gap cycles, %0d RREADY-low cycles with RVALID high",
                 ar_stall_cycles - stall_before, r_gap_cycles - gap_before,
                 r_master_stall_cycles - master_stall_before);

        // 9. Random vectors, offsets and backpressure.
        failures_before = failures;
        for (i = 0; i < 150; i = i + 1) begin
            in_off = $urandom % 12000;
            f_off = 16000 + ($urandom % 12000);
            len = (i % 5 == 0) ? ($urandom % 3000) : ($urandom % 400);
            ar_stall_percent = $urandom % 80;
            r_gap_percent = $urandom % 80;
            check_dot_product("", in_off, f_off, len);
        end
        ar_stall_percent = 0;
        r_gap_percent = 0;
        if (failures == failures_before) begin
            $display("[PASS] 150 random dot products (random offsets, lengths 0..2999, backpressure)");
        end

        // 10. The shared read channel still serves the single-word AXI read
        //     (funct3 = 001) and the SIMD MAC (funct3 = 011) is unchanged.
        failures_before = failures;
        memory[32'h0100] = 8'h11; memory[32'h0101] = 8'h22;
        memory[32'h0102] = 8'h33; memory[32'h0103] = 8'h44;
        memory[32'h0104] = 8'h55; memory[32'h0105] = 8'h66;
        memory[32'h0106] = 8'h77; memory[32'h0107] = 8'h88;
        npu_op(3'b001, 7'd0, MEMORY_BASE + 32'h0100, 0, value);
        checks = checks + 1;
        if (value !== 32'h44332211) fail("aligned AXI read after burst operations");
        npu_op(3'b001, 7'd0, MEMORY_BASE + 32'h0102, 0, value);
        checks = checks + 1;
        if (value !== 32'h66554433) fail("misaligned AXI read after burst operations");
        npu_op(3'b011, 7'd1, 32'h807F0102, 32'h80800304, value);
        checks = checks + 1;
        // lanes: (-128*-128) + (127*-128) + (1*3) + (2*4) = 16384 - 16256 + 3 + 8
        if (value !== 32'd139) fail("SIMD MAC reset after burst operations");
        npu_op(3'b011, 7'd0, 32'h01010101, 32'h02020202, value);
        checks = checks + 1;
        if (value !== 32'd147) fail("SIMD MAC accumulate after burst operations");
        check_dot_product("burst after single-word read and SIMD MAC", 32'h0101, 32'h0203, 9);
        if (failures == failures_before) begin
            $display("[PASS] single-word AXI read and SIMD MAC share the NPU correctly");
        end

        $display("Coverage: %0d bursts, %0d with ARLEN=0, %0d with ARLEN=255, %0d ending on a 4 KB boundary, %0d starting on one",
                 bursts_total, bursts_len1, bursts_max, bursts_to_4k_edge, bursts_from_4k_edge);
        if (bursts_len1 == 0 || bursts_max == 0 || bursts_to_4k_edge == 0) begin
            fail("coverage goals not reached");
        end
        if (failures == 0) begin
            $display("[PASS] All %0d burst dot product checks", checks);
            $finish;
        end else begin
            $display("[FAIL] %0d burst dot product check(s) failed", failures);
            $fatal(1);
        end
    end
endmodule
