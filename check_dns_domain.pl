#!/usr/bin/perl

# Disable use of embedded perl in Nagios for this script
# nagios: -epn

#
# Check DNS domain configuration consistency and reachability.
# Provides Nagios-compatible return codes.
#
# Author: Michal Ludvig <mludvig@logix.net.nz> (c) 2010
#         http://logix.cz/michal/devel/nagios
#
# Checks performed:
# - Fetch domain SOA through an independent recursive nameserver
# - Fetch domain authoritative NS list from upper-level NS
# - Fetch SOA and NS list from each authoritative NS
# - Warn if SOAs serials don't match.
# - Warn if NS lists don't match (compares NS list obtained
#   from upper-level NS with NS list from one of the auth NS)
# - Warn (Critical) if designated NS doesn't know about the domain
# - Warn if --master is not SOA master
# - Warn if SOA master NS is not in either of the NS lists
# - (TODO: Resolve --rr name and warn if it doesn't match the expected value)

my $version = "1.0";

use strict;
use warnings;
use Net::DNS;
use Getopt::Long;
#use Data::Dumper;

# Nagios error codes
my $EXIT_OK = 0;
my $EXIT_WARNING = 1;
my $EXIT_CRITICAL = 2;
my $EXIT_UNKNOWN = 3;

# Some global vars
my $res;
my $verbose = 0;
my $critical_messages = [];
my $warning_messages = [];
my $ok_messages = [];

my $ignore_hosts = [];
my $nowarn_hosts_unreachable = [];
my $nowarn_hosts_outofsync = [];
my $nowarn_soa_master_match = 0;
my $nowarn_soa_outofsync = 0;
my $nowarn_tld_missing_master = 0;
my $nowarn_tld_nslist = 0;
my $nowarn_aa = 0;

my $suppress_ignored_warns = 0;

# Fetched DNS results
my %results;

# Cache for results obtained from recursive nameservers
my $cache = {};

# Cache for results obtained from TLD nameserver
my $cache_tld = {};

# CLI options-vars
my ($domain, @nameservers, $master);

GetOptions(
	'd|domain=s' => \$domain,
	'ns|nameserver=s' => \@nameservers,
	'master=s' => \$master,
	'v|verbose+' => \$verbose,
	'ignore-host=s' => $ignore_hosts,
	'no-warn-host-unreachable=s' => $nowarn_hosts_unreachable,
	'no-warn-soa-master-mismatch' => \$nowarn_soa_master_match,
	'no-warn-tld-nslist-mismatch' => \$nowarn_tld_nslist,
	'no-warn-tld-missing-master' => \$nowarn_tld_missing_master,
	'no-warn-aa' => \$nowarn_aa,
	'suppress-ignored-warnings' => \$suppress_ignored_warns,
	'version' => sub { &version() },
	'help' => sub { &usage() },
) or die("Use --help for more details.\n");

&main();

my $retval = $EXIT_OK;
my $retmsg = "OK";
if (@$warning_messages) {
	$retval = $EXIT_WARNING;
	$retmsg = "WARNING";
}
if (@$critical_messages) {
	$retval = $EXIT_CRITICAL;
	$retmsg = "CRITICAL";
}
print "$retmsg: $domain: ";
my $msgs = 0;
foreach my $msg (@$critical_messages, @$warning_messages) {
	chomp $msg;
	print " | " if ($msgs > 0);
	print "$msg";
	$msgs += 1;
}

if ($retval == $EXIT_OK) {
	my @slaves = sort(@{$results{'tld_nslist'}});
	&remove_item(\@slaves, $master);
	print "serial=".$results{'recursive_soa'}->{serial}.", master=$master, slaves=[".join(",", @slaves)."]";
	if (not $suppress_ignored_warns) {
		foreach my $msg (@$ok_messages) {
			chomp $msg;
			print " | $msg";
		}
	}
}
print "\n";

exit $retval;

sub version()
{
	print "check_dns_domain.pl version $version\n";
	exit (0);
}

