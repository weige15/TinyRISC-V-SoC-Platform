# Vivado-generated tracked XCI changes

Inputs were byte-hashed before `all_clean`, at committed revision
`7d3e255ff169dd9daa0d5e66a8b7870477a0ed4f`. Vivado regenerated five tracked XCI
files during the build; no agent edited those files. The captured patch and
copies are `vivado_generated_xci.patch` and `generated_xci/`.

- Four module-reference XCI files: ten constant AXI interface parameters each
  changed only `value_permission` from `bd_and_user` to `bd`. Parameter values,
  port widths/protocols and clocks are unchanged.
- SmartConnect S03_AXI: generated `simulation.tlm` metadata for
  `SUPPORTS_NARROW_BURST` changed from 1 to 0 and gained
  `value_src=constant_prop`. No hardware/model component parameters changed.
- Other **895/900 input files remain byte-identical**, including all submitted
  RTL/software. The checker requires these exact whole-object transformations,
  not a blanket exclusion of XCI files; six positive/negative unit tests pass.

The original software driver reports exit 1 at its overly strict final raw
input-hash assertion, **after actual make returned 0** and produced BIN and ELF
byte-identical to row 13. Its logs/status are preserved, not rewritten.
The hardware driver has the same strict post-build git-diff guard and may
likewise report exit 1 after successful programming. The handoff requires actual
PROGRAM_EXIT=0, startup HIGH, new reports/bitstream, commit identity and the
independent complete input audit before starting capture. No rebuild/retry is
performed merely to conceal this expected generator behavior.

No metadata cleanup/restoration has been done. This note is not Goal 8 status
acceptance; that fresh checkout will need an explicit, honest generated-file
status audit as well.
