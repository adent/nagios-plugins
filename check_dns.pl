#!/usr/bin/perl

#
# Check DNS domain configuration consistency and reachability.
# Provides Nagio-compatible return codes.
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
use Net::DNS;
use Getopt::Long;
use Data::Dumper;

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

# CLI options-vars
my ($domain, @nameservers, $master,
    $no_warn_aa);

GetOptions(
	'd|domain=s' => \$domain,
	'ns|nameserver=s' => \@nameservers,
	'master=s' => \$master,
	'v|verbose+' => \$verbose,
	'no-warn-aa' => \$no_warn_aa,
);

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
print "$retmsg: ";
my $msgs = 0;
foreach my $msg (@$critical_messages, @$warning_messages) {
	chomp $msg;
	print " | " if ($msgs > 0);
	print "$msg";
	$msgs += 1;
}

if ($retval == $EXIT_OK) {
	print "Domain $domain looks good!";
}
print "\n";

exit $retval;

sub exit_ok($) {
	print "OK: ".shift;
	exit $EXIT_OK;
}

sub exit_warning($) {
	print "WARNING: ".shift;
	exit $EXIT_WARNING;
}

sub exit_critical($) {
	print "CRITICAL: ".shift;
	exit $EXIT_CRITICAL;
}

sub exit_unknown($) {
	print "UNKNOWN: ".shift;
	exit $EXIT_UNKNOWN;
}

sub append_warning($) {
	my ($message) = @_;
	print_debug("append_warning: $message");
	push(@$warning_messages, shift);
}

sub append_critical($) {
	my ($message) = @_;
	print_debug("append_critical: $message");
	push(@$critical_messages, shift);
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

sub find_rr_all($$)
{
	my ($rr_type, $packet) = @_;
	my $rr_list = [];

	return $rr_list if (!defined($packet));
	
	foreach my $rr ($packet->answer, $packet->authority) {
		push(@$rr_list, $rr) if ($rr->{type} eq $rr_type);
	}

	return $rr_list;
}

sub find_rr($$)
{
	my ($rr_type, $packet) = @_;

	return undef if (!defined($packet));

	my $rr_list = find_rr_all($rr_type,$packet);

	return undef if (not $rr_list);

	return $rr_list->[0];
}

sub create_ns_list($)
{
	my ($rr_list) = @_;
	my $nslist = [];

	foreach my $rr (@$rr_list) {
		push(@$nslist, $rr->nsdname) if ($rr->type eq "NS");
	}

	return $nslist;
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

sub main()
{
	# Fetched DNS results
	my %results;

	# Cache for results obtained from recursive nameservers
	my $cache = {};

	# Cache for results obtained from TLD nameserver
	my $cache_tld = {};

	my (@tmp, $addrlist, $tld_nslist);
	my ($ret, $packet);

	if (! defined($domain)) {
		exit_unknown("Parameter --domain is mandatory\n");
	}

	$res = Net::DNS::Resolver->new(
		debug       => ($verbose >= 4 ? 1 : 0),
		defnames	=> 0,
		retrans		=> 1,
		udp_timeout	=> 10,
		tcp_timeout	=> 10,
	);

	if (defined(@nameservers)) {
		$res->nameservers(@nameservers);
	}
	# Back up list of recursive nameservers for later use
	# (populated by Net::DNS if no --nameserver used)
	@nameservers = $res->nameservers;

	print_info("Using recursive nameserver(s): ".join(" ", @nameservers)."\n");

	($ret, $packet) = query($domain, "SOA", \@nameservers, $cache);
	my $soa = find_rr("SOA", $packet);

	if (! $soa) {
		exit_critical("Can't fetch SOA of $domain from: ".join(" ", $res->nameservers)."\n");
	}

	$results{'recursive_soa'} = $soa;

	print_info("SOA serial $soa->{serial} from $packet->{answerfrom} (".($packet->header->aa ? "" : "non-")."authoritative)\n");
	if ($packet->header->aa and !$no_warn_aa) {
		print("\n");
		print("!! For the most reliable results use a non-authoritative recursive nameserver.\n");
		print("!! Your ISP may provide one, Google has one at 8.8.8.8 too.\n");
		print("!! Alternatively suppress this warning with --no-warn-aa\n");
	}

	# Get list of nameservers from TLD
	my @tmp = split("\\.", $domain);
	shift(@tmp); 
	my $tld = join(".", @tmp);

	# Fetch NS list for TLD from our recursive NS
	($tld_nslist, $packet) = query($tld, "NS", \@nameservers, $cache);
	print_debug("$tld nameservers hostnames: ".join(", ", @$tld_nslist)."\n");
	$addrlist = resolve_hostnames($tld_nslist, \@nameservers, $cache);

	# Query TLD nameservers for a list of authoritative nameservers for our domain
	print_debug("Querying $tld to get NS list for $domain\n");
	($ret, $packet) = query($domain, "NS", $addrlist, $cache_tld);
	$results{'domain_nslist_from_tld'} = $ret;

	if (not $results{'domain_nslist_from_tld'}) {
		exit_critical("Can't fetch list of authoritative nameservers from TLD: $res->{errorstring}\n");
	}
	print_info("Authoritative NS list for $domain from $packet->{answerfrom}: ".join(" ", @{$results{'domain_nslist_from_tld'}})."\n");
	foreach my $ns (@{$results{'domain_nslist_from_tld'}}) {
		my $ret = [];
		$addrlist = [];
		$ret = lookup_cache($cache_tld, $ns, "AAAA");
		push(@$addrlist, @$ret);
		$ret = lookup_cache($cache_tld, $ns, "A");
		push(@$addrlist, @$ret);
		if (not @$addrlist) {
			print_debug("TLD server didn't send A/AAAA for $ns. Querying recursive servers.\n");
			$addrlist = resolve_hostnames([$ns], \@nameservers, $cache);
			print_info("$ns: resolved to: ".join(" ", @$addrlist)." (from recursive nameserver)\n");
		} else {
			print_info("$ns: resolved to: ".join(" ", @$addrlist)." (from TLD nameserver)\n");
		}
		if (not @$addrlist) {
			exit_critical("No A/AAAA record for $domain authoritative ns $ns\n");
		}
		($ret, $packet) = query($domain, "SOA", $addrlist, {});
		$soa = find_rr("SOA", $packet);
		if ($soa) {
			print_info("$ns: SOA serial $soa->{serial}\n");
		} else {
			append_critical("$ns: query for SOA failed: $res->{errorstring}\n");
		}

		($ret, $packet) = query($domain, "NS", $addrlist, {});
		if (@$ret) {
			print_info("$domain: $ns: NS list: ".join(", ", @$ret)."\n");
		} else {
			append_critical("$ns: query for NS list failed: $res->{errorstring}\n");
		}
	}
}