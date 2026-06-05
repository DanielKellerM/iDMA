#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO backend interaction"""
from mako.template import Template
from mario.util import eval_key, prot_key


def render_backend(prot_ids: dict, db: dict, tpl_file: str, compute_ids: list = None) -> str:
    """Generate backend"""
    backend_rendered = ''
    compute_ids = compute_ids or []

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        backend_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        # get ports used
        used_read_prots = prot_ids[prot_id]['ar']
        used_write_prots = prot_ids[prot_id]['aw']

        # single port IPs?
        srp = len(used_read_prots) == 1
        swp = len(used_write_prots) == 1

        # on-the-fly compute is hosted at the (single) AXI write seam
        enable_compute = prot_id in compute_ids
        if enable_compute and not (swp and used_write_prots[0] == 'axi'):
            raise ValueError(f'compute (IDMA_VIDMA_IDS) requires a single AXI write port: {prot_id}')

        # create context
        context = {
            'name_uniqueifier': prot_id,
            'database': db,
            'used_read_protocols': used_read_prots,
            'used_write_protocols': used_write_prots,
            'used_protocols': prot_ids[prot_id]['used'],
            'one_read_port': srp,
            'one_write_port': swp,
            'enable_compute': enable_compute,
            'used_non_bursting_write_protocols':
                prot_key(used_write_prots, 'bursts', 'not_supported', db),
            'combined_aw_and_w':
                eval_key(used_write_prots, 'combined_aw_and_w', 'true', db)
        }

        # render
        backend_rendered += Template(backend_tpl).render(**context)

    return backend_rendered
