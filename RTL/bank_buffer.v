`timescale 1ns/1ps

// bank_buffer : NBANK개의 독립 bank로 이루어진 온칩 입력 버퍼
//
// - bank 하나는 8비트 x DEPTH 크기의 메모리이고, 읽기 포트 1개와 쓰기 포트 1개를 가진다.
// - 쓰기: 한 사이클에 bank 하나의 한 칸 (wr_en은 bank별 one-hot)
// - 읽기: 한 사이클에 모든 bank를 각자 다른 주소로 동시에 읽는다.
//         skew 때문에 행마다 읽어야 하는 k가 다르므로 bank를 나눴다.
// - 읽기는 동기식이다: 주소를 넣은 다음 사이클에 데이터가 나온다 (SRAM과 같은 1사이클 지연).
module bank_buffer #(
    parameter NBANK = 4,
    parameter DEPTH = 64,
    parameter AW    = 6                 // bank 안 주소 폭 = log2(DEPTH)
)(
    input  wire                clk,

    input  wire [NBANK-1:0]    wr_en,   // bank b에 쓰기 = wr_en[b]
    input  wire [AW-1:0]       wr_addr,
    input  wire [7:0]          wr_data,

    input  wire [NBANK*AW-1:0] rd_addr, // bank b의 읽기 주소 = rd_addr[b*AW +: AW]
    output wire [NBANK*8-1:0]  rd_data  // bank b의 읽기 데이터 = rd_data[b*8 +: 8]
);

    genvar b;
    generate
        for (b = 0; b < NBANK; b = b + 1) begin : g_bank
            reg [7:0] mem [0:DEPTH-1];
            reg [7:0] rdata;

            always @(posedge clk) begin
                if (wr_en[b])
                    mem[wr_addr] <= wr_data;
                rdata <= mem[rd_addr[b*AW +: AW]];
            end

            assign rd_data[b*8 +: 8] = rdata;
        end
    endgenerate

endmodule
