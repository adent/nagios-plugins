#!/usr/bin/env perl

use strict;
use Getopt::Long;

my ( $file, $run_apt);
my ( $up_warn, $up_crit) = (0, 0);
my ( $sec_warn, $sec_crit) = (0, 0);
my ( $perf_data );
my $critical = 0;
my ( $filelist, $num_upg, $num_new, $num_del, $num_noupg );

GetOptions(
    'file=s'  => \$file,
    'run-apt' => \$run_apt,
    'perf-data' => \$perf_data,
    'uw=s' => \$up_warn,
    'uc=s' => \$up_crit,
    'sw=s' => \$sec_warn,
    'sc=s' => \$sec_crit,
    'help'    => sub { &usage() }
);

if ( defined($run_apt) ) {
    $ENV{LC_ALL} = 'C';
    open STDIN, "apt-get -q -s upgrade |"
      or die "UNKNOWN - apt-get upgrade : $!\n";
}
elsif ( defined($file) ) {
    open STDIN, "< $file" or die "UNKNOWN - $file : $!\n";
}
else {
  exit 1;
}

while (<>) {
    if (/The following packages will be upgraded:/) {
        while (<>) {
            last if not /^\s+\w+.*/;
            chop($_);
            $filelist .= $_;
        }
        ## Remove extra spaces
        $filelist =~ s/\s+/ /g;
        $filelist .= " ";
    }
    if (/^Inst (?<pkg_name>[^\s]+).*security.*\)$/) {
        $critical++;
        $filelist =~ s/ ($+{pkg_name}) / $1\[S\] /g;
    }
    if (
/(?<n_upg>\d+) upgraded, (?<n_new>\d+) newly installed, (?<n_rem>\d+) to remove and (?<n_noupg>\d+) not upgraded/
      )
    {
        ( $num_upg, $num_new, $num_del, $num_noupg ) = ( $+{n_upg}, $+{n_new},  $+{n_rem}, $+{n_noupg} );
    }
}

my $ret;
my $perf_str = '';
if ($perf_data) {
  $perf_str = "|available_upgrades=$num_upg;$up_warn;$up_crit;;                 critical_updates=$critical;$sec_warn;$sec_crit;;";
  }


if ( !defined($num_upg) ) {
    print("UNKNOWN - could not parse \"apt-get upgrade\" output\n");
    $ret = 3;
}
elsif ( $critical > $sec_warn ) {
    print("CRITICAL - $critical security updates available:                     $filelist$perf_str\n");
    $ret = 2;
}
elsif ( $num_upg > $up_warn ) {
    print("WARNING - $num_upg updates available:$filelist$perf_str\n");
    $ret = 1;
}
elsif (($critical > 0) || ($num_upg > 0 )) {
    print("OK - $critical security & $num_upg updates                           available\n$filelist\n$perf_str\n");
    $ret = 0;
}
else {
    print("OK - system is up to date$perf_str\n");
    $ret = 0;
}
exit $ret;

# ===========

sub usage() {
    printf( "
    Nagios SNMP check for Debian / Ubuntu package updates
    Author: Michal Ludvig <michal\@logix.cz> (c) 2006
    http://www.logix.cz/michal/devel/nagios
    Usage: check-apt-upgrade.pl [options]
      --help          Guess what's it for ;-)
      --file=<file>   File with output of \"apt-get -s upgrade\"
      --run-apt       Run \"apt-get -s upgrade\" directly.
      Option --run-apt has precedence over --file, i.e. no file is
      read if apt-get is run internally. If none of these options
      is given use standard input by default (e.g. to read from
      external command through a pipe).
      Return value (according to Nagios expectations):
      * If no updates are found, returns OK.
      * If there are only non-security updates, return WARNING.
      * If there are security updates, return CRITICAL.
    " );
    exit(1);
}

