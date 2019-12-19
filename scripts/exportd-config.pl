#!/usr/bin/perl
# Module: exportd-config.pl
#
# **** License ****
#
# Copyright (c) 2019, AT&T Intellectual Property.
# Copyright (c) 2015-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****

use v5.14;
use strict;
use warnings;
no warnings 'experimental::smartmatch'; #Probably shouldn't use 'when' keyword
use lib "/opt/vyatta/share/perl5/";
use Module::Load::Conditional qw[can_load];
use Vyatta::Config::Parse;
use Vyatta::Interface;
use Getopt::Long;
use Template;
use Digest::MD5 qw(md5);

use constant {
	SERVICE => "/usr/sbin/service vermont",
	EXPORTD_CONF => "/etc/vermont/vermont.xml",
};

# CLI config defaults #
use constant {
	DEFAULT_PORT => 9995,
	DEFAULT_ADDRESS => "127.0.0.1",
};

my $vrf_available = can_load( modules => { "Vyatta::VrfManager" => undef },
	autoload => "true" );
my $vyattaConfig = new Vyatta::Config();
my $disabled = 1;
my $conf_output = "";

sub var_exists {
    no strict 'refs';
    my $name = shift;
    return \${$name} if defined ${$name};
    return;
}

sub is_running {
	return system(SERVICE." status &> /dev/null") == 0;
}

sub reload {
	system(SERVICE." reload &> /dev/null") == 0 or die "Failed to reload Vermont\n";
}

sub start {
	system(SERVICE." start &> /dev/null") == 0 or die "Failed to start Vermont\n";
}

sub stop {
	system(SERVICE." stop &> /dev/null") == 0 or die "Failed to stop Vermont\n";
}

sub hash_module_name {
	# first 4 bytes of md5 of the module name, prefixed with type, converted to unsigned 32 bit long
	my ($module_name, $module_type) = @_;
	my %module_string_prefix_hash = (
		"INT" => "int-",
		"AGG" => "agg-",
		"EXP" => "exp-",
		"COLL" => "ipfix-udp-coll-",
		"ENHANCE" => "enhancer-",
		"EXP-QUEUE" => "exp-queue-"
	    );
	return unpack('L', substr(md5($module_string_prefix_hash{$module_type}.$module_name), 0, 4));
}

