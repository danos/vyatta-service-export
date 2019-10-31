#!/usr/bin/perl
# Module: vyatta-flow-monitoring-show.pl
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
use Getopt::Long;
use XML::LibXML;

use constant {
    CONFIG_FILE => "/etc/vermont/vermont.xml",
    RE_AGG => '^<!--\s+Aggregator\s+(\S+)\s+-->$',
    RE_EXP => '^<!--\s+Exporter\s+(\S+)\s+-->$',
    RE_COL => '^<!--\s+Source of flows coming from interface\s+(\S+)\s+-->$',
    SENSOR_FILE => "/var/run/vermont/sensor_output.xml",
    SERVICE_NAME => "vermont",
    XP_AGG => "/ipfixConfig/ipfixAggregator",
    XP_EXP => "/ipfixConfig/ipfixExporter",
    XP_COL => "/ipfixConfig/ipfixCollector",
};

sub checkVermontStatus {
    my $vermont_status = system("service ".SERVICE_NAME." status &> /dev/null");
    if ($vermont_status) {
        print "Flow Monitoring service not running\n";
        exit;
    }
}

sub cmdListAggregators {
    my $config = eval {loadConfig();}; exit if $@;
    my $aggregators = getNameIdMapping($config, XP_AGG, RE_AGG);

    foreach my $aggregator_name (sort(keys(%{$aggregators}))) {
        print $aggregator_name."\n";
    }
}

sub cmdListExporters {
    my $config = eval{loadConfig();}; exit if $@;
    my $exporters = getNameIdMapping($config, XP_EXP, RE_EXP);

    foreach my $exporter_name (sort(keys(%{$exporters}))) {
        print $exporter_name."\n";
    }
}

sub cmdPrintAggregator {
    my $name = $_[0];
    my $config = loadConfig();
    my $sensors = loadSensors();
    my $aggregators = getNameIdMapping($config, XP_AGG, RE_AGG);
    my $id = $aggregators->{$name};

    printAggregatorHeader();
    printAggregator($sensors, $name, $id);
}

sub cmdPrintAll {
    my $config = loadConfig();
    my $sensors = loadSensors();
    my $aggregators = getNameIdMapping($config, XP_AGG, RE_AGG);
    my $exporters = getNameIdMapping($config, XP_EXP, RE_EXP);

    printDataplane();
    print "\n";

    printCollectorReports();
    print "\n";

    printAggregatorHeader();
    while (my ($name, $id) = each(%{$aggregators})) {
        printAggregator($sensors, $name, $id);
    }
    print "\n";

    printExporterHeader();
    while (my ($name, $id) = each(%{$exporters})) {
        printExporter($sensors, $name, $id);
    }
}

sub cmdPrintExporter {
    my $name = $_[0];
    my $config = loadConfig();
    my $sensors = loadSensors();
    my $exporters = getNameIdMapping($config, XP_EXP, RE_EXP);
    my $id = $exporters->{$name};

    printExporterHeader();
    printExporter($sensors, $name, $id);
}

sub getNameIdMapping {
    my $config = $_[0];
    my $modules_xp = $_[1];
    my $module_re = $_[2];
    my $modules = {};

    foreach my $module ($config->findnodes($modules_xp)) {
        my $id = $module->getAttribute("id");
        my $name = $module->findnodes("comment()")->[0];
        if ($name) {
            if ($name =~ /$module_re/) {
                $modules->{$1} = $id;
            }
        }
    }

    return $modules;
}

sub loadConfig {
    return XML::LibXML->load_xml(location => CONFIG_FILE);
}

sub loadSensors {
    return XML::LibXML->load_xml(location => SENSOR_FILE);
}

sub printDataplane {
    system('/opt/vyatta/bin/vyatta_flow_monitoring_show_dataplane.py');
    print "\n";
}

sub printAggregator {
    my $sensors = $_[0];
    my $name = $_[1];
    my $id = $_[2];

    print "    aggregator ".$name.":\n";

    if (!$id) {
        print "        not found\n";
        return;
    }

    my $xp_query = '/vermont/sensorData/sensor[@type="module" and '.
            '@name="ipfixAggregator" and @id="'.$id.'"]';
    my $aggregator = $sensors->findnodes($xp_query)->[0];

    if ($aggregator) {
        my $cache_query = "addInfo/hashtable/entries/text()[1]";
        my $cache = $aggregator->findnodes($cache_query);
        printf("        flows in cache: %23s\n", $cache);

        my $expired_query = "addInfo/hashtable/totalExportedEntries/text()[1]";
        my $expired = $aggregator->findnodes($expired_query);
        printf("        expired flows: %24s\n", $expired);
    } else {
        print "        data not available\n";
    }
}

sub printAggregatorHeader {
    print "aggregator statistics:\n";
}

sub printExporter {
    my $sensors = $_[0];
    my $name = $_[1];
    my $id = $_[2];

    print "    exporter ".$name.":\n";

    if (!$id) {
        print "        not found\n";
        return;
    }

    my $xp_query = '/vermont/sensorData/sensor[@type="module" and '.
            '@name="ipfixExporter" and @id="'.$id.'"]';
    my $exporter = $sensors->findnodes($xp_query)->[0];

    if ($exporter) {
        my $samples_query = "addInfo/totalPacketsInFlows/text()[1]";
        my $samples = $exporter->findnodes($samples_query);
        printf("        samples exported: %21s\n", $samples);

        my $flows_query = "addInfo/totalSentDataRecords/text()[1]";
        my $flows = $exporter->findnodes($flows_query);
        printf("        flows exported: %23s\n", $flows);

        my $flow_packets_query = "addInfo/totalSentUDPDataRecordPackets/".
                "text()[1]";
        my $flow_packets = $exporter->findnodes($flow_packets_query);
        printf("        flow packets sent: %20s\n", $flow_packets);
    } else {
        print "        data not available\n";
    }
}

sub printExporterHeader {
    print "exporter statistics:\n";
}

sub printCollectorReports {
    my $config = loadConfig();
    my $sensors = loadSensors();
    my $collectors = getNameIdMapping($config, XP_COL, RE_COL);

    print "interface collector statistics:\n";
    foreach my $name (sort keys %$collectors) {
        print "    interface ".$name.":\n";

        my $collector_query = '/vermont/sensorData/sensor[@type="simple" and '.
            '@name="IpfixReceiverZMQ" and @id="'.%$collectors{$name}.'"]';
        my $collector = $sensors->findnodes($collector_query)->[0];

        if ($collector) {
            my $records_query = "addInfo/receivedPackets/text()[1]";
			my $records = $collector->findnodes($records_query);
			printf("        records received: %21s\n", $records);
        } else {
            print "        data not available\n";
        }
    }
}

my $cmd = "";
my $arg_name = "";

GetOptions("cmd=s" => \$cmd,
           "name:s" => \$arg_name);



if ($cmd eq "list-aggregators") {
    cmdListAggregators();
} elsif ($cmd eq "list-exporters") {
    cmdListExporters();
} elsif ($cmd eq "print-exporter") {
    checkVermontStatus();
    cmdPrintExporter($arg_name);
} elsif ($cmd eq "print-aggregator") {
    checkVermontStatus();
    cmdPrintAggregator($arg_name);
} else {
    checkVermontStatus();
    cmdPrintAll();
}
