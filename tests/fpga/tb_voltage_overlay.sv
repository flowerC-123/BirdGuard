`timescale 1ns / 1ps
module tb_voltage_overlay;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0, de = 0, fs = 0, mv = 0;
    reg [11:0] x = 0, y = 0;
    reg [596:0] meta = 0;
    wire [23:0] rgb0, rgb1;
    wire od0, od1;
    hdmi_osd #(
        .VOLTAGE_REFERENCE(0),
        .PANEL_LAYOUT(1),
        .COLOR_LABELS(1),
        .MAX_HOLD_FRAMES(3)
    ) legacy (
        .pixel_clk(clk),
        .rst_n(rst),
        .in_rgb(24'h223344),
        .in_de(de),
        .in_hs(1'b0),
        .in_vs(1'b0),
        .in_x(x),
        .in_y(y),
        .frame_start(fs),
        .meta_valid(mv),
        .meta_payload(meta),
        .meta_cfg(7'd10),
        .out_rgb(rgb0),
        .out_de(od0)
    );
    hdmi_osd #(
        .VOLTAGE_REFERENCE(1),
        .PANEL_LAYOUT(1),
        .COLOR_LABELS(1),
        .MAX_HOLD_FRAMES(3)
    ) reference (
        .pixel_clk(clk),
        .rst_n(rst),
        .in_rgb(24'h223344),
        .in_de(de),
        .in_hs(1'b0),
        .in_vs(1'b0),
        .in_x(x),
        .in_y(y),
        .frame_start(fs),
        .meta_valid(mv),
        .meta_payload(meta),
        .meta_cfg(7'd10),
        .out_rgb(rgb1),
        .out_de(od1)
    );
    function [127:0] glyph;
        input [7:0] c;
        begin
            case (c)
                32: glyph = 128'h00000000000000000000000000000000;
                45: glyph = 128'h00000000003c00000000000000000000;
                46: glyph = 128'h00000000000000101000000000000000;
                48: glyph = 128'h0038644edef666443800000000000000;
                49: glyph = 128'h00387818181818187c00000000000000;
                50: glyph = 128'h00384c040c1830607e00000000000000;
                51: glyph = 128'h00780c0c380c040c7800000000000000;
                53: glyph = 128'h007c4040780c040c7800000000000000;
                54: glyph = 128'h001c60407c6446643800000000000000;
                56: glyph = 128'h003c446c386c44443c00000000000000;
                58: glyph = 128'h00000010100000101000000000000000;
                69: glyph = 128'h007c60607c6060607c00000000000000;
                70: glyph = 128'h007c60607c6060606000000000000000;
                82: glyph = 128'h00784c444c784c4c4600000000000000;
                86: glyph = 128'h00c2c644646c28383800000000000000;
                default: $fatal(1, "missing oracle glyph %0d", c);
            endcase
        end
    endfunction
    integer checks = 0, row, col, ci, n;
    reg [127:0] g0, g1;
    reg [23:0] e0, e1;
    task tick;
        begin
            @(negedge clk);
        end
    endtask
    task publish;
        input valid;
        begin
            tick;
            de = 0;
            fs = 1;
            mv = valid;
            tick;
            fs = 0;
            mv = 0;
            repeat (600) tick;
        end
    endtask
    task pixels;
        input string a, b;
        begin
            for (row = 0; row < 16; row = row + 1)
            for (ci = 0; ci < 12; ci = ci + 1)
            for (col = 0; col < 8; col = col + 1) begin
                tick;
                x  = 1176 + ci * 8 + col;
                y  = 8 + row;
                de = 1;
                g0 = glyph(a[ci]);
                g1 = glyph(b[ci]);
                e0 = g0[127-row*8-col] ? 24'hffffff : 24'h101820;
                e1 = g1[127-row*8-col] ? 24'hffffff : 24'h101820;
                repeat (2) tick;
                if (!od0 || !od1 || rgb0 !== e0 || rgb1 !== e1)
                    $fatal(
                        1,
                        "VOLTAGE_PIXEL row=%0d cell=%0d col=%0d legacy=%h/%h ref=%h/%h",
                        row,
                        ci,
                        col,
                        rgb0,
                        e0,
                        rgb1,
                        e1
                    );
                checks = checks + 2;
            end
            tick;
            de = 0;
        end
    endtask
    initial begin
        repeat (4) tick;
        rst = 1;
        meta[596] = 1;
        meta[595:580] = 1638;
        publish(1);
        pixels("V:016.38V   ", "REF:16.38V  ");
        meta[595:580] = 1050;
        publish(1);
        pixels("V:010.50V   ", "REF:10.50V  ");
        meta[596] = 0;
        publish(1);
        pixels("V:---.--V   ", "REF:--.--V  ");
        meta[596] = 1;
        meta[595:580] = 1638;
        publish(1);
        repeat (4) publish(0);
        pixels("V:---.--V   ", "REF:--.--V  ");
        publish(1);
        pixels("V:016.38V   ", "REF:16.38V  ");
        rst = 0;
        repeat (3) tick;
        rst = 1;
        publish(0);
        pixels("V:---.--V   ", "REF:--.--V  ");
        $display("PASS VOLTAGE_OSD checks=%0d cases=6", checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "WATCHDOG");
    end
endmodule