sub generate {
	my $output = '';
	my $cfg = new Vyatta::Config::Parse("service flow-monitoring");
	my $interfaces = new Vyatta::Config::Parse("interfaces");
	my $vplanes = new Vyatta::Config::Parse("distributed dataplane");
	my @dataplane_endpoint_addresses;
	my %interfaces_list;
	return $output unless $cfg->{'flow-monitoring'};

	if ($vplanes->{'dataplane'}) {
		my $vplane_node = $vplanes->{'dataplane'};
		foreach my $dp_id (keys %$vplane_node) {
			if ($vplanes->{'dataplane'}->{$dp_id}->{'address'}) {
				push @dataplane_endpoint_addresses, $vplanes->{'dataplane'}->{$dp_id}->{'address'};
			}
		}
	} else {
		push @dataplane_endpoint_addresses, "127.0.0.1";
	}

	if ($interfaces->{"interfaces"}->{"dataplane"}) {
		my $intfs = $interfaces->{"interfaces"}->{"dataplane"};
		foreach my $intf (keys %$intfs) {
			if ($interfaces->{"interfaces"}->{"dataplane"}->{$intf}->{"flow-monitoring"}) {
				$interfaces_list{$intf} = $interfaces->{"interfaces"}->{"dataplane"}->{$intf};
			}
			if ($interfaces->{"interfaces"}->{"dataplane"}->{$intf}->{"vif"}) {
				my $vifs = $interfaces->{"interfaces"}->{"dataplane"}->{$intf}->{"vif"};
				foreach my $vif (keys %$vifs) {
					if ($interfaces->{"interfaces"}->{"dataplane"}->{$intf}->{"vif"}->{$vif}->{"flow-monitoring"}) {
						$interfaces_list{"$intf.$vif"} = $interfaces->{"interfaces"}->{"dataplane"}->{$intf}->{"vif"}->{$vif};
					}
				}
			}
		}
	}

	if ($interfaces->{"interfaces"}->{"bonding"}) {
		my $intfs = $interfaces->{"interfaces"}->{"bonding"};
		foreach my $intf (keys %$intfs) {
			if ($interfaces->{"interfaces"}->{"bonding"}->{$intf}->{"flow-monitoring"}) {
				$interfaces_list{$intf} = $interfaces->{"interfaces"}->{"bonding"}->{$intf};
			}
		}
	}

	if ($interfaces->{"interfaces"}->{"vhost"}) {
		my $intfs = $interfaces->{"interfaces"}->{"vhost"};
		foreach my $intf (keys %$intfs) {
			if ($interfaces->{"interfaces"}->{"vhost"}->{$intf}->{"flow-monitoring"}) {
				$interfaces_list{$intf} = $interfaces->{"interfaces"}->{"vhost"}->{$intf};
			}
		}
	}

	my $tt = new Template(PRE_CHOMP => 1, INCLUDE_PATH => '.');
	if ( $vrf_available ) {
		$tt->process(\*DATA, {
			cfg => $cfg->{'flow-monitoring'},
			interfaces => \%interfaces_list,
			dataplane_endpoint_addresses => \@dataplane_endpoint_addresses,
			hash_module_name => \&hash_module_name,
			vrf_available => $vrf_available,
			rd_vrf_available => $vrf_available &&
                            !defined(var_exists(
                                         "Vyatta::VrfManager::VRFMASTER_PREFIX")),
			get_vrf_id => sub { Vyatta::VrfManager::get_vrf_id( @_ ) },
                        get_vrf_name => sub {
                            my $vrf = shift;
                            my $vrfprefix = var_exists(
                                "Vyatta::VrfManager::VRFMASTER_PREFIX");
                            return $$vrfprefix . $vrf if defined $vrfprefix;
                            return $vrf;
                        }
		}, \$output) or die($tt->error . "\n");
	} else {
		$tt->process(\*DATA, {
			cfg => $cfg->{'flow-monitoring'},
			interfaces => \%interfaces_list,
			dataplane_endpoint_addresses => \@dataplane_endpoint_addresses,
			hash_module_name => \&hash_module_name,
			vrf_available => $vrf_available
		}, \$output) or die($tt->error . "\n");
	}
	return $output;
}

sub apply {
	my $config = generate();
	if ($config eq '') {
		stop() if is_running();
		return;
	}
	open(my $fh, '>', EXPORTD_CONF);
	print $fh $config;
	close($fh);
	if (is_running()) {
		reload();
	} else {
		start();
	}
}

sub validateInterface {
	my $intf = $_[0];
	my $type = $_[1];
	my $vif = $_[2];
	my $vif_and_type = "";
	my $cfg = new Vyatta::Config;

	if ($vif ne "") {
		$vif_and_type = "vif $vif";
	}

	if ($cfg->exists("interfaces $type $intf $vif_and_type flow-monitoring") &&
			$cfg->exists("interfaces $type $intf bond-group")) {

		print "Error: cannot add interface $intf $vif_and_type with flow-monitoring to bond-group";
		exit(1);
	}
}

sub validateAllInterfaces {
	my $cfg = new Vyatta::Config;
	if ($cfg->exists("interfaces dataplane")) {
		my @interfaces = $vyattaConfig->listNodes("interfaces dataplane");
		for my $intf (@interfaces) {
			validateInterface($intf, "dataplane", "");
			if ($cfg->exists("interfaces dataplane $intf vif")) {
				my @vifs = $vyattaConfig->listNodes("interfaces dataplane $intf vif");
				for my $vif (@vifs) {
					validateInterface($intf, "dataplane", $vif);
				}
			}
		}
	}
}

sub usage {
	printf("Usage for %s\n", $0);
	printf("  --action=[apply|generate|validate_all_interfaces]\n");
	exit(1);
}

my $action = "";
GetOptions(
	"action=s" => \$action,
) or usage();

for ($action) {
	apply()              when /^apply$/;
	print generate()     when /^generate$/;
	usage()              when /^$/;
	validateAllInterfaces()               when /^validate_all_interfaces$/;
	default { usage() };
}

