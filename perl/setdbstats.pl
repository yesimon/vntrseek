#!/usr/bin/perl

# sets a number of db stat variables
#
# command line usage example:
#  ./setdbstats.pl reference_file reads_profiles_folder reference_folder reads_profile_folder_clean dbname dblogin dbpass dbhost
# where inputfile is the main cluster file
#

use strict;
use warnings;
use Cwd;

use FindBin;
use File::Basename;

use List::Util qw[min max];

use lib "$FindBin::Bin/vntr"; # must be same as install dir!

require "vutil.pm";

use vutil ('get_credentials');
use vutil ('write_mysql');
use vutil ('stats_set');


my $argc = @ARGV;
if ($argc<6) { die "Usage: setdbstats.pl reference_file reads_profiles_folder reference_folder reads_profile_folder_clean dbname msdir\n"; }

my $reffile = $ARGV[0];
my $readpf = $ARGV[1];
my $reffolder = $ARGV[2];
my $rpfc = $ARGV[3];
my $DBNAME = $ARGV[4];
my $MSDIR = $ARGV[5];

# set these mysql credentials in vs.cnf (in installation directory)
my ($LOGIN,$PASS,$HOST) = get_credentials($MSDIR);

####################################
sub SetStatistics {

  my $argc = @_;
  if ($argc <2) { die "stats_set: expects 2 parameters, passed $argc !\n"; }

  my $NAME = $_[0];
  my $VALUE = $_[1];

  #print "$DBNAME,$LOGIN,$PASS,$NAME,$VALUE\n";
  return stats_set($DBNAME,$LOGIN,$PASS,$HOST,$NAME,$VALUE);
}
####################################

my $rc;
my $exstring;

open(INPUT, "wc -l $reffile | tail -1 |");
$rc = <INPUT>;
if ($rc =~ /(\d+)/) {
  SetStatistics('NUMBER_REF_TRS',$rc);
}
close(INPUT);

open(INPUT, "wc -l $readpf/*.indexhist | tail -1 |");
$rc = <INPUT>;
if ($rc =~ /(\d+)/) {
  SetStatistics('NUMBER_TRS_IN_READS',$rc);
}
close(INPUT);

open(INPUT, "wc -l $reffolder/reference.leb36.rotindex | tail -1 |");
$rc = <INPUT>;
if ($rc =~ /(\d+)/) {
  SetStatistics('NUMBER_REFS_TRS_AFTER_REDUND',$rc);
}
close(INPUT);

open(INPUT, "wc -l $rpfc/*.rotindex | tail -1 |");
$rc = <INPUT>;
if ($rc =~ /(\d+)/) {
  SetStatistics('NUMBER_TRS_IN_READS_AFTER_REDUND',$rc);
}
close(INPUT);


my $readTRsWithPatternGE7 = 0;
my $totalReadsWithTRsPatternGE7 = 0;
my $totalReadsWithTRs = 0;
my $readTRsWPGE7AfterCyclicRedundancyElimination = 0;

open(INPUT, "cat $readpf/*.index | ./ge7.pl |");
$rc = <INPUT>;
if ($rc =~ /(\d+) (\d+) (\d+)/) {
   $readTRsWithPatternGE7 = $1;
   $totalReadsWithTRsPatternGE7 = $2;
   $totalReadsWithTRs = $3;
}
close(INPUT);


open(INPUT, "cat $readpf/*.indexhist | ./ge7.pl |");
$rc = <INPUT>;
if ($rc =~ /(\d+) (\d+) (\d+)/) {
  $totalReadsWithTRs = $3;
}
close(INPUT);


open(INPUT, "cat $rpfc/*.rotindex | wc |");
$rc = <INPUT>;
if ($rc =~ /(\d+) (\d+) (\d+)/) {
  $readTRsWPGE7AfterCyclicRedundancyElimination = $1;
}
close(INPUT);


SetStatistics("NUMBER_TRS_IN_READS_GE7",$readTRsWithPatternGE7);
SetStatistics("NUMBER_READS_WITHTRS_GE7",$totalReadsWithTRsPatternGE7);
SetStatistics("NUMBER_READS_WITHTRS",$totalReadsWithTRs);
SetStatistics("NUMBER_READS_WITHTRS_GE7_AFTER_REDUND",$readTRsWPGE7AfterCyclicRedundancyElimination);


1;




