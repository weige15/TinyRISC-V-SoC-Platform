# Lab 2 — TA Q&A verification

> Historical audit: the source-hash matches and API/kernel line references below
> apply to the saved V1–V7/TA-Q&A evidence generation, before latency attempts
> 9–13. Do not interpret them as a fresh audit of the later packed-command,
> preparation-adapter or channel-block implementation. Current-source results
> are recorded in `lab2_latency.md` and `results/lab2_opt/att13/`.

## 驗收範圍與結果

依使用者提供的「Additional Verification：助教 Q&A 整理」（Discord
2026/10/7～10/13）逐項核對：**8 個 section、23 個 checklist 項目，23 PASS，0 FAIL rows**。
每列保留原文，補上 section 內的順序編號、V-goal、判定及測試名稱／數量。
原始貼文存於 `QA/notes.md`；不是從 assignment 或測試結果反推的清單。

PASS 表示下列實作、測試及證據符合清單的行為要求，**不是保證未公開 hidden
cases 全過，也不是已執行助教的 private trace grader**。唯一待助教回答的
hidden-test N 範圍仍為 **OPEN**（見末節）。

### 路徑與 V-goal

所有路徑以 NNchip 根目錄為基準：

- `P/` = `TinyRISC-V-SoC-Platform/`
- `R/` = `P/Platform/sw/results/lab2_verification/`
- `V1/` = `R/v1/`；`V4/` = `R/v4/`；`V35/` = `R/v3_v5/`；`QA/` = `R/ta_qa/`
- `RTL` = `demo/out/rtl.log`；`UART` = `demo/V6/uart.log`

| V-goal | 驗證內容 |
|---|---|
| V1 | N、alignment、offset、counter/burst 位寬、切分與整段結果 |
| V2 | RRESP/RLAST 錯誤、持續 drain、完成時序與 recovery |
| V3 | +128 的 9-bit offset 路徑、一般 MAC／convolution 交替 |
| V4 | 唯一 legacy C MAC、真實函式派送、global state 清理 |
| V5 | AXI byte provenance、buffer 重用與 invalidation、跨 layer freshness |
| V6 | 已保存的單次開機 FPGA UART acceptance |
| V7 | Laptop regression、模擬流程、波形、demo 材料 |

## 1.1 Arbitrary N 的範圍

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 1.1.1 | 測試 N = 1、2、3（不是 SIMD 寬度整數倍）、255、256 | V1, V6 | PASS | `npu_lab2_tb.length_matrix`：每個指定 N 有 16 alignment × 5 offset = **80** tuples；5 個指定值共 **400**，包含於 `RTL:400,403` 的 **24,320** matrix cases，零錯誤。歷史 `UART:110` 另有 **640/640** boundary cases。 |
| 1.1.2 | 測試 N 為 SIMD 寬度整數倍與非整數倍的情況 | V1 | PASS | 同一 `length_matrix` 完整測 **N=1..300,511,512,513,1024**（304 lengths ×16×5），包含四個 N mod 4 類別；另有 **12,160** window-end cases；`RTL:400,403`。非整數倍的末端 lane masking 也比對完整 signed oracle。 |
| 1.1.3 | 確認 counter / burst 計算在 N = 256 時不會 overflow | V1 | PASS | `npu_lab2_counters_tb`：**54** actual widths、**80** SET/COMPUTE snapshots、**8,006** checks、0 failures（`V1/counters.log:1–57`）；N=256 含 16 alignments，最多 **65 words**；burst/beat_index 為 9 bits，ARLEN 的 8 bits 編碼 B−1，不是 N。 |

## 1.2 AXI 讀取過程發生錯誤時

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 1.2.1 | error 發生時 `NPU_out` 的值不做任何假設（testbench 不應檢查它） | V2 | PASS | `npu_lab2_tb.run_case` 只在 `INJ_NONE` 比對 COMPUTE result。重新執行四態 `dont-care-error-result` control，將每次 error COMPUTE output 強制為 **32'hxxxxxxxx**，仍通過 **64 cases + 56 recoveries / 120 COMPUTEs**（`QA/dont-care-error-result.log:122–125`）。STATUS 是另一條指令，仍須檢查。 |
| 1.2.2 | error 之後仍持續接收資料並維持 `RREADY`，直到該 burst 的 RLAST handshake 完成 | V2 | PASS | `run_error_matrix`／`watch_tick`：**64/64** cases、**56/56** fresh-data recoveries（`QA/unmodified-control.log:122–125`）。獨立 AR/R monitor 在 outstanding burst 的每一 cycle（含 RVALID bubbles）要求 RREADY=1，RLAST handshake 才關閉 descriptor；`drop-rready-on-error` mutant 被同一 assertion 拒絕（`QA/errors_mutations.log:5`）。 |
| 1.2.3 | 只有在 `RVALID && RREADY && RLAST` 同時成立後，才轉到 `STATE_DONE` 並 assert `NPU_done` | V2 | PASS | `watch_tick`／post-NBA done monitor／`watch_finish` 在 **64 cases** 檢查 affected RLAST 已握手、所有已接受／原先 held AR 均 drain、只有一次單 cycle done，另觀察 32 idle clocks（`QA/unmodified-control.log:122–125`）。`done-before-affected-rlast`、`done-before-other-rlast`、sticky／second-done 四種 mutants 都被拒絕（`QA/errors_mutations.log:7–10`）。下方說明實作的等價完成分支。 |

