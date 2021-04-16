#!/usr/bin/perl
# Module: vplane-netflow.pl
#
# **** License ****
#
# Copyright (c) 2019-2021, AT&T Intellectual Property.
# Copyright (c) 2015-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****

use strict;
use lib '/opt/vyatta/share/perl5';
use warnings;
use Getopt::Long;
use Vyatta::Config;
use Vyatta::VPlaned;

# Vyatta config
my $vyattaConfig = new Vyatta::Config;

#
# main
#
my ( $cmd, $intf, $type, $vif ) = ("", "", "", "");

GetOptions(
    "cmd=s" => \$cmd,
    "intf=s"  => \$intf,
    "type=s"  => \$type,
    "vif=s"  => \$vif,
);

sub configureDataplane {
    my $intf = $_[0];
    my $type = $_[1];
    my $vif = $_[2];
    my $vif_and_type = "";
    my $sub_int = "";

    my $sampleType = "random";
    my $sampleRate = 1000;

    my $direction = "ingress";

    my $ctrl = new Vyatta::VPlaned;

    if ($vif ne "") {
        $vif_and_type = "vif $vif";
        $sub_int = ".$vif";
    }

    if ($vyattaConfig->exists(
            "interfaces $type $intf $vif_and_type flow-monitoring selector")) {
        my $name = $vyattaConfig->returnValue(
            "interfaces $type $intf $vif_and_type flow-monitoring selector");

        if ($vyattaConfig->exists(
                "service flow-monitoring selector $name randomly out-of")) {
            $sampleRate = $vyattaConfig->returnValue(
                "service flow-monitoring selector $name randomly out-of");
        }

        if ($vyattaConfig->exists(
                "service flow-monitoring selector $name direction")) {
            $direction = $vyattaConfig->returnValue(
                "service flow-monitoring selector $name direction");
        }

        $ctrl->store(
            "interface $type netflow $intf$sub_int",
            "netflow enable $intf$sub_int $sampleType $sampleRate $direction",
            "ALL", "SET"
        );
    } else {
        $ctrl->store(
            "interface $type netflow $intf$sub_int",
            "netflow disable $intf$sub_int", "ALL", "DELETE"
        );
    }
}

sub configureAll {
    if ($vyattaConfig->exists("interfaces dataplane")) {
        my @interfaces = $vyattaConfig->listNodes("interfaces dataplane");
        for my $intf (@interfaces) {
            configureDataplane($intf, "dataplane", "");
            if ($vyattaConfig->exists("interfaces dataplane $intf vif")) {
                my @vifs = $vyattaConfig->listNodes("interfaces dataplane $intf vif");
                for my $vif (@vifs) {
                    configureDataplane($intf, "dataplane", $vif);
                }
            }
        }
    }

    if ($vyattaConfig->exists("interfaces bonding")) {
        my @interfaces = $vyattaConfig->listNodes("interfaces bonding");
        for my $intf (@interfaces) {
            configureDataplane($intf, "bonding", "");
            if ($vyattaConfig->exists("interfaces bonding $intf vif")) {
                my @vifs = $vyattaConfig->listNodes("interfaces bonding $intf vif");
                for my $vif (@vifs) {
                    configureDataplane($intf, "bonding", $vif);
                }
            }
        }
    }

    if ($vyattaConfig->exists("interfaces vhost")) {
        my @interfaces = $vyattaConfig->listNodes("interfaces vhost");
        for my $intf (@interfaces) {
            configureDataplane($intf, "vhost", "");
        }
    }
}

if ($cmd eq "configure_all") {
    configureAll;
} else {
    configureDataplane($intf, $type, $vif);
}
