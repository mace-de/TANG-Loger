`timescale 1ns/1ps
module templog_tb;
    reg clk=0, s1_n=1, s2_n=1, rx=1;
    always #18 clk=~clk;
    wire tx, thermo_clk, thermo_cs_n, sd_mosi, sd_sck, sd_cs_n;
    wire led_run_n, led_error_n;
    templog #(.CLK_HZ(5000), .UART_DIV(9), .DEBOUNCE_CYCLES(5)) dut(
        .clk27(clk), .s1_n(s1_n), .s2_n(s2_n),
        .thermo_do(1'b0), .thermo_clk(thermo_clk),
        .thermo_cs_n(thermo_cs_n), .sd_miso(1'b1),
        .sd_mosi(sd_mosi), .sd_sck(sd_sck), .sd_cs_n(sd_cs_n),
        .uart_rx_pin(rx), .uart_tx_pin(tx),
        .led_run_n(led_run_n), .led_error_n(led_error_n));
    reg reset_rx=1;
    wire [7:0] tx_decoded;
    wire tx_valid;
    uart_rx #(.CLKS_PER_BIT(9)) decoder(
        .clk(clk), .reset(reset_rx), .rx(tx),
        .data(tx_decoded), .valid(tx_valid));
    reg [7:0] output_bytes[0:127];
    integer output_count=0;
    always @(posedge clk) if(tx_valid) begin
        output_bytes[output_count]=tx_decoded;
        output_count=output_count+1;
    end
    task send_byte(input [7:0] value);
        integer i;
        begin
            rx=0; repeat(9) @(negedge clk);
            for(i=0;i<8;i=i+1) begin
                rx=value[i]; repeat(9) @(negedge clk);
            end
            rx=1; repeat(9) @(negedge clk);
        end
    endtask
    initial begin
        repeat(20) @(negedge clk); reset_rx=0;
        wait(dut.state==6); // UNFORMATTED
        send_byte("F"); send_byte("!");
        send_byte(8'h78); send_byte(8'h56);
        send_byte(8'h34); send_byte(8'h12);
        wait(dut.state==7); // READY
        if(dut.generation!==32'h12345678) $fatal(1,"format nonce lost");
        s1_n=0; repeat(12) @(negedge clk); s1_n=1;
        wait(dut.logging);
        wait(dut.count==2);
        s2_n=0; repeat(12) @(negedge clk); s2_n=1;
        wait(!dut.logging);
        wait(dut.state==7 && dut.checkpoint_count==2);
        send_byte("D");
        wait(output_count==68); // 12-byte header + two 28-byte records
        if ({output_bytes[0],output_bytes[1],output_bytes[2],output_bytes[3]} !== "TLOG")
            $fatal(1,"bad export header");
        if(output_bytes[4]!==2 || output_bytes[12]!=="T" ||
           output_bytes[40]!=="T") $fatal(1,"bad export records");
        wait(dut.state==7);
        s1_n=0; repeat(12) @(negedge clk); s1_n=1;
        wait(dut.count==3);
        force dut.reset=1'b1;
        repeat(5) @(negedge clk);
        release dut.reset;
        wait(dut.state==7);
        if(dut.count!==3) $fatal(1,"restart did not recover third record");
        send_byte("C"); send_byte("!");
        send_byte(8'hef); send_byte(8'hcd);
        send_byte(8'hab); send_byte(8'h89);
        wait(dut.state==11); // first checkpoint write in progress
        wait(dut.state==7);
        if(dut.count!==0 || dut.session!==0 || dut.generation!==32'h89abcdef)
            $fatal(1,"clear did not reset the log");
        force dut.reset=1'b1;
        repeat(5) @(negedge clk);
        release dut.reset;
        wait(dut.state==7);
        if(dut.count!==0) $fatal(1,"old records reappeared after clear/restart");
        s1_n=0; repeat(12) @(negedge clk); s1_n=1;
        wait(dut.count==1);
        s2_n=0; repeat(12) @(negedge clk); s2_n=1;
        wait(dut.state==7 && !dut.logging && dut.checkpoint_count==1);
        if(dut.session!==1) $fatal(1,"new session after clear is not one");
        $display("Top: format, buttons, samples, checkpoint, export, restart, clear OK");
        $finish;
    end
    initial begin #100000000; $fatal(1,"top timeout"); end
endmodule
