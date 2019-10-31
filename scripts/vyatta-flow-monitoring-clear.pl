#!/usr/bin/perl
# Module: exportd-config.pl
#
# **** License ****
#
# Copyright (c) 2019, AT&T Intellectual Property.
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";

use constant {
    CLEAR_FILE => "/var/run/vermont/sensor_clear.txt",
};

system('/opt/vyatta/bin/vplsh -l -c "netflow clear"');

system("touch ".CLEAR_FILE." &> /dev/null");
