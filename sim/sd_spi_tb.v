`timescale 1ns/1ps
module sd_spi_tb;
    parameter OLD_CARD = 0;
    reg clk = 0, reset = 1, request = 0, write_mode = 0;
    always #18 clk = ~clk;
    reg miso = 1;
    wire mosi, sck, cs_n, ready, busy, done, error, read_valid;
    wire [31:0] sector_count;
    wire [8:0] data_index;
    wire [7:0] read_data;
    reg [31:0] lba = 12;
    wire [7:0] write_data = data_index[7:0] ^ 8'h5a;
    sd_spi dut(.clk(clk), .reset(reset), .sd_cs_n(cs_n), .sd_sck(sck),
        .sd_mosi(mosi), .sd_miso(miso), .request(request),
        .write_mode(write_mode), .lba(lba), .ready(ready), .busy(busy),
        .done(done), .error(error), .sector_count(sector_count),
        .data_index(data_index), .write_data(write_data),
        .read_data(read_data), .read_valid(read_valid));

    reg [7:0] queue [0:4095];
    integer head = 0, tail = 0;
    reg [7:0] outbound = 8'hff;
    reg [7:0] inbound = 0;
    reg [2:0] bit_index = 0;
    reg [47:0] command = 0;
    integer command_bytes = 0;
    integer write_phase = 0, data_bytes = 0;
    integer writes = 0, reads = 0;
    integer seen_read_bytes = 0;
    reg [7:0] csd_byte [0:15];
    integer i;
    reg [31:0] arg;
    task enqueue(input [7:0] value);
        begin queue[tail] = value; tail = tail + 1; end
    endtask
    task process_byte(input [7:0] value);
        reg [5:0] command_number;
        begin
            if (write_phase != 0) begin
                if (write_phase == 1) begin
                    if (value == 8'hfe) begin write_phase = 2; data_bytes = 0; end
                end else if (write_phase == 2) begin
                    if (value !== (data_bytes[7:0] ^ 8'h5a)) begin
                        $display("bad write data at %0d: %h", data_bytes, value); $fatal;
                    end
                    data_bytes = data_bytes + 1;
                    if (data_bytes == 512) write_phase = 3;
                end else if (write_phase == 3) begin
                    data_bytes = data_bytes + 1;
                    if (data_bytes == 514) begin
                        write_phase = 0; writes = writes + 1;
                        enqueue(8'h05); enqueue(8'h00); enqueue(8'hff);
                    end
                end
            end else if (command_bytes != 0 || value[7:6] == 2'b01) begin
                command = {command[39:0], value};
                command_bytes = command_bytes + 1;
                if (command_bytes == 6) begin
                    command_bytes = 0;
                    command_number = command[45:40];
                    arg = command[39:8];
                    case (command_number)
                        0: enqueue(8'h01);
                        8: if (OLD_CARD) enqueue(8'h05);
                           else begin
                               enqueue(8'h01); enqueue(0); enqueue(0);
                               enqueue(8'h01); enqueue(8'haa);
                           end
                        55: enqueue(8'h01);
                        41: enqueue(8'h00);
                        58: begin
                            enqueue(8'h00); enqueue(OLD_CARD ? 8'h80 : 8'hc0);
                            enqueue(8'hff); enqueue(8'h80); enqueue(8'h00);
                        end
                        16: begin
                            if (!OLD_CARD || arg != 512) begin
                                $display("bad CMD16"); $fatal;
                            end
                            enqueue(8'h00);
                        end
                        9: begin
                            enqueue(8'h00); enqueue(8'hff); enqueue(8'hfe);
                            for (i=0; i<16; i=i+1) enqueue(csd_byte[i]);
                            enqueue(8'hff); enqueue(8'hff);
                        end
                        17: begin
                            if (arg != (OLD_CARD ? lba << 9 : lba)) begin
                                $display("bad LBA %h", arg); $fatal;
                            end
                            reads = reads + 1;
                            enqueue(8'h00); enqueue(8'hff); enqueue(8'hfe);
                            for (i=0; i<512; i=i+1) enqueue(i[7:0] ^ 8'h5a);
                            enqueue(8'hff); enqueue(8'hff);
                        end
                        24: begin
                            if (arg != (OLD_CARD ? lba << 9 : lba)) begin
                                $display("bad LBA %h", arg); $fatal;
                            end
                            enqueue(8'h00); write_phase = 1;
                        end
                        default: begin $display("unexpected CMD%0d",command_number); $fatal; end
                    endcase
                end
            end
        end
    endtask
    always @(posedge sck) if (!cs_n) begin
        inbound = {inbound[6:0], mosi};
        if (bit_index == 7) begin
            process_byte(inbound);
            bit_index = 0;
            if (head != tail) begin outbound = queue[head]; head = head + 1; end
            else outbound = 8'hff;
        end else bit_index = bit_index + 1'b1;
    end
    always @* miso = outbound[7-bit_index];
    always @(posedge clk) if (read_valid) begin
        if (read_data !== (data_index[7:0] ^ 8'h5a)) begin
            $display("bad read data at %0d: %h", data_index, read_data); $fatal;
        end
        seen_read_bytes = seen_read_bytes + 1;
    end
    initial begin
        for (i=0; i<16; i=i+1) csd_byte[i]=0;
        if (OLD_CARD) begin
            // CSD v1: READ_BL_LEN=9, C_SIZE=1023, C_SIZE_MULT=7.
            csd_byte[5]=8'h09; csd_byte[7]=8'hff;
            csd_byte[8]=8'hc0; csd_byte[9]=8'h03; csd_byte[10]=8'h80;
        end else begin
            // CSD v2 with C_SIZE = 1023: 1,048,576 sectors.
            csd_byte[0]=8'h40;
            csd_byte[7]=8'h00; csd_byte[8]=8'h03; csd_byte[9]=8'hff;
        end
        repeat (10) @(posedge clk);
        reset = 0;
        wait(ready);
        if (sector_count !== (OLD_CARD ? 32'd524288 : 32'd1048576)) begin
            $display("capacity wrong: %0d", sector_count); $fatal;
        end
        @(posedge clk); request = 1; write_mode = 1;
        @(posedge clk); request = 0;
        wait(done);
        if (error || writes != 1) begin $display("write failed"); $fatal; end
        repeat (3) @(posedge clk);
        request = 1; write_mode = 0;
        @(posedge clk); request = 0;
        wait(done);
        if (error || reads != 1 || seen_read_bytes != 512) begin
            $display("read failed: %d %d %d", error, reads, seen_read_bytes); $fatal;
        end
        if (OLD_CARD) $display("SDSC SPI read/write OK");
        else $display("SDHC SPI read/write OK");
        $finish;
    end
    initial begin #200000000; $display("timeout"); $fatal; end
endmodule