sub usage()
{
	print "
check_dns_domain.pl $version

Script for checking DNS domain inconsitencies.
Return codes are compatible with Nagios.

Author: Michal Ludvig <mludvig\@logix.net.nz> (c) 2010
        http://logix.cz/michal/devel/nagios

Usage: check_dns_domain.pl --domain <domain.tld> [--other-options]

        --domain=<domain.tld>   Fully qualified domain name to check.

        --master=<host.domain>  Expected 'master' nameserver. If not
                                specified the name of master server
                                will be taken from SOA record.
                                If specified but not matching SOA a
                                warning will be emitted.

        --nameserver=<ip.ad.dr.es>
                                IP address of a recursive nameserver.
                                This NS should not be authoritative
                                for the domain. Better use your ISP's
                                nameserver or Google's one on 8.8.8.8.
                                Can be used multiple times.
                                See also --no-warn-aa below.

        Suppress some warnings
        --ignore-host=<host.name>
                                Ignore all errors associated by
                                a nameserver <host.name>.

        --no-warn-host-unreachable=<host.name>
                                Do not treat <host.name>'s unreachability
                                as a problem.

        --no-warn-soa-master-mismatch
                                Do not warn is SOA master doesn't match
                                the host specified with --master.

        --no-warn-tld-nslist-mismatch
                                Do not warn if the list of nameservers
                                returned from TLD doesn't match the list
                                on master nameserver.

        --no-warn-tld-missing-master
                                Do not warn if the list of nameservers
                                returned from TLD doesn't include the
                                SOA master nameserver.

        --no-warn-aa            Do not warn if the recursive nameserver
                                is an authoritative NS for the domain.

        Other options
        --verbose[=<number>]    Be more verbose.
        --version               Print: check_dns_domain.pl version $version
        --help                  Guess what this option is for ;-)

";
	exit (0);
}

sub exit_ok($) {
	print "OK: ";
	print "$domain: " if defined($domain);
	print shift;
	exit $EXIT_OK;
}

sub exit_warning($) {
	print "WARNING: ";
	print "$domain: " if defined($domain);
	print shift;
	exit $EXIT_WARNING;
}

sub exit_critical($) {
	print "CRITICAL: ";
	print "$domain: " if defined($domain);
	print shift;
	exit $EXIT_CRITICAL;
}

sub exit_unknown($) {
	print "UNKNOWN: ";
	print "$domain: " if defined($domain);
	print shift;
	exit $EXIT_UNKNOWN;
}

sub append_warning($$) {
	my ($message, $ignore) = @_;
	print_info("WARNING: $message");
	if ($ignore) {
		push(@$ok_messages, "WARNING: $message");
	} else {
		push(@$warning_messages, $message);
	}
}

sub append_critical($$) {
	my ($message, $ignore) = @_;
	print_info("CRITICAL: $message");
	if ($ignore) {
		push(@$ok_messages, "CRITICAL: $message");
	} else {
		push(@$critical_messages, $message);
	}
}

sub print_info($)
{
	print shift if ($verbose > 0);
}

sub print_debug($)
{
	print shift if ($verbose > 1);
}

sub dump_packet_section($)
{
	my ($section) = @_;
	foreach my $rr (@$section) {
		if ($rr->{type} eq "A") { print "$rr->{name} $rr->{type} $rr->{address}\n"; next; }
		if ($rr->{type} eq "AAAA") { print "$rr->{name} $rr->{type} $rr->{address}\n"; next; }
		if ($rr->{type} eq "NS") { print "$rr->{name} $rr->{type} $rr->{nsdname}\n"; next; }
		if ($rr->{type} eq "MX") { print "$rr->{name} $rr->{type} $rr->{preference} $rr->{exchange}\n"; next; }
		if ($rr->{type} eq "SOA") { print "$rr->{name} $rr->{type} $rr->{serial} $rr->{mname}\n"; next; }
		print "Unknown record type=$rr->{type}\n";
		print map { "#\t$_ => $rr->{$_}\n" } keys %$rr;
	}
}

sub dump_packet($)
{
	my ($packet) = @_;

	return;
	return if ($verbose < 3);

	print "========= packet dump ==========\n";
	if ($packet) {
		my @tmp;
		print "** Answer section\n";
		@tmp = $packet->answer;
		dump_packet_section(\@tmp);

		print "** Authority section\n";
		@tmp = $packet->authority;
		dump_packet_section(\@tmp);

		print "** Additional section\n";
		@tmp = $packet->additional;
		dump_packet_section(\@tmp);
	} else {
		warn "query failed: ", $res->errorstring, "\n";
	}
	print "========= packet end ==========\n";
}

