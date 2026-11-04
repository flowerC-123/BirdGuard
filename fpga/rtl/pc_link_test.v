module pc_link_test #(
    parameter CLOCK_HZ = 50000000,
    parameter BAUD     = 115200
) (
    input  wire clk,
    input  wire rst_n,
    output wire tx
);
    localparam [25:0] GAP = CLOCK_HZ / 2;

    reg [7:0] rom[0:11];
    initial begin
        rom[0]  = "P";
        rom[1]  = "C";
        rom[2]  = "-";
        rom[3]  = "L";
        rom[4]  = "I";
        rom[5]  = "N";
        rom[6]  = "K";
        rom[7]  = "-";
        rom[8]  = "O";
        rom[9]  = "K";
        rom[10] = 8'h0D;
        rom[11] = 8'h0A;
    end

    reg  [25:0] gap_cnt;
    reg  [ 3:0] ci;
    reg         firing;
    reg         valid_r;
    wire        tx_ready;

    uart_tx_8n1 #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD)
    ) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data(rom[ci]),
        .valid(valid_r),
        .ready(tx_ready),
        .tx(tx),
        .done()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gap_cnt <= 26'd0;
            ci <= 4'd0;
            firing <= 1'b0;
            valid_r <= 1'b0;
        end else begin
            valid_r <= 1'b0;
            if (!firing) begin
                if (gap_cnt >= GAP - 1) begin
                    gap_cnt <= 26'd0;
                    firing  <= 1'b1;
                end else gap_cnt <= gap_cnt + 1'b1;
            end else begin
                if (ci == 4'd12) begin
                    firing <= 1'b0;
                    ci <= 4'd0;
                end else if (tx_ready && !valid_r) begin
                    valid_r <= 1'b1;
                    ci <= ci + 1'b1;
                end
            end
        end
    end
endmodule