__END__
<!-- Autogenerated by vyatta config system -->
<!-- Note: Manual changes to this file will be lost during the next commit. -->
<ipfixConfig logging="[% cfg.logging.level or 'notice' %]">
<sensorManager id="1">
        <outputfile>/var/run/vermont/sensor_output.xml</outputfile>
        <clearfilename>/var/run/vermont/sensor_clear.txt</clearfilename>
        <checkinterval>1</checkinterval>
</sensorManager>
<!-- Collectors for interfaces -->
[% FOREACH interface = interfaces.keys.sort %]
<ipfixCollector id="[% hash_module_name(interface, 'INT') %]">
<!-- Source of flows coming from interface [% interface %] -->
        <listener>
            <transportProtocol>ZMQ</transportProtocol>
     [% FOREACH endpoint = dataplane_endpoint_addresses %]
            <zmqEndpoint>tcp://[% endpoint %]:5950</zmqEndpoint>
     [% END %]
            <zmqPubSubChannel>/monitor/[% interface %]/ipv4</zmqPubSubChannel>
            <zmqPubSubChannel>/monitor/[% interface %]/ipv6</zmqPubSubChannel>
            <zmqHighWaterMark>5000</zmqHighWaterMark>
        </listener>
        <next>[% hash_module_name(interface, 'ENHANCE') %]</next>
</ipfixCollector>
<ipfixEnhancer id ="[% hash_module_name(interface, 'ENHANCE') %]">
        <fieldsList>
            <field>
                <ieName>sourceIPv4PrefixLength</ieName>
            </field>
            <field>
                <ieName>destinationIPv4PrefixLength</ieName>
            </field>
            <field>
                <ieName>bgpNextHopIPv4Address</ieName>
            </field>
            <field>
                <ieName>sourceIPv6PrefixLength</ieName>
            </field>
            <field>
                <ieName>destinationIPv6PrefixLength</ieName>
            </field>
            <field>
                <ieName>bgpNextHopIPv6Address</ieName>
            </field>
            <field>
                <ieName>bgpSourceAsNumber</ieName>
            </field>
            <field>
                <ieName>bgpDestinationAsNumber</ieName>
            </field>
            <field>
                <ieName>bgpPrevAdjacentAsNumber</ieName>
            </field>
            <field>
                <ieName>bgpNextAdjacentAsNumber</ieName>
            </field>
        </fieldsList>
        <routingPlane>
            <zmqSubEndpoint>ipc:///var/run/routing/routing-netflow-pub-sub.ipc</zmqSubEndpoint>
            <zmqReqEndpoint>ipc:///var/run/routing/routing-netflow-req-rep.ipc</zmqReqEndpoint>
            <zmqHighWaterMark>5000</zmqHighWaterMark>
            <cacheWipingInterval>300</cacheWipingInterval>
        </routingPlane>
    [% FOREACH next_exp = interfaces.item(interface).item('flow-monitoring').exporter %]
        <next>[% hash_module_name(next_exp, 'EXP-QUEUE') %]</next><!-- Exporter [% next_exp %] -->
    [% END %]
    [% FOREACH next_agg = interfaces.item(interface).item('flow-monitoring').aggregator %]
        <next>[% hash_module_name(next_agg, 'AGG') %]</next><!-- Aggregator [% next_agg %] -->
    [% END %]
</ipfixEnhancer>
[% END %]
<!-- Aggregators -->
[% FOREACH agg = cfg.aggregator.keys.sort %]
<ipfixAggregator id="[% hash_module_name(agg, 'AGG') %]">
<!-- Aggregator [% agg %] -->
        <rule>
    [% FOREACH key_field = cfg.aggregator.$agg.rule.key %]
                <flowKey>
                       <ieName>[% key_field %]</ieName>
        [% IF key_field == 'sourceIPv4Address' || key_field == 'destinationIPv4Address' %]
                       <autoAddV4PrefixLength>false</autoAddV4PrefixLength>
        [% END %]
                </flowKey>
    [% END %]
    [% FOREACH non_key_field = cfg.aggregator.$agg.rule.item('non-key') %]
                <nonFlowKey>
                       <ieName>[% non_key_field %]</ieName>
        [% IF non_key_field == 'sourceIPv4Address' || non_key_field == 'destinationIPv4Address' %]
                       <autoAddV4PrefixLength>false</autoAddV4PrefixLength>
        [% END %]
                </nonFlowKey>
    [% END %]
        </rule>
        <expiration>
               <inactiveTimeout unit="sec">[% cfg.aggregator.$agg.expiration.item('inactive-timeout') %]</inactiveTimeout>
               <activeTimeout unit="sec">[% cfg.aggregator.$agg.expiration.item('active-timeout') %]</activeTimeout>
        </expiration>
        <hashtableBits>[% cfg.aggregator.$agg.item('hashtable-bits') %]</hashtableBits>
  [% FOREACH next_exp = cfg.aggregator.$agg.next.exporter %]
        <next>[% hash_module_name(next_exp, 'EXP-QUEUE') %]</next><!-- Exporter [% next_exp %] -->
  [% END %]
  [% FOREACH next_agg = cfg.aggregator.$agg.next.aggregator %]
        <next>[% hash_module_name(next_agg, 'AGG') %]</next><!-- Aggregator [% next_agg %] -->
  [% END %]