sub find_item($$)
{
	my ($array_ref, $item) = @_;
	my $i;
	for($i = 0; $i < scalar @$array_ref; $i++) {
		last if ($array_ref->[$i] eq $item);
	}
	return undef if ($i >= scalar(@$array_ref));
	return $i;
}

sub remove_item($$)
{
	my ($array_ref, $item) = @_;
	my $i = find_item($array_ref, $item);
	return undef if (not defined($i));
	return splice(@$array_ref, $i, 1);
}

sub diff_arrays($$)
{
	my ($array_ref1, $array_ref2) = @_;
	my @array1 = sort(@$array_ref1);
	my @array2 = sort(@$array_ref2);

	my @array1_leftovers;
	foreach my $item (@array1) {
		if (not remove_item(\@array2, $item)) {
			push(@array1_leftovers, $item);
		}
	}
	return (\@array1_leftovers, \@array2);
}

sub arrays_equal($$)
{
	my ($array_ref1, $array_ref2) = @_;
	($array_ref1, $array_ref2) = diff_arrays($array_ref1, $array_ref2);
	return 0 if (scalar(@$array_ref1) > 0 or scalar(@$array_ref2) > 0);
	return 1;
}

sub in_array($$)
{
	my ($needle, $haystack) = @_;
	foreach my $item (@$haystack) {
		return 1 if ($item eq $needle);
	}
	return 0;
}

sub find_rr_all($$$)
{
	my ($rr_type, $packet, $name) = @_;
	my $rr_list = [];

	return $rr_list if (!defined($packet));

	foreach my $rr ($packet->answer, $packet->authority) {
		push(@$rr_list, $rr) if ($rr->{type} eq $rr_type and $rr->{name} eq $name);
	}

	return $rr_list;
}

sub find_rr($$$)
{
	my ($rr_type, $packet, $name) = @_;

	return undef if (!defined($packet));

	my $rr_list = find_rr_all($rr_type,$packet,$name);

	return undef if (not $rr_list);

	return $rr_list->[0];
}

sub query($$$$)
{
	my ($name, $type, $nameservers, $cache) = @_;
	my ($ret, @ns_old);

	$ret = lookup_cache($cache, $name, $type);
	return ($ret, undef) if (@$ret > 0);

	@ns_old = $res->nameservers;
	if ($nameservers) {
		$res->nameservers(@$nameservers);
		print_debug("Nameservers set to: ".join(",", @$nameservers)."\n");
	}

	my $packet = $res->send($name, $type);

	update_cache($cache, $packet);
	$ret = lookup_cache($cache, $name, $type);

	$res->nameservers(@ns_old);

	#print Data::Dumper->Dump([$cache, $ret], ["cache", "ret"]) if($verbose>3);
	return ($ret, $packet);
}

sub resolve_hostnames($$$)
{
	my ($hostnames,$nameservers,$cache) = @_;
	my $addrs = [];
	foreach my $hostname (@$hostnames) {
		my ($addr, $packet, $ret);
		($ret, $packet) = query($hostname, "AAAA", $nameservers, $cache);
		foreach $addr (@$ret)
			{ push (@$addrs, $addr); }
		($ret, $packet) = query($hostname, "A", $nameservers, $cache);
		foreach $addr (@$ret)
			{ push (@$addrs, $addr); }
	}
	#print_debug("Addresses for (".join(",", @$hostnames)."): ".join(",", @$addrs)."\n");
	return $addrs;
}

sub update_cache_helper($$$$)
{
	my ($cache, $name, $type, $value) = @_;
	if (not $cache->{$type}) {
		$cache->{$type} = {};
	}
	if (not $cache->{$type}->{$name}) {
		$cache->{$type}->{$name} = {};
	}
	if (not $cache->{$type}->{$name}->{$value}) {
		$cache->{$type}->{$name}->{$value} = 1;
	}
}

sub update_cache($$)
{
	my ($cache, $packet) = @_;
	my $rr;
	return if (not $packet);
	foreach $rr ($packet->answer, $packet->authority, $packet->additional) {
		if ($rr->type eq "A" or $rr->type eq "AAAA") {
			update_cache_helper($cache, $rr->name, $rr->type, $rr->address);
			next;
		}
		if ($rr->type eq "NS") {
			update_cache_helper($cache, $rr->name, "NS", $rr->nsdname);
			next;
		}
	}
	#print Data::Dumper->Dump([$cache], ["cache"]);
}

