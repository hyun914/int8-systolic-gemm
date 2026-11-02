`timescale 1ns/1ps

// load_seq : LOAD 동안 "지금 차례인 원소"를 세는 카운터
//
// 출력 하나로 두 가지를 알려 준다: 메모리에서 어디를 읽을지(addr), bank의 어디에 넣을지(phase_b, lane, k).
//   A 단계: r = 0 .. rows_valid-1, k = 0 .. K-1   (A[i0+r][k], 주소가 계속 +1)
//   B 단계: k = 0 .. K-1, c = 0 .. cols_valid-1   (B[k][j0+c], 행 안에서 +1, 다음 행으로 +N)
// step이 1인 사이클이 끝나면 다음 원소로 넘어가고, 마지막 원소를 지나면 finished가 1이 된다.
//
// 코어는 이 모듈을 두 개 쓴다. 요청 쪽은 요청이 받아들여질 때, 응답 쪽은 응답이 올 때 한 칸씩 진행한다.
// 메모리가 요청 순서대로 응답한다고 가정하므로 두 순서가 1:1로 맞고, 응답 쪽 출력이 돌아온 바이트의 bank와 칸을 알려 준다.
// 그래서 메모리 지연이 몇 사이클이든 요청 정보를 따로 담아 둘 FIFO가 필요 없다.
module load_seq #(
    parameter AW = 16
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          init,        // 타일 시작: 첫 원소로 되돌린다
    input  wire          step,        // 1이면 이번 사이클이 끝날 때 다음 원소로
    input  wire [15:0]   rows_valid,
    input  wire [15:0]   cols_valid,
    input  wire [15:0]   k_len,       // K
    input  wire [15:0]   n_len,       // N (B의 한 행 길이)
    input  wire [AW-1:0] a_start,     // A[i0][0]의 주소
    input  wire [AW-1:0] b_start,     // B[0][j0]의 주소
    output reg           phase_b,     // 0: A 단계, 1: B 단계
    output reg  [15:0]   lane,        // bank 번호 (A 단계 r, B 단계 c). 필요한 폭은 log2(max(ROWS, COLS))비트 (README 7.1절)
    output reg  [15:0]   k,           // bank 안 칸 번호 0 .. K-1. 필요한 폭은 log2(K_MAX)비트 (README 7.1절)
    output reg  [AW-1:0] addr,
    output reg           finished
);

    reg [AW-1:0] row_base;            // B 단계: 현재 행 B[k][j0]의 주소

    wire last_k   = (k == k_len - 1);
    wire last_row = (lane == rows_valid - 1);
    wire last_col = (lane == cols_valid - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            phase_b  <= 1'b0;
            lane     <= 16'd0;
            k        <= 16'd0;
            addr     <= {AW{1'b0}};
            row_base <= {AW{1'b0}};
            finished <= 1'b1;
        end else if (init) begin
            phase_b  <= 1'b0;
            lane     <= 16'd0;
            k        <= 16'd0;
            addr     <= a_start;
            row_base <= b_start;
            finished <= 1'b0;
        end else if (step && !finished) begin
            if (!phase_b) begin
                // A 단계: k가 안쪽 루프. A 타일의 행들은 메모리에서 이어져 있어 주소가 1씩 증가한다.
                if (!last_k) begin
                    k    <= k + 1'b1;
                    addr <= addr + 1'b1;
                end else if (!last_row) begin
                    k    <= 16'd0;
                    lane <= lane + 1'b1;
                    addr <= addr + 1'b1;
                end else begin
                    // A 타일 끝: B 단계로 넘어간다
                    phase_b <= 1'b1;
                    lane    <= 16'd0;
                    k       <= 16'd0;
                    addr    <= b_start;
                end
            end else begin
                // B 단계: c가 안쪽 루프. 한 행을 다 읽으면 N만큼 떨어진 다음 행으로 간다.
                if (!last_col) begin
                    lane <= lane + 1'b1;
                    addr <= addr + 1'b1;
                end else if (!last_k) begin
                    lane     <= 16'd0;
                    k        <= k + 1'b1;
                    row_base <= row_base + n_len;
                    addr     <= row_base + n_len;
                end else begin
                    finished <= 1'b1;
                end
            end
        end
    end

endmodule
