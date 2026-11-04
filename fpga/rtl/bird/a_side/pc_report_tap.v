module pc_report_tap #(
    parameter CLOCK_HZ = 50_000_000,
    parameter SOC_BAUD = 1_500_000,

    parameter STATS_BAUD = 9_600,
    parameter PC_BAUD    = 115_200,
    parameter AW         = 7
) (
    input wire clk,
    input wire rst_n,

    input wire soc_rx,
    input wire stats_rx,

    output wire pc_tx,

    output reg [7:0] dropped,
    output wire [AW-1:0] rd_level
);

    wire [7:0] soc_data, st_data;
    wire soc_valid, st_valid;
    wire soc_ferr, st_ferr;

    uart_rx_8n1 #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(SOC_BAUD)
    ) u_soc_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(soc_rx),
        .data(soc_data),
        .valid(soc_valid),
        .framing_error(soc_ferr)
    );

    uart_rx_8n1 #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(STATS_BAUD)
    ) u_st_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(stats_rx),
        .data(st_data),
        .valid(st_valid),
        .framing_error(st_ferr)
    );

    (* ram_style = "bram" *) reg [7:0] mem[0:(1<<AW)-1];

    reg [AW:0] wr_ptr, rd_ptr;
    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);

    reg soc_pend, st_pend;
    reg [7:0] soc_hold, st_hold;

    reg [17:0] soc_busy_cnt;
    localparam [17:0] SOC_BUSY_LOAD = 18'd200_000;
    wire soc_active = (soc_busy_cnt != 18'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) soc_busy_cnt <= 18'd0;
        else if (soc_valid) soc_busy_cnt <= SOC_BUSY_LOAD;
        else if (soc_active) soc_busy_cnt <= soc_busy_cnt - 18'd1;
    end

    wire       wr_en = !fifo_full && (soc_pend || st_pend);
    wire [7:0] wr_byte = soc_pend ? soc_hold : st_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            soc_pend <= 1'b0;
            st_pend  <= 1'b0;
            soc_hold <= 8'd0;
            st_hold  <= 8'd0;
            wr_ptr   <= {(AW + 1) {1'b0}};
            dropped  <= 8'd0;
        end else begin
            if (soc_valid) begin
                if (soc_pend) begin
                    if (dropped != 8'hff) dropped <= dropped + 8'd1;
                end else begin
                    soc_hold <= soc_data;
                    soc_pend <= 1'b1;
                end
            end
            if (st_valid) begin
                if (soc_active || st_pend) begin

                    if (dropped != 8'hff) dropped <= dropped + 8'd1;
                end else begin
                    st_hold <= st_data;
                    st_pend <= 1'b1;
                end
            end
            if (wr_en) begin
                mem[wr_ptr[AW-1:0]] <= wr_byte;
                wr_ptr <= wr_ptr + 1'b1;
                if (soc_pend) soc_pend <= 1'b0;
                else st_pend <= 1'b0;
            end
        end
    end

    reg  [ 7:0] head_q;
    reg         head_valid;
    reg  [AW:0] rd_prefetch;

    wire        tx_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_valid  <= 1'b0;
            head_q      <= 8'd0;
            rd_ptr      <= {(AW + 1) {1'b0}};
            rd_prefetch <= {(AW + 1) {1'b0}};
        end else begin
            if (head_valid && tx_ready) begin
                head_valid <= 1'b0;
            end
            if (!head_valid && !fifo_empty) begin
                head_q      <= mem[rd_ptr[AW-1:0]];
                head_valid  <= 1'b1;
                rd_ptr      <= rd_ptr + 1'b1;
                rd_prefetch <= rd_prefetch + 1'b1;
            end
        end
    end

    uart_tx_8n1 #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(PC_BAUD)
    ) u_pc_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data(head_q),
        .valid(head_valid),
        .ready(tx_ready),
        .tx(pc_tx),
        .done()
    );

    assign rd_level = wr_ptr[AW-1:0] - rd_ptr[AW-1:0];

endmodule
