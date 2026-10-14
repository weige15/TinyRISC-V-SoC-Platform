# Additional Verification：助教 Q&A 整理

> 來源：課程 Discord 助教回覆（2026/10/7 ～ 2026/10/13）
> 用途：把助教的補充說明整理成實作時要再驗證的項目。這些內容只出現在助教回覆裡，不一定寫在 spec 中。

---

## 一、Part 1：NPU / AXI 硬體行為

### 1.1 Arbitrary N 的範圍

| 項目 | 內容 |
|---|---|
| 問題 | design 需要 handle arbitrary N，是指測資限定的 1～256，還是整個 uint32？隱藏測資也在 1～256 內嗎？ |
| 助教回覆 | 是指**在測試範圍內的任意 N** |
| 結論 | 以測試範圍（Part 1 為 N ≤ 256）內的任意 N 為準，不需要支援整個 uint32 |

**Verification checklist**
- [ ] 測試 N = 1、2、3（不是 SIMD 寬度整數倍）、255、256
- [ ] 測試 N 為 SIMD 寬度整數倍與非整數倍的情況
- [ ] 確認 counter / burst 計算在 N = 256 時不會 overflow

### 1.2 AXI 讀取過程發生錯誤時

| 項目 | 內容 |
|---|---|
| 問題 | AXI 過程中發生錯誤，assert `NPU_done` 時 `NPU_out` 是否 don't care？ |
| 助教回覆 | **don't care** |
| 追問 | 發生 error 時，是否可以立刻結束，或不收資料？ |
| 助教回覆 | 不可以立刻結束，要**等到 `RVALID && RREADY && RLAST` 成立**才結束（進入 `STATE_DONE`） |

**Verification checklist**
- [ ] error 發生時 `NPU_out` 的值不做任何假設（testbench 不應檢查它）
- [ ] error 之後仍持續接收資料並維持 `RREADY`，直到該 burst 的 RLAST handshake 完成
- [ ] 只有在 `RVALID && RREADY && RLAST` 同時成立後，才轉到 `STATE_DONE` 並 assert `NPU_done`

### 1.3 RLAST 時序與 RRESP 非 OKAY

| 情況 | 處理方式 |
|---|---|
| RLAST 提早到 | spec：可馬上結束並 assert `NPU_done` |
| RLAST 晚到 | spec：要等 RLAST 來才能結束 |
| `RRESP` 為 non-OKAY | 助教：**等到該 burst 的 RLAST 收到後再 assert `NPU_done`** |

**Verification checklist**
- [ ] 寫 testbench 注入 SLVERR / DECERR，確認 DUT 不會在 RLAST 之前 assert `NPU_done`
- [ ] RRESP error 出現在 burst 中間、與出現在最後一拍，兩種情況都測
- [ ] RLAST 提早、RLAST 準時、RLAST 晚到三種情況都測

### 1.4 運算元的重用（local buffer）

| 項目 | 內容 |
|---|---|
| 背景 | handout 要求 NPU 必須透過 AXI master fetch 兩個 operand vector，並使用 fetch 回來的 bytes；grader 會檢查 accelerator-command 與 AXI trace |
| 問題 | 若 software 保證資料沒變，重複呼叫時可否略過 ptr1 的 fetch，重用 buffer？ |
| 助教回覆 | **可以**，只要資料最初是從 AXI interface 取得 |

**Verification checklist**
- [ ] 重用的資料第一次一定經過 AXI fetch，不能由 CPU 直接寫入 local buffer
- [ ] 確認 buffer 在 software 保證「不變」的前提下才重用；若 pointer 或內容改變，要重新 fetch
- [ ] 跑 AXI trace 檢查，確認略過 ptr1 fetch 不會讓 trace check 失敗

---

## 二、Part 2：Software / TFLM 整合

### 2.1 N 超過 256 時的切分

| 項目 | 內容 |
|---|---|
| 問題 | Part 1 的 N ≤ 256，但 Part 2 model 有 N > 256。能否在 sw 切成多組（例：N = 300 → 256 + 44），再把 acc1、acc2 加起來？ |
| 助教回覆 | **可以** |

**Verification checklist**
- [ ] 測 N = 257、300、512、513 等邊界
- [ ] 確認 accumulator 位寬足夠，分段相加不會與整段計算產生差異
- [ ] 確認 offset 只被套用一次，不會因為分段而重複計入

### 2.2 Input offset 範圍（int8_t 放不下 128）

| 項目 | 內容 |
|---|---|
| 問題 | Lab2 軟體的 offset 是 `int8_t`，但 TFLM model 裡有 128 的 offset（需要 9 bits），要自己用軟體處理嗎？ |
| 助教回覆 | **可以**（16:03，由我們自行用軟體處理） |
| 後續補充 | **必須實作 spec 規定的完整範圍（例如 −128 ～ 128）**，test model 只用於 behavioral testing，hidden test cases 會檢查 robustness |

**Verification checklist**
- [ ] 測 input offset = −128、−1、0、127、128
- [ ] 確認 offset 128 不會被 `int8_t` 截斷成 −128
- [ ] 不依賴「test model 只出現某些 offset」的假設

### 2.3 Helper function 與自訂 NPU 指令

| 問題 | 助教回覆 |
|---|---|
| 可否用 `extern "C"` helper function 在 `conv.h` 傳 flag 給 `hw_simd_mac()`，處理超出 `int8_t` 的 offset？ | 可以新增任何 helper function，或 c/c++ source / header 檔 |
| helper function 可否發自訂 NPU 指令（例如設定 offset = 128）、或處理 `conv.h` 中 input/filter channel product 以外的部分？ | **可以** |
| MAC 一定要透過 `hw_simd_mac` 派送嗎？其他 helper 可否呼叫 `cfu_op0`？ | spec 只要求「部分計算」必須經過 `hw_simd_mac`；**custom instruction 可以用在任何地方** |
| 可否新增 global state？ | **可以** |
| 可否 overload `hw_simd_mac`，讓它在 `conv.h` 與 `lab2_test.cc` 行為不同？ | **不行** |

**Verification checklist**
- [ ] `hw_simd_mac` 的 prototype 與行為在 `conv.h` 與 `lab2_test.cc` 中一致，沒有 overload
- [ ] 確認仍有「部分」MAC 計算實際經過 `hw_simd_mac`
- [ ] global state 在多次呼叫與多個 layer 之間不會殘留錯誤狀態（尤其是 offset flag、buffer 有效性）

---

## 三、評分與 Demo

| 項目 | 助教回覆 |
|---|---|
| 評分方式 | 助教會用數個 hidden test cases 評估實作的 robustness |
| Demo 是否要帶 FPGA？ | **不用**，帶 laptop 即可 |

**Verification checklist**
- [ ] Demo 前在 laptop 上準備好完整可跑的環境（含 bitstream／模擬流程）
- [ ] 本檔所有 checklist 項目在 hidden-test 風格的邊界案例下重測過

---

## 四、待向助教確認

1. 1.1 中「測試範圍」在 hidden test 裡是否仍然是 N ≤ 256？（助教只說測試範圍內，沒有明確回答隱藏測資）