sub lookup_cache($$$)
{
	my ($cache, $name, $type) = @_;

	return [] unless ($cache->{$type}->{$name});
	my @ret = keys(%{$cache->{$type}->{$name}});
	return \@ret;
}

sub query_nameserver($$)
{
	my ($ns, $domain) = @_;

	my ($soa, $nslist);
	my ($ret, $packet);
	my $addrlist = [];

	## Try to get NS addresses from previous TLD responses
	$ret = lookup_cache($cache_tld, $ns, "AAAA");
	push(@$addrlist, @$ret);

	$ret = lookup_cache($cache_tld, $ns, "A");
	push(@$addrlist, @$ret);

	## ... not found, ask recursive NS
	if (not @$addrlist) {
		print_debug("TLD server didn't send A/AAAA for $ns. Querying recursive servers.\n");
		$addrlist = resolve_hostnames([$ns], \@nameservers, $cache);
		print_info("$ns: resolved to: ".join(" ", @$addrlist)." (from recursive nameserver)\n");
	} else {
		print_info("$ns: resolved to: ".join(" ", @$addrlist)." (from TLD nameserver)\n");
	}

	if (not @$addrlist) {
		append_critical("$ns: No A/AAAA record for $domain authoritative NS\n", in_array($ns, $ignore_hosts));
		return (undef, undef);
	}

	($ret, $packet) = query($domain, "SOA", $addrlist, {});
	$soa = find_rr("SOA", $packet, $domain);
	if ($soa) {
		print_info("$ns: SOA serial $soa->{serial}\n");
	} else {
		if ($res->{errorstring} eq "query timed out") {
			append_critical("$ns: nameserver not reachable (query timed out)\n", 
				(in_array($ns, $ignore_hosts) or in_array($ns, $nowarn_hosts_unreachable)));
		} else {
			append_critical("$ns: query for SOA failed: $res->{errorstring}\n", in_array($ns, $ignore_hosts));
		}
		return (undef, undef);
	}

	($nslist, $packet) = query($domain, "NS", $addrlist, {});
	if (@$nslist) {
		print_info("$ns: NS list: ".join(", ", @$nslist)."\n");
	} else {
		append_critical("$ns: query for NS list failed: $res->{errorstring}\n",
			(in_array($ns, $ignore_hosts) or in_array($ns, $nowarn_hosts_unreachable)));
		return ($soa, undef);
	}

	return ($soa, $nslist);
}

