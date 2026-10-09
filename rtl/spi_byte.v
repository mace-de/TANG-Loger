// SPI mode 0, one byte per request. CLK_HZ/(2*DIV) is the bus clock.
module spi_byte (
    input wire clk, input wire reset,
    input wire [15:0] divisor,
    input wire start, input wire [7:0] tx_data,
    input wire miso, output reg mosi = 1'b1,
    output reg sck = 1'b0, output reg [7:0] rx_data = 0,
    output reg busy = 0, output reg done = 0
);
    reg [15:0] div_count = 0;
    reg [3:0] edges = 0;
    reg [7:0] rx_shift = 0;
    reg [7:0] tx_shift = 0;
    always @(posedge clk) begin
        done <= 0;
        if (reset) begin
            busy <= 0; sck <= 0; mosi <= 1;
            div_count <= 0; edges <= 0; rx_data <= 0;
        end else if (!busy) begin
            sck <= 0;
            if (start) begin
                busy <= 1; div_count <= divisor-1'b1; edges <= 0;
                tx_shift <= tx_data; rx_shift <= 0; mosi <= tx_data[7];
            end
        end else if (div_count != 0) begin
            div_count <= div_count - 1'b1;
        end else begin
            div_count <= divisor-1'b1;
            if (!sck) begin
                sck <= 1;
                rx_shift <= {rx_shift[6:0], miso};
            end else begin
                sck <= 0;
                edges <= edges + 1'b1;
                tx_shift <= {tx_shift[6:0], 1'b1};
                mosi <= tx_shift[6];
                if (edges == 7) begin
                    busy <= 0; done <= 1;
                    rx_data <= rx_shift;
                    mosi <= 1;
                end
            end
        end
    end
endmodule
