`timescale 1ns/1ps

// bank_buffer : NBANK개의 독립 bank로 이루어진 칩 안 입력 버퍼
//
// 필요한 이유: 외부 메모리는 1 B/cycle을 주소 순서대로 주지만, 배열(4x4 기준 A쪽)은
//   COMPUTE 동안 매 사이클 4 B를 행마다 다른 k로 동시에 받아야 한다.
//   LOAD 동안 한 칸씩 쌓고(쓰기), COMPUTE 동안 bank마다 자기 주소로 동시에 꺼낸다(읽기).
//
// - bank 하나는 8비트 x DEPTH 메모리이고, 쓰기 포트 1개와 읽기 포트 1개를 가진다 (1R1W).
// - 쓰기 (LOAD): 한 사이클에 bank 하나의 한 칸. wr_en은 bank별 one-hot이다.
// - 읽기 (COMPUTE): 모든 bank를 각자 다른 주소로 동시에 읽는다. skew 때문에 행마다 읽을 k가 다르다.
// - 읽기는 동기식이다: 주소를 넣은 다음 사이클에 데이터가 나온다 (SRAM과 같은 1사이클 지연).
// - 어느 칸에 쓰고 읽을지는 정하지 않는다. 쓰기 위치는 load_seq, 읽기 위치는 edge_feeder가 정한다.
module bank_buffer #(
    parameter NBANK = 4,                // bank 수 (A쪽 ROWS, B쪽 COLS)
    parameter DEPTH = 64,               // bank 하나의 칸 수 = K_MAX
    parameter AW    = 6                 // bank 안 주소 폭 = log2(DEPTH)
)(
    input  wire                clk,

    input  wire [NBANK-1:0]    wr_en,   // bank b에 쓰기 = wr_en[b] (one-hot, 코어가 디코딩해서 준다)
    input  wire [AW-1:0]       wr_addr, // 쓸 칸 번호 (모든 bank 공유)
    input  wire [7:0]          wr_data, // 쓸 바이트 (모든 bank 공유)

    input  wire [NBANK*AW-1:0] rd_addr, // bank b의 읽기 주소 = rd_addr[b*AW +: AW]
    output wire [NBANK*8-1:0]  rd_data  // bank b의 읽기 데이터 = rd_data[b*8 +: 8]
);

    // bank를 NBANK벌 만든다. 모든 bank가 같은 posedge에 각자 동작한다.
    genvar b;
    generate
        for (b = 0; b < NBANK; b = b + 1) begin : g_bank
            reg [7:0] bank_mem [0:DEPTH-1];  // bank 본체: 8비트 칸 DEPTH개
            reg [7:0] rdata;                 // 읽기 출력 레지스터 (동기식 읽기 1사이클)

            always @(posedge clk) begin
                if (wr_en[b])
                    bank_mem[wr_addr] <= wr_data;       // 이 bank 차례일 때만 쓴다
                rdata <= bank_mem[rd_addr[b*AW +: AW]]; // 매 사이클 자기 주소로 읽는다. 쓸모없는 값은 valid=0으로 무시된다
            end

            assign rd_data[b*8 +: 8] = rdata;
        end
    endgenerate

endmodule