**STATE_DONE 對應：**此列驗證助教要求的對外完成時序，不宣稱 DUT 使用相同
state encoding。`P/Platform/hw/srcs/NPU.v:363–369` 的 Lab2 路徑在
`STATE_BURST_DOT_PRODUCT` 收到 engine done 才 assert `NPU_done` 並回 IDLE，
不經過名為 `STATE_DONE` 的 enum。Engine 在 `npu_burst_dot_product.v:409–423`
確認 queue 清空且無 held AR 後才完成；queue 只在真正 RLAST handshake 時 pop。
若 RLAST 永遠不來，會持續等待，不以 timeout 提早宣告完成。

## 1.3 RLAST 時序與 RRESP 非 OKAY

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 1.3.1 | 寫 testbench 注入 SLVERR / DECERR，確認 DUT 不會在 RLAST 之前 assert `NPU_done` | V2 | PASS | `run_error_matrix` 有 **24 SLVERR + 8 DECERR** cases：ptr1／ptr2、B=16／256、accepted-other／held-other 各組皆測；共 **32** response-error cases，實際 handshake／drain／done assertions 通過（`QA/unmodified-control.log`；exact case set 由 `QA/error_rows_audit.log` 重查）。 |
| 1.3.2 | RRESP error 出現在 burst 中間、與出現在最後一拍，兩種情況都測 | V2 | PASS | `slverr-middle` **8**、`slverr-last` **8**、`decerr-middle` **8**；另有 `slverr-first` **8**。Middle 是 beat B/2+1、last 是 beat B，均以接受的 R beat 驗證，不只看注入設定（`QA/unmodified-control.log`，完整 **64/64** matrix）。 |
| 1.3.3 | RLAST 提早、RLAST 準時、RLAST 晚到三種情況都測 | V2 | PASS | `early-rlast` **8**（B/2）、`correct-rlast` **8**（B）、`rlast-late-1` **8**、`rlast-late-5` **8**；其餘已接受 burst 仍須 drain。`QA/unmodified-control.log:122–125`：**64/64 cases、56/56 recoveries、0 failures**；late tail 同時檢查實體 operand RAM 不再寫入。 |

## 1.4 運算元的重用（local buffer）

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 1.4.1 | 重用的資料第一次一定經過 AXI fetch，不能由 CPU 直接寫入 local buffer | V5 | PASS | Current-source `npu_axi_trace_scoreboard` + `verify_axi_trace.py`：**384 COMPUTEs、194,516 R beats、856,256 consumed MAC bytes、0 violations**（`QA/reuse_rtl.log`、`QA/trace_replay.log`）。逐 byte 對 full address、值、先前 R handshake 及 epoch；RTL 三個 operand RAM write sites 只接受 `m_axi_rdata`，沒有 CPU-register preload。 |
| 1.4.2 | 確認 buffer 在 software 保證「不變」的前提下才重用；若 pointer 或內容改變，要重新 fetch | V4, V5 | PASS | `run_reuse_safety`：armed_same **64**、arena_new_layer **32**、rearm **64**、unarmed_changed **64**、changed_N **64**、changed_ptr1 **32**，零錯誤（`QA/reuse_rtl.log`）。`reuse_arena_host_test` 實際連續 convolution **64 pairs / 128 layers**，同 input 地址覆寫後 **256** reference outputs 改變，mismatches/stale_hits 均 0（`V35/arena_host.log:129`）。 |
| 1.4.3 | 跑 AXI trace 檢查，確認略過 ptr1 fetch 不會讓 trace check 失敗 | V5 | PASS | `verify_axi_trace.py QA/axi_7.csv.gz QA/reuse_rtl.log` 重播 **384 calls、194,516 R beats、856,256 MAC bytes**，violations=0（`QA/trace_replay.log`）。TB 的 exact AR list 在 **64** armed same-key cases 要求略過 ptr1 refill，同時以先前 AXI bytes 驗證 streaming／local-cache MAC。Replay checker 的 **1 valid + 10 invalid controls** 全部符合預期（`QA/trace_controls.log`）。 |

