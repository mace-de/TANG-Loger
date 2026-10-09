// SDSC/SDHC/SDXC SPI-mode block interface. One request transfers 512 bytes.
// Initialization uses 397 kHz; data transfers use 3.375 MHz.
module sd_spi (
    input wire clk, input wire reset,
    output reg sd_cs_n = 1, output wire sd_sck, output wire sd_mosi,
    input wire sd_miso,
    input wire request, input wire write_mode, input wire [31:0] lba,
    output reg ready = 0, output reg busy = 1,
    output reg [31:0] sector_count = 0,
    output reg done = 0, output reg error = 0,
    output reg [5:0] debug_stage = 0,
    output reg [7:0] debug_response = 0,
    output reg [5:0] debug_command = 0,
    output reg [8:0] data_index = 0,
    input wire [7:0] write_data,
    output reg [7:0] read_data = 0, output reg read_valid = 0
);
    reg spi_start = 0;
    reg [7:0] spi_tx = 8'hff;
    wire [7:0] spi_rx;
    wire spi_done, spi_busy;
    spi_byte spi (
        .clk(clk), .reset(reset), .start(spi_start), .tx_data(spi_tx),
        .divisor(ready ? 16'd4 : 16'd34),
        .miso(sd_miso), .mosi(sd_mosi), .sck(sd_sck),
        .rx_data(spi_rx), .busy(spi_busy), .done(spi_done)
    );

    localparam X_START=0, X_WAIT=1, DUMMY=2, DUMMY_NEXT=3,
      CMD_SETUP=4, CMD_BYTE=5, CMD_NEXT=6, CMD_POLL=7, CMD_CHECK=8,
      INIT0=9, INIT8=10, INIT8_EXTRA=11, INIT8_CHECK=12,
      INIT55=13, INIT41=14, INIT58=15, INIT58_EXTRA=16,
      IDLE=17, READ_TOKEN=18, READ_TOKEN_CHECK=19,
      READ_BYTE=20, READ_NEXT=21, READ_CRC=22, READ_FINISH=23,
      WRITE_GAP=24, WRITE_TOKEN=25, WRITE_BYTE=26, WRITE_NEXT=27,
      WRITE_CRC=28, WRITE_RESPONSE=29, WRITE_RESPONSE_CHECK=30,
      WRITE_BUSY=31, WRITE_BUSY_CHECK=32, FINISH=33, FAIL=34,
      INIT58_CHECK=35, INIT16=36, INIT9=37, CSD_TOKEN=38,
      CSD_TOKEN_CHECK=39, CSD_BYTE=40, CSD_NEXT=41,
      CSD_CRC=42, CSD_FINISH=43, READ_ADVANCE=44,
      CMD_GAP=45, CMD_ASSERT=46;
    reg [5:0] state = DUMMY;
    reg [5:0] prior_state = DUMMY;
    reg [5:0] return_state = DUMMY_NEXT;
    reg [5:0] cmd_return = INIT0;
    reg [7:0] rx_byte = 8'hff;
    reg [5:0] cmd = 0;
    reg [31:0] arg = 0;
    reg [7:0] cmd_crc = 8'h95;
    reg [2:0] cmd_index = 0;
    reg [4:0] response_tries = 0;
    reg [3:0] dummy_count = 0;
    reg [2:0] extra_count = 0;
    reg [7:0] ocr_first = 0;
    reg [15:0] init_tries = 0;
    reg [19:0] token_tries = 0;
    reg [19:0] busy_tries = 0;
    reg [1:0] crc_count = 0;
    reg op_write = 0;
    reg sd_v2 = 0;
    reg high_capacity = 0;
    reg [127:0] csd = 0;
    reg [4:0] csd_index = 0;
    wire [31:0] card_address = high_capacity ? lba : (lba << 9);

