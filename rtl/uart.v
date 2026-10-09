module uart_tx #(parameter CLKS_PER_BIT = 234) (
    input wire clk, input wire reset, input wire start, input wire [7:0] data,
    output reg tx = 1, output reg busy = 0, output reg done = 0
);
    reg [15:0] timer = 0;
    reg [3:0] bit_index = 0;
    reg [9:0] frame = 10'h3ff;
    always @(posedge clk) begin
        done <= 0;
        if (reset) begin
            tx <= 1; busy <= 0; timer <= 0; bit_index <= 0;
        end else if (!busy) begin
            if (start) begin
                frame <= {1'b1, data, 1'b0};
                tx <= 0; timer <= CLKS_PER_BIT-1;
                bit_index <= 0; busy <= 1;
            end
        end else if (timer != 0) begin
            timer <= timer - 1'b1;
        end else if (bit_index == 9) begin
            tx <= 1; busy <= 0; done <= 1;
        end else begin
            bit_index <= bit_index + 1'b1;
            frame <= {1'b1, frame[9:1]};
            tx <= frame[1];
            timer <= CLKS_PER_BIT-1;
        end
    end
endmodule

module uart_rx #(parameter CLKS_PER_BIT = 234) (
    input wire clk, input wire reset, input wire rx,
    output reg [7:0] data = 0, output reg valid = 0
);
    reg sync1 = 1, sync2 = 1;
    reg [15:0] timer = 0;
    reg [3:0] bit_index = 0;
    reg [7:0] shift = 0;
    reg [1:0] state = 0;
    always @(posedge clk) begin
        sync1 <= rx; sync2 <= sync1; valid <= 0;
        if (reset) begin
            state <= 0; timer <= 0; bit_index <= 0;
        end else case (state)
            0: if (!sync2) begin
                timer <= CLKS_PER_BIT/2; state <= 1;
            end
            1: if (timer != 0) timer <= timer - 1'b1;
               else if (!sync2) begin
                   timer <= CLKS_PER_BIT-1; bit_index <= 0; state <= 2;
               end else state <= 0;
            2: if (timer != 0) timer <= timer - 1'b1;
               else begin
                   shift[bit_index] <= sync2;
                   timer <= CLKS_PER_BIT-1;
                   if (bit_index == 7) state <= 3;
                   else bit_index <= bit_index + 1'b1;
               end
            3: if (timer != 0) timer <= timer - 1'b1;
               else begin
                   if (sync2) begin data <= shift; valid <= 1; end
                   state <= 0;
               end
        endcase
    end
endmodule