**重用與 trace 邊界：**CPU/DMA writes 不會被硬體 snoop。資料改變前必須結束
owned immutable interval 並 invalidation；production `ConvMacScope` 在 entry／exit
reset，output 與 operands disjoint 才 arm，pointer/N 改變則 miss/refetch。
不是聲稱在 armed interval 違反契約修改記憶體也能自動 coherent。
1.4.3 的 PASS 是本地 command/AXI/provenance checker 的實測結果；未取得助教
private checker，不能聲稱跑過它。此限制不改寫助教「首次來自 AXI 即可重用」的答覆。

## 2.1 N 超過 256 時的切分

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 2.1.1 | 測 N = 257、300、512、513 等邊界 | V1, V4 | PASS | `lab2_length_host_test` 的 N=257,300,511,512,513 各 **160** cases，whole call 與 256-byte chunks 比對同一獨立 unsplit oracle；合計 **800 matrix cases**，全 suite **833 cases、11,360 COMPUTEs、0 mismatches**（`V1/host.log:1–6`）。`RTL` 同時覆蓋指定四個 N 各 80 tuples。 |
| 2.1.2 | 確認 accumulator 位寬足夠，分段相加不會與整段計算產生差異 | V1, V4 | PASS | 同一 **833-case** host suite 使用獨立 **int64 unsplit oracle**，包含 **32** N=70,000 真正正／負 overflow cases；以定義明確的 uint32 modulo 相加比對。實際 `ConvDotProduct` 的 4096-byte split 另測 **42 tuples**：N=0,1,4095,4096,4097,8193 ×7 offsets（`V4/host.log:14`），exact_visitation=1。 |
| 2.1.3 | 確認 offset 只被套用一次，不會因為分段而重複計入 | V1, V3, V4 | PASS | `lab2_length_host_test`：**5,149,760 per-element audits** 檢查每個 index 只造訪一次、offset 恰一次、兩個 pointer 同步前進（`V1/host.log:6`）；offset-only 非零正權重 pattern 防止 cancellation。`mac_routing_host_test` 的 **42 split tuples** 亦檢查真實 prepared MAC offset（含 +128）及 visits（`V4/host.log:14`）。 |

**實際切分方式：**助教允許 256+44，不代表必須以 256 為上限。本 NPU 可直接
stream N>256；production `ConvDotProduct` 以 **4096** bytes 切分，host 另外測
legacy **256** bytes partition。不是把 test-side 256 切分誤稱 production 行為。
N≤1024 時每 term 絕對值≤32,768，總和≤33,554,432，可裝入 int32；較大 overflow
測試則比對規定的 32-bit result，而非承諾無限精度。實作以 uint32 partial sum
避免 C++ signed-overflow UB。

## 2.2 Input offset 範圍（int8_t 放不下 128）

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 2.2.1 | 測 input offset = −128、−1、0、127、128 | V3 | PASS | `offset9_host_test`：**8 offsets**（含五個指定值）×4 conv shapes ×16 alignments ×2 patterns = **1,024** matrix cases；加交替測試共 **1,280 convolutions、196,608 compared bytes、0 mismatches**（`V35/offset9_host.log:1–40`）。指定 offset 每值 128 matrix cases。 |
| 2.2.2 | 確認 offset 128 不會被 `int8_t` 截斷成 −128 | V3, V4 | PASS | `run_offset9_matrix`：**4,032 tuples、6,560 wide computes、4,288 subsequent plain calls**，zero failures（`RTL:15`）；檢查 9-bit latch=`0x080` 而非 `0x180` 及未 quantize 的完整和。`V35/offset9_mutations.log` 的 **5/5** offset/state mutants（含 API／RTL int8 narrowing）被拒絕。 |
| 2.2.3 | 不依賴「test model 只出現某些 offset」的假設 | V3 | PASS | 新增 focused witness `all_offsets_host.cc`，使用既有 test 的 upstream-reference assertions，讓 **−128..128 全部 257 offsets** 經實際 ConvPerChannel→prepared MAC→SET9；**257 convolutions、12,336 bytes、257 subsequent plain calls、0 mismatches/model failures**（`QA/all_offsets_host.log:1–258`）。另有既存 host／RTL 的全 **256 int8 values** conv/plain 交替測試。 |