sub main()
{
	my (@tmp, $addrlist, $tld_nslist);
	my ($ret, $packet);

	if (! defined($domain)) {
		exit_unknown("Parameter --domain is mandatory\n");
	}
	# Remove trailing dot if any
	$domain =~ s/\.$//;

	$res = Net::DNS::Resolver->new(
		debug       => ($verbose >= 4 ? 1 : 0),
		defnames	=> 0,
		retrans		=> 1,
		udp_timeout	=> 10,
		tcp_timeout	=> 10,
	);

	if (@nameservers) {
		$res->nameservers(@nameservers);
	}
	# Back up list of recursive nameservers for later use
	# (populated by Net::DNS if no --nameserver used)
	@nameservers = $res->nameservers;

	print_info("Using recursive nameserver(s): ".join(" ", @nameservers)."\n");

	($ret, $packet) = query($domain, "SOA", \@nameservers, $cache);
	my $soa = find_rr("SOA", $packet, $domain);

	if (! $soa) {
		if ($res->{errorstring} eq "NXDOMAIN") {
			exit_critical("Domain not known to recursive nameservers (Unregistered? Expired?)\n");
		} else {
			exit_critical("Can't fetch SOA  from: ".join(", ", $res->nameservers)." ($res->{errorstring})\n");
		}
	}

	$results{'recursive_soa'} = $soa;

	print_info("SOA serial $soa->{serial} from $packet->{answerfrom} (".($packet->header->aa ? "" : "non-")."authoritative)\n");
	if ($packet->header->aa and !$nowarn_aa) {
		print("\n");
		print("!! For the most reliable results use a non-authoritative recursive nameserver.\n");
		print("!! Your ISP may provide one, Google has one at 8.8.8.8 too.\n");
		print("!! Alternatively suppress this warning with --no-warn-aa\n");
	}

	# Check if --master == SOA->master
	# (eventually use master from SOA if no --master was set)
	my $soa_master = $soa->mname;
	if ($master) {
		if ($master ne $soa_master) {
			append_warning("master: $master does not match SOA master $soa_master\n", $nowarn_soa_master_match);
		} else {
			print_info("master: $master matches SOA\n");
		}
	} else {
		$master = $soa_master;
		print_info("master: $master (from SOA)\n");
	}

	### Get list of nameservers from TLD
	# Derive TLD name from $domain
	my $tld;
	($tld = $domain) =~ s/^[^\.]*\.//g;

	# Fetch NS list for TLD from our recursive NS
	($tld_nslist, $packet) = query($tld, "NS", \@nameservers, $cache);
	print_debug("$tld nameservers hostnames: ".join(", ", @$tld_nslist)."\n");
	$addrlist = resolve_hostnames($tld_nslist, \@nameservers, $cache);

	# Query TLD nameservers for a list of authoritative nameservers for our domain
	print_debug("Querying $tld to get NS list for $domain\n");
	($ret, $packet) = query($domain, "NS", $addrlist, $cache_tld);
	$results{'tld_nslist'} = $ret;

	if (not @{$results{'tld_nslist'}}) {
		exit_critical("Can't fetch list of authoritative nameservers from TLD: $res->{errorstring}\n");
	}

	print_info("Authoritative NS list for $domain from $packet->{answerfrom}: ".join(" ", @{$results{'tld_nslist'}})."\n");

	### Check that $master is in the list
	if (not defined(find_item($results{'tld_nslist'}, $master))) {
		append_warning("Authoritative TLD NS list doesn't contain master: $master\n", 
			($nowarn_tld_missing_master or in_array($master, $ignore_hosts)));
		## Pick one of the servers to be the master
		$master = $results{'tld_nslist'}->[0];
		print_info("Using $master as a master instead\n");
	}

	if (defined(find_item($results{'tld_nslist'}, $master))) {
		my ($soa, $nslist) = query_nameserver($master, $domain);
		if (not $nslist) {
			append_critical("Master nameserver $master is unreachable. Using data from TLD.\n",
				(in_array($master, $ignore_hosts) or in_array($master, $nowarn_hosts_unreachable)));
			$nslist = $results{'tld_nslist'};
			$soa = $results{'recursive_soa'};
		}
		$results{'master_soa'} = $soa;
		$results{'master_nslist'} = $nslist;
		if (not arrays_equal($results{'master_nslist'}, $results{'tld_nslist'})) {
			append_warning("TLD NS list doesn't match master NS list (tld=[".join(",", @{$results{'tld_nslist'}})."] != master=[".join(",", @{$results{'master_nslist'}})."])\n", $nowarn_tld_nslist);
		}
		if ($soa->{serial} != $results{'recursive_soa'}->{serial}) {
			append_warning("Recursive SOA serial doesn't match master SOA (".$results{'recursive_soa'}->{serial}." != ".$soa->{serial}.")\n", $nowarn_soa_outofsync);
		}
	}

	if (not $results{'master_nslist'}) {
		$results{'master_nslist'} = [$master, @{$results{'tld_nslist'}}];
	}
	if (not $results{'master_soa'}) {
		$results{'master_soa'} = $results{'recursive_soa'};
	}

	foreach my $ns (@{$results{'tld_nslist'}}) {
		next if ($ns eq $master);
		my ($soa, $nslist) = query_nameserver($ns, $domain);

		if ($nslist and (not arrays_equal($results{'master_nslist'}, $nslist))) {
			append_warning("$master (master) NS list doesn't match $ns (slave) NS list (master=[".join(",", @{$results{'master_nslist'}})."] != slave=[".join(",", @$nslist)."])\n", in_array($ns, $nowarn_hosts_outofsync));
		}
		if ($soa and ($soa->{serial} != $results{'master_soa'}->{serial})) {
			append_warning("$master (master) SOA serial doesn't match $ns SOA (".$results{'master_soa'}->{serial}." != ".$soa->{serial}.")\n", in_array($ns, $nowarn_hosts_outofsync));
		}
	}
}
