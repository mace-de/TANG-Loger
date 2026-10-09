module button #(parameter DEBOUNCE = 270000) (
    input wire clk, input wire reset, input wire pin_n,
    output reg pressed = 0
);
    reg sync1 = 1, sync2 = 1, stable = 1;
    reg [19:0] count = 0;
    always @(posedge clk) begin
        sync1 <= pin_n; sync2 <= sync1; pressed <= 0;
        if (reset) begin stable <= 1; count <= 0; end
        else if (sync2 == stable) count <= 0;
        else if (count == DEBOUNCE-1) begin
            stable <= sync2; count <= 0;
            if (!sync2) pressed <= 1;
        end else count <= count + 1'b1;
    end
endmodule
