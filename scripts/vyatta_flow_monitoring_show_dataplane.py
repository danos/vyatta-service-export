#!/usr/bin/env python3
#
# Copyright (c) 2019, AT&T Intellectual Property.
# Copyright (c) 2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# # Copyright (c) 2019, AT&T Intellectual Property.
#
# SPDX-License-Identifier: GPL-2.0-only

from vplaned import Controller
from collections import Counter, defaultdict

def main():
    dp_interface_stats = defaultdict(Counter)
    dp_stats = defaultdict(dict)

    with Controller() as controller:
        for dp in controller.get_dataplanes():
            with dp:
                for key, value in dp.json_command("netflow show").items():
                    if isinstance(value, dict):
                        dp_interface_stats[key].update(Counter(value))
                    else:
                        dp_stats[dp.id][key] =	value

    print("dataplane statistics:")
    for intf in sorted(dp_interface_stats.keys()):
        print("    interface {}:".format(intf))
        print("        monitor default:")
        for stat in sorted(dp_interface_stats[intf].keys()):
            # Dataplane maintainers do not want JSON keys with spaces, so we
            # have to use _ and strip them out when printing
            print("            {}:{}{}".format(stat.replace("_", " "),
                                               (33 - len(stat)) * " ",
                                               dp_interface_stats[intf][stat]))

    print()

    for dataplane in sorted(dp_stats.keys()):
        print("    dataplane {}:".format(dataplane))
        for stat in sorted(dp_stats[dataplane].keys()):
            # Dataplane maintainers do not want JSON keys with spaces, so we
            # have to use _ and strip them out when printing
            print("            {}:{}{}".format(stat.replace("_", " "),
                                               (33 - len(stat)) * " ",
                                               dp_stats[dataplane][stat]))

if __name__ == '__main__':
    main()
