`timescale 1ns/1ps

// bank_buffer : NBANK개의 독립 bank로 이루어진 칩 안 입력 버퍼
//
// 필요한 이유: 외부 메모리는 W B/cycle을 주소 순서대로 주지만, 배열(4x4 기준 A쪽)은
//   COMPUTE 동안 매 사이클 4 B를 행마다 다른 k로 동시에 받아야 한다.
//   LOAD 동안 beat 단위로 쌓고(쓰기), COMPUTE 동안 bank마다 자기 주소로 동시에 꺼낸다(읽기).
//
// - bank 하나는 WB바이트 폭 word DEPTH/WB개로 이루어지고, 쓰기 포트 1개와 읽기 포트 1개를 가진다 (1R1W).
//   칸 k는 word k/WB의 바이트 k%WB이다. WB는 2의 거듭제곱이고 DEPTH를 나눠야 한다.
// - 쓰기 (LOAD): 한 사이클에 bank 하나의 word 하나. wr_mask가 1인 바이트만 쓴다 (마지막 beat는 앞쪽 일부만 1).
//   메모리 beat 하나(W바이트)는 같은 행(열)의 연속된 k이고 k는 W의 배수에서 시작하므로 word 하나와 정확히 겹친다
//   (B 전치 배치, README 7.5절). 그래서 저장 바이트마다 쓰기 데이터가 오는 위치가 하나로 정해진다.
// - 읽기 (COMPUTE): 모든 bank를 각자 다른 주소로 동시에 읽는다. skew 때문에 행마다 읽을 k가 다르다.
//   word를 고른 뒤 그 안에서 1바이트를 고른다.
// - 읽기는 동기식이다: 주소를 넣은 다음 사이클에 데이터가 나온다 (SRAM과 같은 1사이클 지연).
// - 어느 칸에 쓰고 읽을지는 정하지 않는다. 쓰기 위치는 load_seq, 읽기 위치는 edge_feeder가 정한다.
module bank_buffer #(
    parameter NBANK = 4,                // bank 수 (A쪽 ROWS, B쪽 COLS)
    parameter DEPTH = 64,               // bank 하나의 칸(바이트) 수 = K_MAX
    parameter AW    = 6,                // bank 안 칸 주소 폭 = log2(DEPTH)
    parameter WB    = 1                 // word 하나의 바이트 수 = 메모리 beat 바이트 수 W
)(
    input  wire                 clk,

    input  wire [NBANK-1:0]     wr_en,   // bank b에 쓰기 = wr_en[b] (one-hot, 코어가 디코딩해서 준다)
    input  wire [AW-$clog2(WB)-1:0] wr_word, // 쓸 word 번호 = 첫 칸 번호 / WB (모든 bank 공유)
    input  wire [WB-1:0]        wr_mask, // wr_mask[j] = 1이면 word 안 바이트 j를 쓴다
    input  wire [WB*8-1:0]      wr_data, // word 안 바이트 j에 쓸 값 = wr_data[j*8 +: 8] (모든 bank 공유)

    input  wire [NBANK*AW-1:0]  rd_addr, // bank b의 읽기 칸 주소 = rd_addr[b*AW +: AW]
    output wire [NBANK*8-1:0]   rd_data  // bank b의 읽기 데이터 = rd_data[b*8 +: 8]
);

    localparam LW    = $clog2(WB);      // word 안 바이트 번호 폭
    localparam WORDS = DEPTH / WB;      // bank 하나의 word 수

    // bank를 NBANK벌 만든다. 모든 bank가 같은 posedge에 각자 동작한다.
    genvar b;
    generate
        for (b = 0; b < NBANK; b = b + 1) begin : g_bank
            reg  [WB*8-1:0] bank_mem [0:WORDS-1];  // bank 본체: WB바이트 word WORDS개
            reg  [7:0]      rdata;                 // 읽기 출력 레지스터 (동기식 읽기 1사이클)
            wire [AW-1:0]   ra    = rd_addr[b*AW +: AW];
            wire [WB*8-1:0] rword = bank_mem[ra >> LW];   // 칸 ra가 들어 있는 word
            integer         j;

            always @(posedge clk) begin
                if (wr_en[b])                // 이 bank 차례일 때만 쓴다
                    for (j = 0; j < WB; j = j + 1)
                        if (wr_mask[j])
                            bank_mem[wr_word][j*8 +: 8] <= wr_data[j*8 +: 8];
                rdata <= rword[(ra % WB)*8 +: 8]; // 매 사이클 자기 주소로 읽는다. 쓸모없는 값은 valid=0으로 무시된다
            end

            assign rd_data[b*8 +: 8] = rdata;
        end
    endgenerate

endmodule
