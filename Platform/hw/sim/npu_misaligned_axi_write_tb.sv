`timescale 1ns / 1ps

module npu_misaligned_axi_write_tb;
    localparam [31:0] BASE_ADDR = 32'h60000100;
    localparam integer BASE_MEMORY_INDEX = 1;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg [31:0] rs1_i = 32'd0;
    reg [31:0] rs2_i = 32'd0;
    reg NPU_start = 1'b0;
    wire [31:0] NPU_out;
    wire NPU_done;
    reg [3:0] funct3_i = 4'b0010;
    reg [31:0] funct7_i = 32'd0;

    wire [31:0] M_AXI_AWADDR;
    wire M_AXI_AWVALID;
    reg M_AXI_AWREADY = 1'b0;
    wire [31:0] M_AXI_WDATA;
    wire [3:0] M_AXI_WSTRB;
    wire M_AXI_WLAST;
    wire M_AXI_WVALID;
    reg M_AXI_WREADY = 1'b0;
    reg [1:0] M_AXI_BRESP = 2'b00;
    reg M_AXI_BVALID = 1'b0;
    wire M_AXI_BREADY;

    integer failures = 0;
    integer aw_count = 0;
    integer w_count = 0;
    integer b_count = 0;
    reg prev_aw_stalled = 1'b0;
    reg [31:0] prev_awaddr = 32'd0;
    reg prev_w_stalled = 1'b0;
    reg [31:0] prev_wdata = 32'd0;
    reg [3:0] prev_wstrb = 4'd0;
    reg prev_wlast = 1'b0;
    reg [31:0] observed_awaddr [0:7];
    reg [31:0] observed_wdata [0:7];
    reg [3:0] observed_wstrb [0:7];
    reg observed_wlast [0:7];
    reg [7:0] memory [0:8];
    reg [7:0] original_memory [0:8];

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
        .M_AXI_AWADDR(M_AXI_AWADDR),
        .M_AXI_AWVALID(M_AXI_AWVALID),
        .M_AXI_AWREADY(M_AXI_AWREADY),
        .M_AXI_WDATA(M_AXI_WDATA),
        .M_AXI_WSTRB(M_AXI_WSTRB),
        .M_AXI_WLAST(M_AXI_WLAST),
        .M_AXI_WVALID(M_AXI_WVALID),
        .M_AXI_WREADY(M_AXI_WREADY),
        .M_AXI_BRESP(M_AXI_BRESP),
        .M_AXI_BVALID(M_AXI_BVALID),
        .M_AXI_BREADY(M_AXI_BREADY),
        .M_AXI_ARREADY(1'b0),
        .M_AXI_RID(4'b0000),
        .M_AXI_RDATA(32'd0),
        .M_AXI_RRESP(2'b00),
        .M_AXI_RLAST(1'b1),
        .M_AXI_RVALID(1'b0)
    );

    task fail(input [8*160-1:0] message);
        begin
            failures = failures + 1;
            $display("[FAIL] %0s", message);
        end
    endtask

    // Observe actual AXI handshakes, and ensure each stalled channel retains
    // VALID and all of its payload until that channel is accepted.
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_count = 0;
            w_count = 0;
            b_count = 0;
            prev_aw_stalled = 1'b0;
            prev_awaddr = 32'd0;
            prev_w_stalled = 1'b0;
            prev_wdata = 32'd0;
            prev_wstrb = 4'd0;
            prev_wlast = 1'b0;
        end else begin
            if (prev_aw_stalled &&
                (!M_AXI_AWVALID || M_AXI_AWADDR !== prev_awaddr)) begin
                fail("AWVALID/AWADDR changed before AWREADY accepted the address");
            end
            if (prev_w_stalled &&
                (!M_AXI_WVALID || M_AXI_WDATA !== prev_wdata ||
                 M_AXI_WSTRB !== prev_wstrb || M_AXI_WLAST !== prev_wlast)) begin
                fail("W channel payload changed before WREADY accepted the data");
            end

            prev_aw_stalled = M_AXI_AWVALID && !M_AXI_AWREADY;
            prev_awaddr = M_AXI_AWADDR;
            prev_w_stalled = M_AXI_WVALID && !M_AXI_WREADY;
            prev_wdata = M_AXI_WDATA;
            prev_wstrb = M_AXI_WSTRB;
            prev_wlast = M_AXI_WLAST;

            if (M_AXI_AWVALID && M_AXI_AWREADY) begin
                observed_awaddr[aw_count] = M_AXI_AWADDR;
                aw_count = aw_count + 1;
            end
            if (M_AXI_WVALID && M_AXI_WREADY) begin
                observed_wdata[w_count] = M_AXI_WDATA;
                observed_wstrb[w_count] = M_AXI_WSTRB;
                observed_wlast[w_count] = M_AXI_WLAST;
                w_count = w_count + 1;
            end
            if (M_AXI_BVALID && M_AXI_BREADY) begin
                b_count = b_count + 1;
            end
        end
    end

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
            M_AXI_AWREADY = 1'b0;
            M_AXI_WREADY = 1'b0;
            M_AXI_BVALID = 1'b0;
            repeat (3) tick();
            @(negedge clk);
            rst_n = 1'b1;
            tick();
        end
    endtask

    task check_pending;
        begin
            if (NPU_done) begin
                fail("NPU_done asserted before all write channels and responses completed");
            end
        end
    endtask

    task initialize_memory;
        integer index;
        begin
            for (index = 0; index < 9; index = index + 1) begin
                original_memory[index] = 8'hA1 + (index * 8'h17);
                memory[index] = original_memory[index];
            end
        end
    endtask

    task apply_observed_write(input integer transaction_index);
        integer lane;
        integer memory_index;
        begin
            if (observed_awaddr[transaction_index][1:0] !== 2'b00) begin
                fail("observed physical AWADDR was not 4-byte aligned");
            end
            if (observed_awaddr[transaction_index] < BASE_ADDR ||
                observed_awaddr[transaction_index] > BASE_ADDR + 32'd4) begin
                fail("observed physical AWADDR was outside the two target words");
            end
            memory_index = BASE_MEMORY_INDEX +
                           (observed_awaddr[transaction_index] - BASE_ADDR);
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (observed_wstrb[transaction_index][lane]) begin
                    memory[memory_index + lane] =
                        observed_wdata[transaction_index][lane*8 +: 8];
                end
            end
        end
    endtask

    task perform_physical_write(
        input integer transaction_index,
        input integer transaction_count,
        input integer offset,
        input [31:0] value
    );
        reg [31:0] expected_address;
        reg [31:0] expected_data;
        reg [3:0] expected_strobe;
        integer wait_cycles;
        begin
            expected_address = BASE_ADDR + ((transaction_index == 0) ? 32'd0 : 32'd4);
            if (transaction_index == 0) begin
                expected_data = value << (offset * 8);
                expected_strobe = 4'hf << offset;
            end else begin
                expected_data = value >> ((4 - offset) * 8);
                expected_strobe = (4'b0001 << offset) - 4'b0001;
            end

            wait_cycles = 0;
            while ((!M_AXI_AWVALID || !M_AXI_WVALID) && wait_cycles < 20) begin
                tick();
                check_pending();
                wait_cycles = wait_cycles + 1;
            end
            if (!M_AXI_AWVALID || !M_AXI_WVALID) begin
                fail("timed out waiting for both AWVALID and WVALID");
            end else begin
                if (M_AXI_AWADDR !== expected_address) begin
                    $display("[FAIL] tx=%0d AWADDR=0x%08x expected=0x%08x",
                             transaction_index, M_AXI_AWADDR, expected_address);
                    failures = failures + 1;
                end
                if (M_AXI_AWADDR[1:0] !== 2'b00) begin
                    fail("AWADDR was misaligned while AWVALID was asserted");
                end
                if (M_AXI_WDATA !== expected_data || M_AXI_WSTRB !== expected_strobe) begin
                    $display("[FAIL] tx=%0d WDATA=0x%08x WSTRB=%b expected WDATA=0x%08x WSTRB=%b",
                             transaction_index, M_AXI_WDATA, M_AXI_WSTRB,
                             expected_data, expected_strobe);
                    failures = failures + 1;
                end
                if (M_AXI_WLAST !== 1'b1) begin
                    fail("single-beat write did not assert WLAST");
                end

                // Stall both channels together, then accept only one channel at
                // a time. Alternate which channel goes first for the second word.
                repeat (2) begin
                    tick();
                    check_pending();
                    if (!M_AXI_AWVALID || M_AXI_AWADDR !== expected_address) begin
                        fail("AW channel did not hold its address during the initial stall");
                    end
                    if (!M_AXI_WVALID || M_AXI_WDATA !== expected_data ||
                        M_AXI_WSTRB !== expected_strobe || !M_AXI_WLAST) begin
                        fail("W channel did not hold its payload during the initial stall");
                    end
                end

                if ((transaction_index % 2) == 0) begin
                    @(negedge clk);
                    M_AXI_AWREADY = 1'b1;
                    tick();
                    check_pending();
                    @(negedge clk);
                    M_AXI_AWREADY = 1'b0;
                    if (M_AXI_AWVALID || !M_AXI_WVALID) begin
                        fail("AW handshake incorrectly completed or dropped the pending W channel");
                    end
                    if (M_AXI_BREADY) begin
                        fail("BREADY asserted before the independent W handshake completed");
                    end
                    repeat (2) begin
                        tick();
                        check_pending();
                        if (!M_AXI_WVALID || M_AXI_WDATA !== expected_data ||
                            M_AXI_WSTRB !== expected_strobe || !M_AXI_WLAST) begin
                            fail("W channel changed while AW had completed and W was stalled");
                        end
                    end
                    @(negedge clk);
                    M_AXI_WREADY = 1'b1;
                    tick();
                    check_pending();
                    @(negedge clk);
                    M_AXI_WREADY = 1'b0;
                end else begin
                    @(negedge clk);
                    M_AXI_WREADY = 1'b1;
                    tick();
                    check_pending();
                    @(negedge clk);
                    M_AXI_WREADY = 1'b0;
                    if (!M_AXI_AWVALID || M_AXI_WVALID) begin
                        fail("W handshake incorrectly completed or dropped the pending AW channel");
                    end
                    if (M_AXI_BREADY) begin
                        fail("BREADY asserted before the independent AW handshake completed");
                    end
                    repeat (2) begin
                        tick();
                        check_pending();
                        if (!M_AXI_AWVALID || M_AXI_AWADDR !== expected_address) begin
                            fail("AW channel changed while W had completed and AW was stalled");
                        end
                    end
                    @(negedge clk);
                    M_AXI_AWREADY = 1'b1;
                    tick();
                    check_pending();
                    @(negedge clk);
                    M_AXI_AWREADY = 1'b0;
                end

                if (aw_count != transaction_index + 1 ||
                    w_count != transaction_index + 1) begin
                    fail("observed AW/W handshake count did not match physical write progress");
                end
                if (observed_awaddr[transaction_index] !== expected_address) begin
                    fail("accepted AW address differed from the expected aligned word");
                end
                if (observed_wdata[transaction_index] !== expected_data ||
                    observed_wstrb[transaction_index] !== expected_strobe) begin
                    fail("accepted WDATA/WSTRB differed from expected byte placement");
                end
                if (observed_wlast[transaction_index] !== 1'b1) begin
                    fail("accepted physical write did not have WLAST asserted");
                end
                apply_observed_write(transaction_index);

                if (!M_AXI_BREADY) begin
                    fail("NPU did not wait in write-response state after AW and W handshakes");
                end
                repeat (2) begin
                    tick();
                    check_pending();
                    if (!M_AXI_BREADY) begin
                        fail("BREADY dropped before the physical write response arrived");
                    end
                    if (M_AXI_AWVALID || M_AXI_WVALID) begin
                        fail("another physical write was launched before the B response");
                    end
                end
                if (b_count != transaction_index) begin
                    fail("physical write advanced without accepting its B response");
                end

                @(negedge clk);
                M_AXI_BVALID = 1'b1;
                tick();
                @(negedge clk);
                M_AXI_BVALID = 1'b0;
                if (b_count != transaction_index + 1) begin
                    fail("write response was not accepted with BVALID && BREADY");
                end
                check_pending();
                if (M_AXI_BREADY) begin
                    fail("BREADY remained active after its write response was accepted");
                end

                if (transaction_index + 1 < transaction_count) begin
                    if (!M_AXI_AWVALID || !M_AXI_WVALID) begin
                        fail("second physical write did not start after the first B response");
                    end
                end else begin
                    if (M_AXI_AWVALID || M_AXI_WVALID) begin
                        fail("write channel remained active after the final B response");
                    end
                    tick();
                    if (!NPU_done) begin
                        fail("NPU_done did not assert after the final write response");
                    end
                end
            end
        end
    endtask

    task check_memory(input integer offset, input [31:0] value);
        integer index;
        integer target_index;
        reg [7:0] expected_byte;
        begin
            target_index = BASE_MEMORY_INDEX + offset;
            for (index = 0; index < 9; index = index + 1) begin
                if (index >= target_index && index < target_index + 4) begin
                    expected_byte = (value >> ((index - target_index) * 8)) & 8'hff;
                end else begin
                    expected_byte = original_memory[index];
                end
                if (memory[index] !== expected_byte) begin
                    $display("[FAIL] offset=%0d memory[%0d]=0x%02x expected=0x%02x",
                             offset, index, memory[index], expected_byte);
                    failures = failures + 1;
                end
            end
        end
    endtask

    task check_offset(input integer offset, input [31:0] value);
        integer transaction_count;
        integer transaction_index;
        begin
            reset_dut();
            initialize_memory();
            transaction_count = (offset == 0) ? 1 : 2;

            @(negedge clk);
            rs1_i = BASE_ADDR + offset;
            rs2_i = value;
            funct3_i = 4'b0010;
            NPU_start = 1'b1;
            tick();
            check_pending();
            @(negedge clk);
            NPU_start = 1'b0;

            for (transaction_index = 0;
                 transaction_index < transaction_count;
                 transaction_index = transaction_index + 1) begin
                perform_physical_write(transaction_index, transaction_count, offset, value);
            end

            if (aw_count != transaction_count || w_count != transaction_count ||
                b_count != transaction_count) begin
                $display("[FAIL] offset=%0d completed AW/W/B counts=%0d/%0d/%0d expected=%0d",
                         offset, aw_count, w_count, b_count, transaction_count);
                failures = failures + 1;
            end
            if (!NPU_done) begin
                fail("logical write completed without NPU_done");
            end
            check_memory(offset, value);

            repeat (2) begin
                tick();
                if (M_AXI_AWVALID || M_AXI_WVALID) begin
                    fail("unexpected extra physical write after logical completion");
                end
            end
            if (aw_count != transaction_count || w_count != transaction_count ||
                b_count != transaction_count) begin
                fail("extra AXI write handshake occurred after logical completion");
            end
            $display("[PASS] offset=%0d value=0x%08x physical_writes=%0d",
                     offset, value, transaction_count);
        end
    endtask

    initial begin
        check_offset(0, 32'h12345678);
        check_offset(1, 32'h12345678);
        check_offset(2, 32'h12345678);
        check_offset(3, 32'h12345678);
        check_offset(0, 32'hA5C37E19);
        check_offset(1, 32'hA5C37E19);
        check_offset(2, 32'hA5C37E19);
        check_offset(3, 32'hA5C37E19);

        if (failures == 0) begin
            $display("[PASS] All aligned/misaligned AXI write byte-placement and handshake checks");
            $finish;
        end else begin
            $display("[FAIL] %0d AXI write check(s)", failures);
            $fatal(1);
        end
    end
endmodule