**+128 路徑：**`conv.h:44–59` 的 int32 offset →
`lab2_prepare_mac(int32_t, bool)` → 唯一 `hw_simd_mac` 消耗 one-shot command →
`cfu_raw_op(4,5,N,command.offset)`（SET9）→ `NPU.v:313–320` 九位 latch。
一般未 prepare 的 call 使用 SET8，完整 sign-extend／覆寫九位。Legacy int8
argument 在 prepared call 為 0 且不作為 wide offset；不存在先把 +128 cast 成 int8
再修補的路徑。257-value witness 的完整範圍是 pointwise depth-300，不宣稱所有
257 offsets 都跑了四種 shapes 的完整 alignment Cartesian product。

## 2.3 Helper function 與自訂 NPU 指令

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 2.3.1 | `hw_simd_mac` 的 prototype 與行為在 `conv.h` 與 `lab2_test.cc` 中一致，沒有 overload | V4 | PASS | 共用 `lab2_api.h:13–16`，唯一 `extern "C" int32_t hw_simd_mac(int8_t*,int8_t*,int8_t,uint32_t)` 定義。C11 ABI probe **1/1**、RV32 object／V6 ELF 各 **1 GLOBAL FUNC**，preprocess 無 rename macro／overload（`V4/abi_and_boot.log`、`V4/source_audit.log`）；實際 `mac_routing_host_test` **26 cases、9,256 entries/exits**。 |
| 2.3.2 | 確認仍有「部分」MAC 計算實際經過 `hw_simd_mac` | V4 | PASS | `mac_routing_host_test` 直接 instrument 真正 `lab2_api.cc` entry/exit（只 model custom instruction）：**26 cases、9,256 real entries、9,256 exits、0 failures**（`V4/host.log:1–29`），包含 fast、merged、grouped/border、dilation、alias、split、int16；bypass-real-entry mutant 被拒絕（`V4/mutations.log`，**5/5 detected**）。 |
| 2.3.3 | global state 在多次呼叫與多個 layer 之間不會殘留錯誤狀態（尤其是 offset flag、buffer 有效性） | V3, V4, V5, V6 | PASS | `V4/host.log:28–29`：**2 prepared N=0** calls 也清狀態、**9,256 exits** 中 nonidle=0；`V35/offset9_host.log:39–40`：**1,280** conv→plain alternations、stale=0；`V35/arena_host.log:129`：**64 pairs/128 layers**，零 mismatch/stale。歷史 `UART:165,178,408`：conv 後 set **3/3**、random **100/100**，model 後 random **100/100**。 |

**同一 API、允許的 helper state：**差異由明確的 one-shot prepare command 決定，
不是依 caller／translation unit 選 overload；conv 與 lab2_test 呼叫同一 symbol。
`g_conv_command` 所有欄位在 MAC entry 先清零，scope entry／exit 再 reset/disarm。
它位於 startup 實際清零的 `.bss` 範圍（`V4/abi_and_boot.log`），不是未初始化
的 orphan `.sbss`。採用單一 NPU owner，不宣稱支援 prepare 與 MAC 間重入。

## 3 評分與 Demo

| ID | 原始 checklist 項目 | V-goal | 判定 | 具體證據 |
|---|---|---|---|---|
| 3.1 | Demo 前在 laptop 上準備好完整可跑的環境（含 bitstream／模擬流程） | V7, V6 | PASS | `./demo/run.sh` 可離線 build/run；Bash/Python3/Icarus/C++17+ASan 依賴及來源均在場。已執行的 `npu_lab2_tb` **57,255 COMPUTEs／43,806,036 passing checks**、conv host **2,582/2,582 cases／1,187,329 outputs／0 mismatches**；五份 self-checking VCD 各 **1 COMPUTE**。`QA/demo_{rtl,host,waves}.log` 重查實際 log／VCD。現存 `P/Platform/build/out.bit` hash 與 `demo/V6/programmed_bit.sha256` 相同（`QA/completion_audit.log`）；不用帶 FPGA。 |
| 3.2 | 本檔所有 checklist 項目在 hidden-test 風格的邊界案例下重測過 | V1–V7 | PASS | 本表前 **22 items** 逐項對應直接 evidence，不以任一 green total 代替 coverage。N/末端/alignment/split、SLVERR/DECERR/early/late RLAST、changed-address/arena、全257 offsets、empty/early-return/ABI 路徑均有上述結果；`QA/completion_audit.log` 對原文 **23/23** 逐字比對、核對各具名 case set 與 source hashes。新的 error control **2 pass / 14 mutants rejected**，trace **384 calls** 與全-offset **257 convs** 已重跑；完整 RTL／host／UART 沿用且重驗相符來源的既有實測，未虛稱本次全重跑或已取得 hidden tests。 |

