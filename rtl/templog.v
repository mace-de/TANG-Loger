module templog #(parameter CLK_HZ=27000000, parameter UART_DIV=9,
                 parameter DEBOUNCE_CYCLES=270000) (
    input wire clk27,
    input wire s1_n, input wire s2_n,
    input wire thermo_do, output wire thermo_clk, output wire thermo_cs_n,
    input wire sd_miso, output wire sd_mosi, output wire sd_sck,
    output wire sd_cs_n,
    input wire uart_rx_pin, output wire uart_tx_pin,
    output wire led_run_n, output wire led_error_n
);
    reg [3:0] powerup = 0;
    always @(posedge clk27) if (!powerup[3]) powerup <= powerup + 1'b1;
    wire reset = !powerup[3];

    wire s1_press, s2_press;
    button #(.DEBOUNCE(DEBOUNCE_CYCLES)) start_button(
        .clk(clk27), .reset(reset), .pin_n(s1_n), .pressed(s1_press));
    button #(.DEBOUNCE(DEBOUNCE_CYCLES)) stop_button(
        .clk(clk27), .reset(reset), .pin_n(s2_n), .pressed(s2_press));

    reg thermo_start = 0;
    wire thermo_done, thermo_busy;
    wire [31:0] thermo_data;
    max31855_reader thermo(
        .clk(clk27), .reset(reset), .start(thermo_start), .so(thermo_do),
        .cs_n(thermo_cs_n), .sck(thermo_clk), .data(thermo_data),
        .busy(thermo_busy), .done(thermo_done)
    );

    reg sd_request = 0, sd_write = 0;
    reg [31:0] sd_lba = 0;
    wire sd_ready, sd_busy, sd_done, sd_error;
    wire [5:0] sd_debug_stage, sd_debug_command;
    wire [7:0] sd_debug_response;
    wire [31:0] sector_count;
    wire [8:0] sd_index;
    wire [7:0] sd_read_data;
    wire sd_read_valid;
    wire [7:0] sd_write_data;
    sd_spi sd(
        .clk(clk27), .reset(reset), .sd_cs_n(sd_cs_n),
        .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .request(sd_request), .write_mode(sd_write), .lba(sd_lba),
        .ready(sd_ready), .busy(sd_busy), .done(sd_done), .error(sd_error),
        .debug_stage(sd_debug_stage), .debug_response(sd_debug_response),
        .debug_command(sd_debug_command),
        .sector_count(sector_count), .data_index(sd_index),
        .write_data(sd_write_data), .read_data(sd_read_data),
        .read_valid(sd_read_valid)
    );

    reg tx_start = 0;
    reg [7:0] tx_data = 0;
    wire tx_busy, tx_done;
    uart_tx #(.CLKS_PER_BIT(UART_DIV)) tx(
        .clk(clk27), .reset(reset), .start(tx_start), .data(tx_data),
        .tx(uart_tx_pin), .busy(tx_busy), .done(tx_done)
    );
    wire [7:0] rx_data;
    wire rx_valid;
    uart_rx #(.CLKS_PER_BIT(UART_DIV)) rx(
        .clk(clk27), .reset(reset), .rx(uart_rx_pin),
        .data(rx_data), .valid(rx_valid)
    );

    localparam [31:0] RECORD_MAGIC=32'h474f4c54, // TLOG
                       CHECK_MAGIC=32'h50434c54,  // TLCP
                       CHECK_XOR=32'ha56c29d3;
    localparam BOOT=0, CP0_WAIT=1, CP1_START=2, CP1_WAIT=3,
       SCAN_START=4, SCAN_WAIT=5, UNFORMATTED=6, READY=7,
       THERMO_WAIT=8, RECORD_WAIT=9, CP_WRITE_START=10,
       CP_WRITE_WAIT=11, FORMAT_CP1=12, FORMAT_CP1_WAIT=13,
       EXPORT_HEADER=14, EXPORT_HEADER_WAIT=15,
       EXPORT_READ=16, EXPORT_READ_WAIT=17,
       EXPORT_RECORD=18, EXPORT_RECORD_WAIT=19,
       INFO_SEND=20, INFO_WAIT=21, FAULT=22,
       BACKUP_READ_WAIT=23, BACKUP_PREFETCH=24,
       BACKUP_SEND=25, BACKUP_SEND_WAIT=26;
    reg [5:0] state = BOOT;
    reg logging = 0;
    reg [31:0] count = 0;
    reg [31:0] generation = 0;
    reg [31:0] session = 0;
    reg [31:0] elapsed = 0;
    reg [31:0] sample_raw = 0;
    reg [31:0] sample_seq = 0;
    reg [31:0] sample_elapsed = 0;
    reg [31:0] checkpoint_count = 0;
    reg [31:0] checkpoint_session = 0;
    reg checkpoint_slot = 0;
    reg write_checkpoint = 0;
    reg cp0_valid = 0;
    reg [31:0] cp0_count = 0;
    reg [31:0] cp0_generation = 0;
    reg [31:0] cp0_session = 0;
    reg [31:0] scan_lba = 2;
    reg [31:0] export_seq = 0;
    reg [9:0] tx_index = 0;
    reg [7:0] info_status = 0;
    reg [5:0] info_return_state = BOOT;
    reg [31:0] info_count = 0;
    reg [31:0] info_capacity = 0;
    reg [7:0] read_buf [0:27];
    reg [7:0] backup_buf [0:511];
    reg [7:0] backup_out = 0;
    reg [31:0] backup_checksum = 0;
    reg [31:0] backup_lba = 0;
    reg backup_was_unformatted = 0;
    always @(posedge clk27) backup_out <= backup_buf[tx_index[8:0]-9'd8];

    wire [31:0] b0 = {read_buf[3],read_buf[2],read_buf[1],read_buf[0]};
    wire [31:0] b1 = {read_buf[7],read_buf[6],read_buf[5],read_buf[4]};
    wire [31:0] b2 = {read_buf[11],read_buf[10],read_buf[9],read_buf[8]};
    wire [31:0] b3 = {read_buf[15],read_buf[14],read_buf[13],read_buf[12]};
    wire [31:0] b4 = {read_buf[19],read_buf[18],read_buf[17],read_buf[16]};
    wire [31:0] b5 = {read_buf[23],read_buf[22],read_buf[21],read_buf[20]};
    wire [31:0] b6 = {read_buf[27],read_buf[26],read_buf[25],read_buf[24]};
    wire checkpoint_valid = b0 == CHECK_MAGIC &&
        b4 == (CHECK_MAGIC ^ b1 ^ b2 ^ b3 ^ CHECK_XOR) &&
        b2 <= sector_count - 2;
    wire record_valid = b0 == RECORD_MAGIC && b1 == count &&
        b5 == generation &&
        b6 == (RECORD_MAGIC ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ CHECK_XOR);

    reg [31:0] write_word;
    always @* begin
        write_word = 0;
        if (write_checkpoint) case (sd_index[4:2])
            0: write_word = CHECK_MAGIC;
            1: write_word = generation;
            2: write_word = checkpoint_count;
            3: write_word = checkpoint_session;
            4: write_word = CHECK_MAGIC ^ generation ^ checkpoint_count ^
                            checkpoint_session ^ CHECK_XOR;
        endcase
        else case (sd_index[4:2])
            0: write_word = RECORD_MAGIC;
            1: write_word = sample_seq;
            2: write_word = sample_raw;
            3: write_word = session;
            4: write_word = sample_elapsed;
            5: write_word = generation;
            6: write_word = RECORD_MAGIC ^ sample_seq ^ sample_raw ^
                            session ^ sample_elapsed ^ generation ^ CHECK_XOR;
        endcase
    end
    assign sd_write_data = sd_index < (write_checkpoint ? 20 : 28) ?
                           (write_word >> (8*sd_index[1:0])) : 8'h00;

    reg [31:0] second_ticks = 0;
    reg sample_due = 0;
    reg stop_checkpoint = 0;
    reg overflow = 0;
    assign led_run_n = ~logging;
    assign led_error_n = ~(state == FAULT || state == UNFORMATTED || overflow);

    reg [2:0] format_bytes = 0;
    reg [31:0] format_nonce = 0;
    reg format_ready = 0;
    reg clear_mode = 0;
    reg download_request = 0, info_request = 0, backup_request = 0;
    reg remote_start = 0, remote_stop = 0;
    reg [2:0] backup_bytes = 0;
    reg [31:0] backup_arg = 0;
    always @(posedge clk27) begin
        format_ready <= 0; download_request <= 0;
        info_request <= 0; backup_request <= 0;
        remote_start <= 0; remote_stop <= 0;
        if (reset) begin
            format_bytes <= 0; format_nonce <= 0; clear_mode <= 0;
            backup_bytes <= 0; backup_arg <= 0;
        end
        else if (rx_valid) begin
            if (backup_bytes != 0) begin
                backup_arg <= {rx_data, backup_arg[31:8]};
                if (backup_bytes == 4) begin
                    backup_bytes <= 0; backup_request <= 1;
                end else backup_bytes <= backup_bytes + 1'b1;
            end else if (format_bytes != 0) begin
                if (format_bytes == 1) begin
                    if (rx_data == 8'h21) format_bytes <= 2;
                    else format_bytes <= 0;
                end else begin
                    format_nonce <= {rx_data, format_nonce[31:8]};
                    if (format_bytes == 5) begin
                        format_bytes <= 0; format_ready <= 1;
                    end else format_bytes <= format_bytes + 1'b1;
                end
            end else case (rx_data)
                8'h46: begin format_bytes <= 1; clear_mode <= 0; end // F! + nonce
                8'h43: begin format_bytes <= 1; clear_mode <= 1; end // C! + nonce
                8'h44: download_request <= 1; // D
                8'h49: info_request <= 1; // I
                8'h42: backup_bytes <= 1; // B followed by 4-byte LBA
                8'h52: remote_start <= 1; // R
                8'h54: remote_stop <= 1; // T
            endcase
        end
    end

    reg [7:0] stream_byte;
    always @* begin
        stream_byte = 0;
        if (state == EXPORT_HEADER || state == EXPORT_HEADER_WAIT) begin
            case (tx_index)
                0: stream_byte = "T"; 1: stream_byte = "L";
                2: stream_byte = "O"; 3: stream_byte = "G";
                4,5,6,7: stream_byte = count >> (8*(tx_index-4));
                8,9,10,11: stream_byte = generation >> (8*(tx_index-8));
            endcase
        end else if (state == INFO_SEND || state == INFO_WAIT) begin
            case (tx_index)
                0: stream_byte = "T"; 1: stream_byte = "I";
                2: stream_byte = "N"; 3: stream_byte = "F";
                4: stream_byte = info_status;
                5: stream_byte = {2'b00, sd_debug_stage};
                6: stream_byte = sd_debug_response;
                7: stream_byte = {2'b00, sd_debug_command};
                8,9,10,11: stream_byte = info_capacity >> (8*(tx_index-8));
                12,13,14,15: stream_byte = info_count >> (8*(tx_index-12));
            endcase
        end else if (state == BACKUP_PREFETCH || state == BACKUP_SEND ||
                     state == BACKUP_SEND_WAIT) begin
            if (tx_index < 4) case (tx_index)
                0: stream_byte = "B"; 1: stream_byte = "L";
                2: stream_byte = "K"; 3: stream_byte = "0";
            endcase
            else if (tx_index < 8) stream_byte = backup_lba >> (8*(tx_index-4));
            else if (tx_index < 520) stream_byte = backup_out;
            else stream_byte = backup_checksum >> (8*(tx_index-520));
        end else if (tx_index < 28) stream_byte = read_buf[tx_index];
    end

    always @(posedge clk27) begin
        sd_request <= 0; thermo_start <= 0; tx_start <= 0;
        if (reset) begin
            state <= BOOT; logging <= 0; count <= 0;
            generation <= 0; session <= 0; elapsed <= 0;
            second_ticks <= 0; sample_due <= 0; stop_checkpoint <= 0;
            overflow <= 0; cp0_valid <= 0; checkpoint_slot <= 0;
        end else begin
            if (logging) begin
                if (second_ticks == CLK_HZ-1) begin
                    second_ticks <= 0;
                    elapsed <= elapsed + 1'b1;
                    if (sample_due) overflow <= 1;
                    else sample_due <= 1;
                end else second_ticks <= second_ticks + 1'b1;
            end else second_ticks <= 0;
            if ((s2_press || remote_stop) && logging) begin
                logging <= 0; sample_due <= 0; stop_checkpoint <= 1;
            end
            if (sd_read_valid && sd_index < 28)
                read_buf[sd_index] <= sd_read_data;
            if (sd_read_valid && state == BACKUP_READ_WAIT) begin
                backup_buf[sd_index] <= sd_read_data;
                backup_checksum <= backup_checksum ^
                                   ({24'd0,sd_read_data} << (8*sd_index[1:0]));
            end
            case (state)
                BOOT: if (info_request) begin
                    info_status <= 4; info_capacity <= sector_count;
                    info_count <= 0; info_return_state <= BOOT;
                    tx_index <= 0; state <= INFO_SEND;
                end else if (sd_ready) begin
                    sd_lba <= 0; sd_write <= 0; sd_request <= 1;
                    state <= CP0_WAIT;
                end else if (sd_done && sd_error) state <= FAULT;
                CP0_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else begin
                        cp0_valid <= checkpoint_valid;
                        if (checkpoint_valid) begin
                            cp0_generation <= b1; cp0_count <= b2; cp0_session <= b3;
                        end
                        state <= CP1_START;
                    end
                end
                CP1_START: begin
                    sd_lba <= 1; sd_write <= 0; sd_request <= 1;
                    state <= CP1_WAIT;
                end
                CP1_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else if (checkpoint_valid && (!cp0_valid || b2 >= cp0_count)) begin
                        generation <= b1; count <= b2; session <= b3;
                        checkpoint_slot <= 1; scan_lba <= b2 + 2;
                        state <= SCAN_START;
                    end else if (cp0_valid) begin
                        generation <= cp0_generation;
                        count <= cp0_count; session <= cp0_session;
                        checkpoint_slot <= 0; scan_lba <= cp0_count + 2;
                        state <= SCAN_START;
                    end else state <= UNFORMATTED;
                end
                SCAN_START: if (scan_lba >= sector_count) state <= READY;
                            else begin
                                sd_lba <= scan_lba; sd_write <= 0; sd_request <= 1;
                                state <= SCAN_WAIT;
                            end
                SCAN_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else if (record_valid) begin
                        count <= count + 1'b1; session <= b3;
                        scan_lba <= scan_lba + 1'b1; state <= SCAN_START;
                    end else state <= READY;
                end
                UNFORMATTED, READY: begin
                    if (format_ready && format_nonce != 0 && !logging &&
                        (clear_mode ? state == READY :
                         (state == UNFORMATTED || count == 0))) begin
                        logging <= 0; sample_due <= 0; stop_checkpoint <= 0;
                        generation <= (clear_mode && format_nonce == generation) ?
                                      generation + 1'b1 : format_nonce;
                        count <= 0; session <= 0;
                        checkpoint_count <= 0; checkpoint_session <= 0;
                        checkpoint_slot <= 0; write_checkpoint <= 1;
                        sd_lba <= 0; sd_write <= 1; sd_request <= 1;
                        state <= CP_WRITE_WAIT;
                    end else if (backup_request && !logging && backup_arg < sector_count) begin
                        backup_lba <= backup_arg;
                        backup_was_unformatted <= (state == UNFORMATTED);
                        backup_checksum <= 0;
                        sd_lba <= backup_arg; sd_write <= 0; sd_request <= 1;
                        state <= BACKUP_READ_WAIT;
                    end else if (info_request) begin
                        info_status <= (state == UNFORMATTED) ? 0 : (logging ? 2 : 1);
                        info_return_state <= state;
                        info_capacity <= sector_count; info_count <= count;
                        tx_index <= 0; state <= INFO_SEND;
                    end else if (state == READY) begin
                        if (download_request && !logging) begin
                            export_seq <= 0; tx_index <= 0;
                            state <= EXPORT_HEADER;
                        end else if ((s1_press || remote_start) && !logging) begin
                            logging <= 1; session <= session + 1'b1;
                            elapsed <= 0; second_ticks <= 0;
                            sample_due <= 0; stop_checkpoint <= 0;
                        end else if (sample_due && logging && !s2_press && !remote_stop) begin
                            sample_due <= 0; thermo_start <= 1;
                            state <= THERMO_WAIT;
                        end else if (stop_checkpoint) begin
                            stop_checkpoint <= 0;
                            checkpoint_count <= count;
                            checkpoint_session <= session;
                            checkpoint_slot <= !checkpoint_slot;
                            state <= CP_WRITE_START;
                        end
                    end
                end
                THERMO_WAIT: if (thermo_done) begin
                    sample_raw <= thermo_data; sample_seq <= count;
                    sample_elapsed <= elapsed; write_checkpoint <= 0;
                    if (count + 2 >= sector_count) state <= FAULT;
                    else begin
                        sd_lba <= count + 2; sd_write <= 1; sd_request <= 1;
                        state <= RECORD_WAIT;
                    end
                end
                RECORD_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else begin
                        count <= count + 1'b1;
                        if ((count[9:0] == 10'h3ff) || stop_checkpoint) begin
                            stop_checkpoint <= 0;
                            checkpoint_count <= count + 1'b1;
                            checkpoint_session <= session;
                            checkpoint_slot <= !checkpoint_slot;
                            state <= CP_WRITE_START;
                        end else state <= READY;
                    end
                end
                CP_WRITE_START: begin
                    write_checkpoint <= 1; sd_write <= 1;
                    sd_lba <= checkpoint_slot; sd_request <= 1;
                    state <= CP_WRITE_WAIT;
                end
                CP_WRITE_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else if (count == 0 && checkpoint_slot == 0) begin
                        checkpoint_slot <= 1; state <= FORMAT_CP1;
                    end else state <= READY;
                end
                FORMAT_CP1: begin
                    write_checkpoint <= 1; sd_write <= 1;
                    sd_lba <= 1; sd_request <= 1;
                    state <= FORMAT_CP1_WAIT;
                end
                FORMAT_CP1_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else state <= READY;
                end
                EXPORT_HEADER: begin
                    tx_data <= stream_byte; tx_start <= 1;
                    state <= EXPORT_HEADER_WAIT;
                end
                EXPORT_HEADER_WAIT: if (tx_done) begin
                    if (tx_index == 11) state <= EXPORT_READ;
                    else begin tx_index <= tx_index + 1'b1; state <= EXPORT_HEADER; end
                end
                EXPORT_READ: if (export_seq == count) state <= READY;
                             else begin
                                 sd_lba <= export_seq + 2; sd_write <= 0;
                                 sd_request <= 1; state <= EXPORT_READ_WAIT;
                             end
                EXPORT_READ_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else begin tx_index <= 0; state <= EXPORT_RECORD; end
                end
                EXPORT_RECORD: begin
                    tx_data <= stream_byte; tx_start <= 1;
                    state <= EXPORT_RECORD_WAIT;
                end
                EXPORT_RECORD_WAIT: if (tx_done) begin
                    if (tx_index == 27) begin
                        export_seq <= export_seq + 1'b1; state <= EXPORT_READ;
                    end else begin tx_index <= tx_index + 1'b1; state <= EXPORT_RECORD; end
                end
                INFO_SEND: begin
                    tx_data <= stream_byte; tx_start <= 1; state <= INFO_WAIT;
                end
                INFO_WAIT: if (tx_done) begin
                    if (tx_index == 15) begin
                        state <= info_return_state;
                    end else begin tx_index <= tx_index + 1'b1; state <= INFO_SEND; end
                end
                BACKUP_READ_WAIT: if (sd_done) begin
                    if (sd_error) state <= FAULT;
                    else begin tx_index <= 0; state <= BACKUP_PREFETCH; end
                end
                BACKUP_PREFETCH: state <= BACKUP_SEND;
                BACKUP_SEND: begin
                    tx_data <= stream_byte; tx_start <= 1;
                    state <= BACKUP_SEND_WAIT;
                end
                BACKUP_SEND_WAIT: if (tx_done) begin
                    if (tx_index == 523)
                        state <= backup_was_unformatted ? UNFORMATTED : READY;
                    else begin tx_index <= tx_index + 1'b1; state <= BACKUP_PREFETCH; end
                end
                FAULT: begin
                    logging <= 0;
                    if (info_request) begin
                        info_status <= 3; info_capacity <= sector_count;
                        info_count <= count; info_return_state <= FAULT;
                        tx_index <= 0; state <= INFO_SEND;
                    end
                end
            endcase
        end
    end
endmodule
