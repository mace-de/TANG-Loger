`timescale 1ns/1ps
module max31855_tb;
    reg clk=0, reset=1, start=0;
    always #18 clk=~clk;
    reg so=0;
    wire cs_n, sck, busy, done;
    wire [31:0] data;
    reg [31:0] frame=32'hc1900001;
    integer index=31;
    max31855_reader #(.HALF_PERIOD(3)) dut(
        .clk(clk), .reset(reset), .start(start), .so(so),
        .cs_n(cs_n), .sck(sck), .data(data), .busy(busy), .done(done));
    always @(negedge cs_n) begin index=31; so=frame[31]; end
    always @(negedge sck) if (!cs_n) begin
        index=index-1;
        if (index>=0) so=frame[index];
    end
    initial begin
        repeat (5) @(negedge clk); reset=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        wait(done);
        if (data !== frame) begin
            $display("MAX31855 bits wrong: got %h expected %h", data, frame); $fatal;
        end
        $display("MAX31855 32-bit read OK"); $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