`define SEND(value, destination) begin spi_tx <= (value); return_state <= (destination); state <= X_START; end
`define COMMAND(number, argument, crcbyte, destination) begin \
    cmd <= (number); arg <= (argument); cmd_crc <= (crcbyte); \
    cmd_return <= (destination); state <= CMD_SETUP; end

    always @(posedge clk) begin
        prior_state <= state;
        spi_start <= 0; done <= 0; read_valid <= 0;
        if (reset) begin
            sd_cs_n <= 1; ready <= 0; busy <= 1; error <= 0;
            state <= DUMMY; dummy_count <= 0; init_tries <= 0;
            sd_v2 <= 0; high_capacity <= 0; sector_count <= 0;
            spi_start <= 0;
        end else case (state)
            X_START: begin spi_start <= 1; state <= X_WAIT; end
            X_WAIT: if (spi_done) begin rx_byte <= spi_rx; state <= return_state; end
            DUMMY: `SEND(8'hff, DUMMY_NEXT)
            DUMMY_NEXT: if (dummy_count == 9) begin
                sd_cs_n <= 0; `COMMAND(0, 32'd0, 8'h95, INIT0)
            end else begin dummy_count <= dummy_count + 1'b1; state <= DUMMY; end
            CMD_SETUP: begin sd_cs_n <= 1; state <= CMD_GAP; end
            CMD_GAP: `SEND(8'hff, CMD_ASSERT)
            CMD_ASSERT: begin
                sd_cs_n <= 0; cmd_index <= 0; response_tries <= 0;
                state <= CMD_BYTE;
            end
            CMD_BYTE: case (cmd_index)
                0: `SEND({2'b01,cmd}, CMD_NEXT)
                1: `SEND(arg[31:24], CMD_NEXT)
                2: `SEND(arg[23:16], CMD_NEXT)
                3: `SEND(arg[15:8], CMD_NEXT)
                4: `SEND(arg[7:0], CMD_NEXT)
                5: `SEND(cmd_crc, CMD_NEXT)
            endcase
            CMD_NEXT: if (cmd_index == 5) state <= CMD_POLL;
                      else begin cmd_index <= cmd_index + 1'b1; state <= CMD_BYTE; end
            CMD_POLL: `SEND(8'hff, CMD_CHECK)
            CMD_CHECK: if (!rx_byte[7]) state <= cmd_return;
                       else if (response_tries == 31) state <= FAIL;
                       else begin response_tries <= response_tries + 1'b1; state <= CMD_POLL; end
            INIT0: if (rx_byte == 8'h01)
                       `COMMAND(8, 32'h000001aa, 8'h87, INIT8)
                   else state <= FAIL;
            INIT8: if (rx_byte == 8'h01) begin
                       sd_v2 <= 1; extra_count <= 0; state <= INIT8_EXTRA;
                   end else if (rx_byte == 8'h05)
                       `COMMAND(55, 32'd0, 8'hff, INIT55)
                   else state <= FAIL;
            INIT8_EXTRA: `SEND(8'hff, INIT8_CHECK)
            INIT8_CHECK: if (extra_count == 3) begin
                            if (rx_byte == 8'haa) `COMMAND(55, 32'd0, 8'hff, INIT55)
                            else state <= FAIL;
                         end else begin extra_count <= extra_count + 1'b1; state <= INIT8_EXTRA; end
            INIT55: if (rx_byte == 8'h01 || rx_byte == 8'h00)
                        `COMMAND(41, sd_v2 ? 32'h40000000 : 32'd0, 8'hff, INIT41)
                    else state <= FAIL;
            INIT41: if (rx_byte == 8'h00)
                        `COMMAND(58, 32'd0, 8'hff, INIT58)
                    else if (rx_byte == 8'h01 && init_tries != 16'hffff) begin
                        init_tries <= init_tries + 1'b1;
                        `COMMAND(55, 32'd0, 8'hff, INIT55)
                    end else state <= FAIL;
            INIT58: if (rx_byte == 8'h00) begin extra_count <= 0; state <= INIT58_EXTRA; end
                    else state <= FAIL;
            INIT58_EXTRA: `SEND(8'hff, INIT58_CHECK)
            INIT58_CHECK: if (extra_count == 0) begin
                              ocr_first <= rx_byte;
                              high_capacity <= rx_byte[6];
                              extra_count <= 1; state <= INIT58_EXTRA;
                          end else if (extra_count == 3) begin
                              if (high_capacity) `COMMAND(9, 32'd0, 8'hff, INIT9)
                              else `COMMAND(16, 32'd512, 8'hff, INIT16)
                          end else begin extra_count <= extra_count + 1'b1; state <= INIT58_EXTRA; end
            INIT16: if (rx_byte == 8'h00)
                        `COMMAND(9, 32'd0, 8'hff, INIT9)
                    else state <= FAIL;
            INIT9: if (rx_byte == 8'h00) begin token_tries <= 0; state <= CSD_TOKEN; end
                   else state <= FAIL;
            CSD_TOKEN: begin token_tries <= token_tries + 1'b1; `SEND(8'hff, CSD_TOKEN_CHECK) end
            CSD_TOKEN_CHECK: if (rx_byte == 8'hfe) begin csd_index <= 0; csd <= 0; state <= CSD_BYTE; end
                             else if (token_tries == 20'hfffff || rx_byte != 8'hff) state <= FAIL;
                             else state <= CSD_TOKEN;
            CSD_BYTE: `SEND(8'hff, CSD_NEXT)
            CSD_NEXT: begin
                csd <= {csd[119:0], rx_byte};
                if (csd_index == 15) begin crc_count <= 0; state <= CSD_CRC; end
                else begin csd_index <= csd_index + 1'b1; state <= CSD_BYTE; end
            end
            CSD_CRC: `SEND(8'hff, CSD_FINISH)
            CSD_FINISH: if (crc_count == 0) begin crc_count <= 1; state <= CSD_CRC; end
                        else if (csd[127:126] == 2'b01) begin
                            sector_count <= ({10'd0, csd[69:48]} + 1'b1) << 10;
                            sd_cs_n <= 1; ready <= 1; busy <= 0; state <= IDLE;
                        end else if (csd[127:126] == 2'b00 && csd[83:80] >= 9) begin
                            sector_count <= ({20'd0, csd[73:62]} + 1'b1) <<
                                            (csd[49:47] + csd[83:80] - 7);
                            sd_cs_n <= 1; ready <= 1; busy <= 0; state <= IDLE;
                        end else state <= FAIL;
            IDLE: if (request) begin
                sd_cs_n <= 0; busy <= 1; error <= 0; op_write <= write_mode;
                data_index <= 0; token_tries <= 0;
                if (write_mode) `COMMAND(24, card_address, 8'hff, WRITE_GAP)
                else `COMMAND(17, card_address, 8'hff, READ_TOKEN)
            end
            READ_TOKEN: begin token_tries <= token_tries + 1'b1; `SEND(8'hff, READ_TOKEN_CHECK) end
            READ_TOKEN_CHECK: if (rx_byte == 8'hfe) begin data_index <= 0; state <= READ_BYTE; end
                              else if (token_tries == 20'hfffff || rx_byte != 8'hff) state <= FAIL;
                              else state <= READ_TOKEN;
            READ_BYTE: `SEND(8'hff, READ_NEXT)
            READ_NEXT: begin
                read_data <= rx_byte; read_valid <= 1;
                if (data_index == 511) begin crc_count <= 0; state <= READ_CRC; end
                else state <= READ_ADVANCE;
            end
            READ_ADVANCE: begin data_index <= data_index + 1'b1; state <= READ_BYTE; end
            READ_CRC: `SEND(8'hff, READ_FINISH)
            READ_FINISH: if (crc_count == 1) state <= FINISH;
                         else begin crc_count <= 1; state <= READ_CRC; end
            WRITE_GAP: if (rx_byte == 8'h00) `SEND(8'hff, WRITE_TOKEN)
                       else state <= FAIL;
            WRITE_TOKEN: `SEND(8'hfe, WRITE_BYTE)
            WRITE_BYTE: `SEND(write_data, WRITE_NEXT)
            WRITE_NEXT: if (data_index == 511) begin crc_count <= 0; state <= WRITE_CRC; end
                        else begin data_index <= data_index + 1'b1; state <= WRITE_BYTE; end
            WRITE_CRC: `SEND(8'hff, WRITE_RESPONSE)
            WRITE_RESPONSE: if (crc_count == 0) begin crc_count <= 1; state <= WRITE_CRC; end
                            else `SEND(8'hff, WRITE_RESPONSE_CHECK)
            WRITE_RESPONSE_CHECK: if (rx_byte[4:0] == 5'b00101) begin busy_tries <= 0; state <= WRITE_BUSY; end
                                  else state <= FAIL;
            WRITE_BUSY: begin busy_tries <= busy_tries + 1'b1; `SEND(8'hff, WRITE_BUSY_CHECK) end
            WRITE_BUSY_CHECK: if (rx_byte == 8'hff) state <= FINISH;
                              else if (busy_tries == 20'hfffff) state <= FAIL;
                              else state <= WRITE_BUSY;
            FINISH: begin sd_cs_n <= 1; busy <= 0; done <= 1; state <= IDLE; end
            FAIL: begin
                debug_stage <= prior_state;
                debug_response <= rx_byte;
                debug_command <= cmd;
                sd_cs_n <= 1; busy <= 0; error <= 1; done <= 1; state <= IDLE;
            end
        endcase
    end
`undef SEND
`undef COMMAND
endmodule