Laptop 重現入口（NNchip 根目錄）：

```sh
./demo/run.sh
# 只重新檢查已存證據（不重跑模擬／FPGA）：
python3 demo/verify.py archive
python3 demo/verify.py rtl
python3 demo/verify.py host
python3 demo/verify.py waves
```

五份 `demo/out/waves/{aligned,unaligned,split_4k,slverr,missing_rlast}.vcd`
已解析真正 pre-edge handshakes，分別有 **32、33、34、48、51 R beats**；
passing assertions 分別 **267、578、292、1,364、314,585**，沒有錯誤。
`demo/README.md` 提供完整依賴與操作，`demo/NOTES.md` 提供 code-line 說明。

**V6 僅為歷史 FPGA UART：**`UART:41,165` set 各 3/3；`:54,178,408` random
各 100/100；`:110` boundary 640/640；`:122–124` conv 3/3；
`:240,275,310,345,380` labels 0/1/6/8/11 各 12/12 golden words（60/60）。
本次沒有接板、program、cold boot 或新的 UART execution；host/RTL 不替代硬體結果。

## OPEN — hidden-test N range

**OPEN：1.1 中「測試範圍」在 hidden test 裡是否仍然是 N ≤ 256？**
助教只回答「測試範圍內的任意 N」，没有明確確認 hidden range。
公開 Part 1 是 `1 <= N <= 256`，不要求全 uint32；不能據此替助教回答 hidden limit。

**V1 already covers N up to 1024.** `length_matrix` 對 **1..300,511,512,513,1024**
的 304 lengths 各跑 16 alignments ×5 offsets；另 `long-sweep` 測每個
**N=257..1024**，alignment/offset 採 rotating 選擇。並非所有中間 N 都有完整
Cartesian matrix，也不把 1024 宣稱為 TA-confirmed hidden-test 上限。
證據：`npu_lab2_tb.sv:1412–1427`、`RTL:400,403`。

## Completion audit 與證據時效

| 明確交付要求 | 對应實體 evidence |
|---|---|
| 指定 `Platform/sw/lab2_verification.md` | 本檔位於 platform subrepository 的 `Platform/sw/`。 |
| 八個 sections 每一 checklist item | `QA/notes.md` 的 3+3+3+3+3+3+3+2 = **23** bullets，與本檔 23 rows 原文一一相符，無遺漏／重複。 |
| 每項 V-goal、PASS/FAIL、具名測試與 count 或 UART line | 上方逐項表格；`QA/completion_audit.log` 核對 row IDs、欄位、具名 summaries／完整 cases。 |
| hidden N 問題 OPEN，註明 V1 到 1024 | 前節保留未答問題及 full-matrix／rotating-sweep 的差別。 |
| 印出檔案且無 FAIL rows | 最終讀取完整本檔；audit gate 要求 **23 PASS rows、0 FAIL rows**。 |
| 避免重複已完成工作 | 既有完整 RTL/host/UART 重查而不重跑；只補 current-source error/trace 與完整 prepared-offset range。 |
| 五回合上限 | 原先五回合已停止，舊報告保存於 `QA/previous_blocked_report.md`。使用者補上缺失 notes 後，本次回覆完成逐項 crosswalk，未展開新的五回合迭代。 |

本次新跑：`QA/` error matrix（含 X-output control／14 negative mutants）、
reuse trace + replay、257-offset upstream host witness。原先 V1/V4/V3/V5
focused host/counter 結果來源分別 **9/9、14/14、17/17** hashes 相符；完整
saved demo **22/22** source hashes 相符，**14/14** archive copies 完整。
測試程式的 stimulus、oracle、handshake／visitation／state assertions 已直接檢查，
source hashes 只是時效佐證，不能單獨證明需求完整。

舊 `R/final_audit.log` 記錄「尚未提供 TA notes」時的 blocked gate；它不是本次
結論。本次 gate 存於 `QA/completion_audit.log`。Negative-control logs 的預期失敗
不是 production FAIL rows；沒有刪除／漂白舊證據。未修改 production RTL/API、
既有測試、goldens、bitstream 或 submission ZIP；新增內容限本報告及 `QA/` 證據。