</ipfixAggregator>
[% END %]
<!-- Listener for DPI Options -->
<!-- Fixed ID, and sends to all exporters -->
<ipfixCollector id="2">
        <listener>
            <transportProtocol>ZMQ</transportProtocol>
            <zmqEndpoint>tcp://127.0.0.1:5951</zmqEndpoint>
            <zmqPubSubChannel>dpi_option</zmqPubSubChannel>
        </listener>
    [% FOREACH next_exp = cfg.exporter.keys.sort %]
        <next>[% hash_module_name(next_exp, 'EXP-QUEUE') %]</next><!-- Exporter [% next_exp %] -->
    [% END %]
</ipfixCollector>
<!-- Exporters -->
[% FOREACH exp = cfg.exporter.keys.sort %]
<ipfixQueue id="[% hash_module_name(exp, 'EXP-QUEUE') %]">
        <entries>5000</entries>
        <next>[% hash_module_name(exp, 'EXP') %]</next>
</ipfixQueue>
<ipfixExporter id="[% hash_module_name(exp, 'EXP') %]">
<!-- Exporter [% exp %] -->
        <protocolVersion>[% cfg.exporter.$exp.item('protocol-version') %]</protocolVersion>
        <maxRecordRate>[% cfg.exporter.$exp.item('max-record-rate') %]</maxRecordRate>
        <templateRefreshInterval>[% cfg.exporter.$exp.item('template-refresh-interval') %]</templateRefreshInterval>
        <collector>
                <transportProtocol>UDP</transportProtocol>
                <ipAddress>[% cfg.exporter.$exp.item('udp-collector').address %]</ipAddress>
                <port>[% cfg.exporter.$exp.item('udp-collector').port %]</port>
                <mtu>[% cfg.exporter.$exp.item('udp-collector').mtu %]</mtu>
  [% IF vrf_available && cfg.exporter.$exp.item('udp-collector').item("routing-instance") %]
    [% IF rd_vrf_available %]
                <vrfId>[% get_vrf_id(cfg.exporter.$exp.item('udp-collector').item("routing-instance")) %]</vrfId>
    [% END %]
                <vrfName>[% get_vrf_name(cfg.exporter.$exp.item('udp-collector').item("routing-instance")) %]</vrfName>
  [% END %]
        </collector>
</ipfixExporter>
[% END %]
<!-- IPFIX UDP Collectors -->
[% FOREACH collect = cfg.item('ipfix-udp-collector').keys.sort %]
<ipfixCollector id="[% hash_module_name(collect, 'COLL') %]">
<!-- IPFIX UDP Collector [% collect %] -->
        <listener>
            <transportProtocol>UDP</transportProtocol>
            <ipAddress>[% cfg.item('ipfix-udp-collector').$collect.address %]</ipAddress>
            <port>[% cfg.item('ipfix-udp-collector').$collect.port %]</port>
        </listener>
  [% FOREACH next_exp = cfg.item('ipfix-udp-collector').$collect.next.exporter %]
        <next>[% hash_module_name(next_exp, 'EXP-QUEUE') %]</next><!-- Exporter [% next_exp %] -->
  [% END %]
  [% FOREACH next_agg = cfg.item('ipfix-udp-collector').$collect.next.aggregator %]
        <next>[% hash_module_name(next_agg, 'AGG') %]</next><!-- Aggregator [% next_agg %] -->
  [% END %]
</ipfixCollector>
[% END %]
</ipfixConfig>
