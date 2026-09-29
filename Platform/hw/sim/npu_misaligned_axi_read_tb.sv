`timescale 1ns / 1ps

module npu_misaligned_axi_read_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg [31:0] rs1_i = 32'd0;
    reg [31:0] rs2_i = 32'd0;
    reg NPU_start = 1'b0;
    wire [31:0] NPU_out;
    wire NPU_done;
    reg [3:0] funct3_i = 4'b0001;
    reg [31:0] funct7_i = 32'd0;

    wire [31:0] M_AXI_ARADDR;
    wire M_AXI_ARVALID;
    reg M_AXI_ARREADY = 1'b0;
    reg [31:0] M_AXI_RDATA = 32'd0;
    reg M_AXI_RVALID = 1'b0;
    wire M_AXI_RREADY;

    integer failures = 0;
    integer ar_count = 0;
    reg [31:0] observed_araddr [0:7];

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
        .M_AXI_ARVALID(M_AXI_ARVALID),
        .M_AXI_ARREADY(M_AXI_ARREADY),
        .M_AXI_RID(4'b0000),
        .M_AXI_RDATA(M_AXI_RDATA),
        .M_AXI_RRESP(2'b00),
        .M_AXI_RLAST(1'b1),
        .M_AXI_RVALID(M_AXI_RVALID),
        .M_AXI_RREADY(M_AXI_RREADY)
    );

    always @(posedge clk) begin
        if (rst_n && M_AXI_ARVALID && M_AXI_ARREADY) begin
            observed_araddr[ar_count] <= M_AXI_ARADDR;
            ar_count <= ar_count + 1;
        end
    end

    task fail(input [8*96-1:0] message);
        begin
            failures = failures + 1;
            $display("[FAIL] %0s", message);
        end
    endtask

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
            M_AXI_ARREADY = 1'b0;
            M_AXI_RVALID = 1'b0;
            ar_count = 0;
            repeat (3) tick();
            rst_n = 1'b1;
            tick();
        end
    endtask

    task accept_read(input [31:0] expected_address, input [31:0] word_data);
        integer stall_cycles;
        reg [31:0] stalled_address;
        reg [31:0] held_output;
        begin
            stall_cycles = 0;
            while (!M_AXI_ARVALID && !NPU_done && stall_cycles < 20) begin
                tick();
                stall_cycles = stall_cycles + 1;
            end
            if (!M_AXI_ARVALID) begin
                if (NPU_done) begin
                    fail("NPU_done asserted before the required read was complete");
                end else begin
                    fail("timed out waiting for ARVALID");
                end
            end else begin
                stalled_address = M_AXI_ARADDR;
                if (stalled_address !== expected_address) begin
                    $display("[FAIL] ARADDR=0x%08x expected aligned address=0x%08x",
                             stalled_address, expected_address);
                    failures = failures + 1;
                end
                repeat (3) begin
                    tick();
                    if (!M_AXI_ARVALID || M_AXI_ARADDR !== stalled_address) begin
                        fail("ARVALID/ARADDR changed before ARREADY handshake");
                    end
                    if (NPU_done) begin
                        fail("NPU_done asserted while an AXI read address was pending");
                    end
                end
                M_AXI_ARREADY = 1'b1;
                tick();
                M_AXI_ARREADY = 1'b0;
                if (M_AXI_ARVALID) begin
                    fail("ARVALID remained asserted after ARREADY handshake");
                end

                held_output = NPU_out;
                repeat (2) begin
                    tick();
                    if (NPU_out !== held_output) begin
                        fail("read data was accepted before RVALID");
                    end
                    if (NPU_done) begin
                        fail("NPU_done asserted before an RVALID/RREADY handshake");
                    end
                end

                M_AXI_RDATA = word_data;
                M_AXI_RVALID = 1'b1;
                stall_cycles = 0;
                while (!M_AXI_RREADY && stall_cycles < 20) begin
                    tick();
                    stall_cycles = stall_cycles + 1;
                end
                if (!M_AXI_RREADY) begin
                    fail("timed out waiting for RREADY");
                    M_AXI_RVALID = 1'b0;
                end else begin
                    tick();
                    M_AXI_RVALID = 1'b0;
                    if (NPU_done) begin
                        fail("NPU_done asserted in the same cycle as the read-data handshake");
                    end
                end
            end
        end
    endtask

    task check_offset(input integer offset);
        reg [31:0] expected;
        reg [31:0] base_address;
        integer expected_reads;
        begin
            base_address = 32'h60000000;
            case (offset)
                0: expected = 32'h44332211;
                1: expected = 32'h55443322;
                2: expected = 32'h66554433;
                3: expected = 32'h77665544;
                default: expected = 32'd0;
            endcase
            expected_reads = (offset == 0) ? 1 : 2;
            reset_dut();
            rs1_i = base_address + offset;
            NPU_start = 1'b1;
            tick();
            NPU_start = 1'b0;

            accept_read(base_address, 32'h44332211);
            if (offset != 0) begin
                accept_read(base_address + 4, 32'h88776655);
            end

            if (!NPU_done) begin
                tick();
            end
            if (!NPU_done) begin
                fail("NPU_done did not assert after the full read result");
            end
            if (NPU_out !== expected) begin
                $display("[FAIL] Read offset=%0d returned 0x%08x expected 0x%08x",
                         offset, NPU_out, expected);
                failures = failures + 1;
            end else begin
                $display("[PASS] Read reconstruction offset=%0d value=0x%08x",
                         offset, NPU_out);
            end
            if (ar_count != expected_reads) begin
                $display("[FAIL] Read offset=%0d issued %0d aligned reads; expected %0d",
                         offset, ar_count, expected_reads);
                failures = failures + 1;
            end
            if (ar_count > 0 && observed_araddr[0] !== base_address) begin
                fail("first physical read address was not aligned_base");
            end
            if (expected_reads == 2 && observed_araddr[1] !== base_address + 4) begin
                fail("second physical read address was not next_word");
            end
        end
    endtask

    initial begin
        check_offset(0);
        check_offset(1);
        check_offset(2);
        check_offset(3);
        if (failures == 0) begin
            $display("[PASS] All aligned/misaligned AXI read reconstruction checks");
            $finish;
        end else begin
            $display("[FAIL] %0d read reconstruction check(s)", failures);
            $fatal(1);
        end
    end
endmodule
