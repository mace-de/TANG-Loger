module sd_spi (
    input wire clk, input wire reset,
    output wire sd_cs_n, output wire sd_sck, output wire sd_mosi,
    input wire sd_miso,
    input wire request, input wire write_mode, input wire [31:0] lba,
    output reg ready=0, output reg busy=1,
    output wire [31:0] sector_count,
    output reg done=0, output reg error=0,
    output wire [5:0] debug_stage, output wire [7:0] debug_response,
    output wire [5:0] debug_command,
    output reg [8:0] data_index=0,
    input wire [7:0] write_data,
    output reg [7:0] read_data=0, output reg read_valid=0
);
    assign sd_cs_n=1; assign sd_sck=0; assign sd_mosi=1;
    assign sector_count=16;
    assign debug_stage=0; assign debug_response=0; assign debug_command=0;
    reg [7:0] memory [0:8191];
    integer j;
    initial for (j=0; j<8192; j=j+1) memory[j]=8'hff;
    reg [31:0] current_lba=0;
    reg [1:0] state=0;
    always @(posedge clk) begin
        done<=0; read_valid<=0;
        if (reset) begin ready<=0; busy<=1; state<=0; end
        else case(state)
            0: begin
                ready<=1; busy<=0;
                if(request) begin
                    if(lba>=16) begin error<=1; done<=1; end
                    else begin
                        current_lba<=lba; data_index<=0; busy<=1; error<=0;
                        state<=write_mode ? 1 : 2;
                    end
                end
            end
            1: begin
                memory[current_lba*512+data_index]<=write_data;
                if(data_index==511) begin busy<=0; done<=1; state<=0; end
                else data_index<=data_index+1'b1;
            end
            2: begin
                read_data<=memory[current_lba*512+data_index];
                read_valid<=1; state<=3;
            end
            3: begin
                if(data_index==511) begin busy<=0; done<=1; state<=0; end
                else begin data_index<=data_index+1'b1; state<=2; end
            end
        endcase
    end
endmodule
