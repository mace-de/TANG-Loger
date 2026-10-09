// CS low latches the most significant bit. Data changes on falling SCK;
// sample on rising SCK. 1 MHz SCK from the 27 MHz board oscillator.
module max31855_reader #(parameter HALF_PERIOD = 14) (
    input wire clk, input wire reset, input wire start, input wire so,
    output reg cs_n = 1, output reg sck = 0,
    output reg [31:0] data = 0,
    output reg busy = 0, output reg done = 0
);
    reg [15:0] divider = 0;
    reg [5:0] bit_count = 0;
    reg [31:0] shift = 0;
    reg [1:0] phase = 0;
    always @(posedge clk) begin
        done <= 0;
        if (reset) begin
            cs_n <= 1; sck <= 0; busy <= 0;
            divider <= 0; bit_count <= 0; phase <= 0;
        end else if (!busy) begin
            if (start) begin
                cs_n <= 0; sck <= 0; busy <= 1;
                divider <= HALF_PERIOD-1; bit_count <= 0;
                shift <= 0; phase <= 0;
            end
        end else if (divider != 0) begin
            divider <= divider - 1'b1;
        end else begin
            divider <= HALF_PERIOD-1;
            case (phase)
                0: phase <= 1; // CS setup time
                1: begin
                    sck <= 1;
                    shift <= {shift[30:0], so};
                    phase <= 2;
                end
                2: begin
                    sck <= 0;
                    if (bit_count == 31) begin
                        data <= shift; cs_n <= 1; busy <= 0; done <= 1;
                    end else begin
                        bit_count <= bit_count + 1'b1; phase <= 1;
                    end
                end
            endcase
        end
    end
endmodule
