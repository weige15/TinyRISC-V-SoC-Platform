#!/usr/bin/env python3
"""Check frozen build inputs, explicitly accounting for observed Vivado outputs.

No files are changed. Only the five exact XCI generation transformations below
are accepted; RTL, software, functional parameter edits and other deltas fail.
Usage: check_build_inputs.py REPO COMMIT INPUT_MANIFEST
"""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

PREFIX = 'Platform/hw/srcs/sources_1/bd/MMIO/ip/'
INTERFACES = {
    'MMIO_CPU_0_0': 'm_axi_lite',
    'MMIO_NPU_0_0': 'M_AXI',
    'MMIO_dcache_axiBus_bridge_0_1': 'M_AXI',
    'MMIO_icache_axiBus_bridge_0_0': 'M_AXI',
}
PERMISSIONS = ('DATA_WIDTH', 'PROTOCOL', 'ID_WIDTH', 'ADDR_WIDTH', 'AWUSER_WIDTH',
               'ARUSER_WIDTH', 'WUSER_WIDTH', 'RUSER_WIDTH', 'BUSER_WIDTH', 'READ_WRITE_MODE')


def generated_xci_only(path, before, after):
    """Require the complete observed generation delta, not a broad exclusion."""
    name = Path(path).stem
    if path != PREFIX + name + '/' + name + '.xci':
        return False
    expected = copy.deepcopy(before)
    try:
        if name in INTERFACES:
            params = expected['ip_inst']['boundary']['interfaces'][INTERFACES[name]]['parameters']
            for key in PERMISSIONS:
                p = params[key][0]
                if not (p['value_permission'] == 'bd_and_user' and p['value_src'] == 'constant'
                        and p['resolve_type'] == 'generated' and p['is_ips_inferred'] is True):
                    return False
                p['value_permission'] = 'bd'
        elif name == 'MMIO_smartconnect_0_2':
            p = expected['ip_inst']['boundary']['interfaces']['S03_AXI']['parameters']['SUPPORTS_NARROW_BURST'][0]
            if not (p['value'] == '1' and p['usage'] == 'simulation.tlm'
                    and p['resolve_type'] == 'generated' and 'value_src' not in p):
                return False
            p['value'] = '0'
            p['value_src'] = 'constant_prop'
        else:
            return False
    except (KeyError, TypeError, IndexError):
        return False
    return expected == after


def check(repo, commit, manifest):
    identical, generated, failures = [], [], []
    for name, wanted in manifest.items():
        data = (repo / name).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual == wanted:
            identical.append(name)
            continue
        if name.startswith(PREFIX) and name.endswith('.xci'):
            old = subprocess.check_output(['git', '-C', str(repo), 'show', commit + ':' + name])
            if hashlib.sha256(old).hexdigest() == wanted and generated_xci_only(name, json.loads(old), json.loads(data)):
                generated.append({'path': name, 'input_sha256': wanted, 'generated_sha256': actual})
                continue
        failures.append(name)
    return {'byte_identical_count': len(identical), 'input_count': len(manifest),
            'exact_vivado_generated_xci_changes': generated, 'unexpected_changes': failures,
            'scope': 'Input identity plus exact observed generated-metadata transformations; not a hardware/UART/GATE acceptance.'}


if __name__ == '__main__':
    result = check(Path(sys.argv[1]), sys.argv[2], json.loads(Path(sys.argv[3]).read_text()))
    print(json.dumps(result, indent=2))
    sys.exit(bool(result['unexpected_changes']))
