`timescale 1ns / 1ps
// Width/limit audit of the actual NPU hierarchy, not a second RTL model.
// SET accepts all 32 bits: UINT32_MAX is the encoded maximum, NOT 256.
// A non-wrapping vector inside the AXI window is at most 0x08000000 bytes.
// Huge lengths are checked arithmetically and at command initialization; we
// deliberately hold ARREADY low and reset, rather than issue invalid traffic
// or pretend to have simulated a multi-gigabyte vector to completion.
module npu_lab2_counters_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, start = 0;
    reg [31:0] a = 0, b = 0, f7 = 0;
    wire [31:0] result, araddr;
    wire [7:0] arlen;
    wire done, arvalid;
    NPU dut (
        .clk(clk), .rst_n(rst_n), .rs1_i(a), .rs2_i(b), .funct3_i(4'd4),
        .funct7_i(f7), .NPU_start(start), .NPU_out(result), .NPU_done(done),
        .M_AXI_AWREADY(1'b0), .M_AXI_WREADY(1'b0), .M_AXI_BRESP(2'd0),
        .M_AXI_BVALID(1'b0), .M_AXI_ARREADY(1'b0), .M_AXI_RID(4'd0),
        .M_AXI_RDATA(32'd0), .M_AXI_RRESP(2'd0), .M_AXI_RLAST(1'b0),
        .M_AXI_RVALID(1'b0), .M_AXI_ARADDR(araddr), .M_AXI_ARLEN(arlen),
        .M_AXI_ARVALID(arvalid)
    );
    `define E dut.u_burst_dot_product
    integer failures = 0, checks = 0, widths = 0, snapshots = 0;
    localparam longint unsigned N256 = 256;
    localparam longint unsigned WINDOW_N = 64'h08000000;
    localparam longint unsigned ENCODED_N = 64'hffffffff;
    // Conservative over all four low bits. At WINDOW_N only low=0 is a
    // legal whole-window range, so Wwindow overestimates by one word.
    localparam longint unsigned W256 = (N256 + 6)/4;
    localparam longint unsigned Wwindow = (WINDOW_N + 6)/4;
    localparam longint unsigned Wmax = (ENCODED_N + 6)/4;

    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin failures++; $display("[FAIL] %s", what); end
    endtask

    task automatic fits(input string name, input integer bits,
                        input longint unsigned b256, bwin, bmax);
        longint unsigned capacity;
        begin
            capacity = (64'd1 << bits) - 1;
            widths++;
            $display("COUNTER %-52s bits=%0d capacity=%0d N256<=%0d window_max<=%0d encoded_max<=%0d",
                     name, bits, capacity, b256, bwin, bmax);
            check(bits > 0 && bits < 64 && b256 <= capacity &&
                  bwin <= capacity && bmax <= capacity, {name, " overflows"});
        end
    endtask
    `define WIDTH(signal, b256, bwin, bmax) \
        fits(`"signal`", $bits(signal), b256, bwin, bmax);

    // Check the unsliced expression against an independent 64-bit oracle,
    // including every alignment at the largest encodable N. Sample the real
    // state after SET/COMPUTE so a silent clamp or narrowing is also caught.
    task automatic snapshot(input reg [31:0] nn, input integer lo1, lo2);
        longint unsigned c1, c2, issued;
        integer wait_cycles;
        begin
            c1 = (64'(nn) + lo1 + 3)/4;
            c2 = (64'(nn) + lo2 + 3)/4;
            check(`E.covering_words(nn, lo1[1:0]) == c1, "input covering_words");
            check(`E.covering_words(nn, lo2[1:0]) == c2, "filter covering_words");
            @(negedge clk); rst_n = 0; start = 0;
            repeat (2) @(negedge clk);
            rst_n = 1; a = nn; b = 32'hffffff80; f7 = 0; start = 1;
            @(negedge clk); start = 0;
            wait_cycles = 0;
            while (!done && wait_cycles < 10) begin
                @(negedge clk); wait_cycles++;
            end
            check(done && result == nn && dut.burst_dot_product_length_r == nn,
                  "SET did not preserve all 32 length bits");
            @(negedge clk); a = 32'h60000000 + lo1; b = 32'h60000000 + lo2;
            f7 = 1; start = 1;
            @(posedge clk); #1;
            issued = (c1 > 256) ? 256 : c1;
            check(`E.length_r == nn && `E.reuse_length == nn, "latched length truncated");
            check(`E.input_cover == c1 && `E.filter_cover == c2, "cover wire truncated");
            check(`E.input_left == ((nn == 0) ? 0 : c1-issued), "input_left truncated");
            check(`E.filter_left == ((nn == 0) ? 0 : c2), "filter_left truncated");
            check(`E.input_issued == ((nn == 0) ? 0 : issued), "input_issued truncated");
            check(arvalid == (nn != 0), "initial ARVALID");
            if (nn != 0)
                check(araddr == 32'h60000000 && arlen == issued-1,
                      "first burst/256-beat ARLEN encoding");
            snapshots++;
            @(negedge clk); start = 0; rst_n = 0;
        end
    endtask

    integer lo1, lo2, t, left_i, addr_i;
    longint unsigned left_value, want;
    initial begin
        $display("LIMITS: SET/byte_length accepts 32-bit N=0..4294967295; largest legal whole-window N=134217728 at 0x60000000");
        $display("BOUNDS: words=ceil((N+low)/4); low<=3; N256<=%0d window<=%0d encoded<=%0d; burst<=256, ARLEN=beats-1",
                 W256, Wwindow, Wmax);
        // NPU.v: stored length, single-word byte selector and second-beat
        // flag, plus every top-level beat-length field (AWLEN is constant 0).
        `WIDTH(dut.burst_dot_product_length_r, N256, WINDOW_N, ENCODED_N)
        `WIDTH(dut.read_offset_r, 3, 3, 3)
        `WIDTH(dut.read_second_word_r, 1, 1, 1)
        `WIDTH(dut.write_second_pending_r, 1, 1, 1)
        `WIDTH(dut.burst_dot_product_arlen, 64, 255, 255)
        `WIDTH(dut.M_AXI_ARLEN, 64, 255, 255)
        `WIDTH(dut.M_AXI_AWLEN, 0, 0, 0)
        // npu_burst_dot_product.v is the engine instantiated by NPU.v.
        `WIDTH(`E.byte_length, N256, WINDOW_N, ENCODED_N)
        `WIDTH(`E.length_r, N256, WINDOW_N, ENCODED_N)
        `WIDTH(`E.reuse_length, N256, WINDOW_N, ENCODED_N)
        `WIDTH(`E.input_low, 3, 3, 3)
        `WIDTH(`E.filter_low, 3, 3, 3)
        `WIDTH(`E.input_left, W256, Wwindow, Wmax)
        `WIDTH(`E.filter_left, W256, Wwindow, Wmax)
        `WIDTH(`E.input_issued, W256, Wwindow, Wmax)
        `WIDTH(`E.filter_issued, W256, Wwindow, Wmax)
        `WIDTH(`E.input_received, W256, Wwindow, Wmax)
        `WIDTH(`E.filter_received, W256, Wwindow, Wmax)
        `WIDTH(`E.input_cover, W256, Wwindow, Wmax)
        `WIDTH(`E.filter_cover, W256, Wwindow, Wmax)
        `WIDTH(`E.covering_words.span, N256+6, WINDOW_N+6, ENCODED_N+6)
        `WIDTH(`E.burst_size.boundary, 1024, 1024, 1024)
        `WIDTH(`E.burst_size.beats, W256, Wwindow, Wmax)
        `WIDTH(`E.input_beats, W256, 256, 256)
        `WIDTH(`E.filter_beats, W256, 256, 256)
        `WIDTH(`E.first_beats, W256, 256, 256)
        `WIDTH(`E.m_axi_arlen, 64, 255, 255)
        `WIDTH(`E.q_beats[0], W256, 256, 256)
        `WIDTH(`E.q_beats[1], W256, 256, 256)
        // On missing RLAST the index can reach B=256, then discard freezes
        // it. Nine bits, not the eight ARLEN bits, are essential here.
        `WIDTH(`E.beat_index, W256, 256, 256)
        `WIDTH(`E.q_count, 2, 2, 2)
        `WIDTH(`E.count_after, 2, 2, 2)
        `WIDTH(`E.q_head, 1, 1, 1)
        `WIDTH(`E.q_tail, 1, 1, 1)
        `WIDTH(`E.needed_increment, W256+1, 257, 257)
        `WIDTH(`E.needed_words, W256+1, Wwindow+1, Wmax+1)
        `WIDTH(`E.freed_words, W256, Wwindow, Wmax)
        `WIDTH(`E.filter_position, W256*4, Wwindow*4, Wmax*4)
        `WIDTH(`E.filter_limit, N256+3, WINDOW_N+3, ENCODED_N+3)
        `WIDTH(`E.fw_end, 64'h3fffffff+W256, 64'h3fffffff+Wwindow, 64'h3fffffff+Wmax)
        // fc_span is subtracted unsigned; failed/outside windows may wrap
        // to UINT32_MAX and are rejected by the <=32768 append predicate.
        `WIDTH(`E.fc_span, ENCODED_N, ENCODED_N, ENCODED_N)
        // Fast path ONLY after a reusable <=1024-word input, so its row
        // counts stay <=128 independently of the streaming length limit.
        `WIDTH(`E.fast_rows, (W256+7)/8, 128, 128)
        `WIDTH(`E.fast_k, (W256+7)/8, 128, 128)
        `WIDTH(`E.s1_k, (W256+7)/8, 128, 128)
        `WIDTH(`E.flanes[0].pos, ((W256+7)/8)*32+31, 4127, 4127)
        // Bounded/modular RAM indices, not total length counters. Their
        // wrap is intentional; valid stores/lanes are range/credit guarded.
        `WIDTH(`E.read_index, 1023, 1023, 1023)
        `WIDTH(`E.read_index_hi, 1023, 1023, 1023)
        `WIDTH(`E.shift_bytes, 3, 3, 3)
        `WIDTH(`E.fc_wbase, 32767, 32767, 32767)
        `WIDTH(`E.fc_wrel, 32767, 32767, 32767)
        `WIDTH(`E.fast_row_base, 4095, 4095, 4095)
        `WIDTH(`E.banks[0].raddr, 4095, 4095, 4095)
        `WIDTH(`E.fast_rot, 7, 7, 7)
        `WIDTH(`E.s1_rot, 7, 7, 7)

        // Every byte alignment for N=0,1,256, legal maximum at that pair of
        // addresses, and the largest encodable N (held request only).
        for (lo1 = 0; lo1 < 4; lo1++)
            for (lo2 = 0; lo2 < 4; lo2++) begin
                snapshot(0, lo1, lo2);
                snapshot(1, lo1, lo2);
                snapshot(256, lo1, lo2);
                snapshot(32'h08000000 - ((lo1 > lo2) ? lo1 : lo2), lo1, lo2);
                snapshot(32'hffffffff, lo1, lo2);
            end
        // Every possible 4-KiB word position, around the burst limit and at
        // the largest word count. No slicing-induced 256 -> 0 is allowed.
        for (addr_i = 0; addr_i < 1024; addr_i++)
            for (left_i = 0; left_i < 7; left_i++) begin
                case (left_i)
                    0: left_value = 0; 1: left_value = 1;
                    2: left_value = 255; 3: left_value = 256;
                    4: left_value = 257; 5: left_value = Wwindow;
                    default: left_value = Wmax;
                endcase
                want = left_value;
                if (want > 256) want = 256;
                if (want > 1024-addr_i) want = 1024-addr_i;
                check(`E.burst_size(32'h60000000 + 4*addr_i, 31'(left_value)) == want,
                      "burst_size overflow or boundary error");
            end
        $display("COUNTER RESULT: widths=%0d snapshots=%0d checks=%0d failures=%0d", widths, snapshots, checks, failures);
        if (failures) $fatal(1, "counter audit failed");
        $finish;
    end
    `undef WIDTH
    `undef E
endmodule
