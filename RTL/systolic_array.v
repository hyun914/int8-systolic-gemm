`timescale 1ns/1ps

module systolic_array #(
    parameter ROWS = 4, // 미지정 시 : 4
    parameter COLS = 4
)
(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    clear,
    input  wire [ROWS*8-1:0]       a_in, // INT8
    input  wire [ROWS-1:0]         a_valid_in,
    input  wire [COLS*8-1:0]       b_in,
    input  wire [COLS-1:0]         b_valid_in,
    output wire [ROWS*COLS*32-1:0] acc_out
);


/*
a_h : a-horizontal : 가로로 흐르는 A 데이터 INT8
av_h : a의 valid
b_v: b-vertical INT8

a_out을 a_in에 직접 꽃을 수 없다.
*/

    wire [7:0] a_h  [0:ROWS-1][0:COLS]; //PE끼리 연결하는 wire
    wire       av_h [0:ROWS-1][0:COLS]; 
    wire [7:0] b_v  [0:ROWS][0:COLS-1];
    wire       bv_v [0:ROWS][0:COLS-1];



    genvar r, c;
    generate

        for(r=0; r<ROWS; r= r+1) begin: g_a_edge
            assign a_h[r][0] = a_in[r*8+:8];
            assign av_h[r][0]= a_valid_in[r];
        end

        for (c=0; c<COLS; c=c+1) begin: g_b_edge
            assign b_v[0][c] = b_in[c*8 +: 8];
            assign bv_v[0][c]= b_valid_in[c];
        end

        for (r = 0; r < ROWS; r = r + 1) begin : g_row
            for (c = 0; c < COLS; c = c + 1) begin : g_col
                PE u_pe (
                    .clk(clk), .rst_n(rst_n), .clear(clear),
                    .a_in(a_h[r][c]),    .a_valid_in(av_h[r][c]),
                    .b_in(b_v[r][c]),    .b_valid_in(bv_v[r][c]),
                    .a_out(a_h[r][c+1]), .a_valid_out(av_h[r][c+1]),
                    .b_out(b_v[r+1][c]), .b_valid_out(bv_v[r+1][c]),
                    .acc_out(acc_out[(r*COLS+c)*32 +: 32])
                );
            end
        end
    endgenerate
endmodule
    