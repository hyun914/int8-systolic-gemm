
`timescale 1ns/1ps


module PE(
    input wire                  clk,
    input wire                  rst_n,
    input wire                  clear,
    input wire signed [7:0]     a_in,
    input wire signed [7:0]     b_in,
    input wire                  a_valid_in,
    input wire                  b_valid_in,

    output reg signed [7:0]     a_out,
    output reg signed [7:0]     b_out,
    output reg                  a_valid_out,
    output reg                  b_valid_out,
    output reg signed [31:0]    acc_out
    
    );

    wire signed [15:0] product; // int8 x int 8 
    wire signed [31:0] product_ext;

    assign product = a_in * b_in; // 16b mul output
    assign product_ext = {{16{product[15]}}, product}; // extension. 부호확장

    always @(posedge clk)begin
        if(!rst_n || clear) begin
            a_out       <= 8'sd0;
            b_out       <= 8'sd0;
            a_valid_out <= 1'b0;
            b_valid_out <= 1'b0;
            acc_out     <= 32'sd0;
        end else begin //전달 reg가 A,B와 Valid를 함께 저장
            a_out <= a_in;
            b_out <= b_in;
            a_valid_out <= a_valid_in;
            b_valid_out <= b_valid_in;

            if (a_valid_in && b_valid_in) // 누산기는 (a,b) valid가 모두 유효할 때 갱신
                acc_out <= acc_out + product_ext;
        end
    end
endmodule


