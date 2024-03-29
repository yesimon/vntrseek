#!/usr/bin/perl

# MASTER SCRIPT TO RUN THE TR VARIANT SEARCH PIPELINE
#
# DO NOT USE SPACES IN PATHS AND DO NOT USE DOTS (.) OR HYPHENS (-) IN DBSUFFIX
#
# command line usage example:
#  vntrseek N K --dbsuffix dbsuffix
#       where N is the start step to execute (0 is the first step)
#       and K is the end step (19 is the last step)
#
# example:
#  vntrseek 0 19 --dbsuffix run1 --server orca.bu.edu --nprocesses 8 --html_dir /var/www/html/vntrview --fasta_dir /bfdisk/watsontest --output_root /smdisk --tmpdir /tmp &
#
# special commands:
#  vntrseek 100 --dbsuffix dbsuffix
#       clear error
#  vntrseek 99 --dbsuffix dbsuffix
#       return next step that needs to be run (this can be
#       used for multi/single processor execution flow control used with
#       advanced cluster script)
#  vntrseek 100 N --dbsuffix dbsuffix
#       clear error and set NextRunStep to N (for advanced cluster script)
#
# IMPORTANT: for correct execution, please add these lines to 
# [mysqld] section of my.cnf file and restart mysql process:
#
# innodb_buffer_pool_size=1G
# innodb_additional_mem_pool_size=20M


use strict;
use warnings;
use Cwd;

use FindBin;
use File::Basename;

use Getopt::Long qw(GetOptionsFromArray);

use List::Util qw(min max);

# VNTRSEEK Version
my $VERSION = "1.08"; 

# this is where the pipeline is installed
my $install_dir = "$FindBin::RealBin"; 

use lib "$FindBin::RealBin/vntr"; # must be same as install dir!

require "vutil.pm";

use vutil ('read_global_config_file');
use vutil ('get_config');
use vutil ('get_config_vars');
use vutil ('get_credentials');
use vutil ('set_config');
use vutil ('set_config_vars');
use vutil ('set_credentials');
use vutil ('write_mysql');
use vutil ('stats_set');
use vutil ('stats_get');
use vutil ('set_datetime');
use vutil ('print_config');


# minimum number of mapped reads to consider reference for vntr
my $MIN_SUPPORT_REQUIRED = -1;

# DB/Web options
my $DBSUFFIX = "";  # set this to a unique short string,  ex: "run1"; DO NOT USE SPACES OR DOTS (.)

# used for generating links
my $SERVER = "";    # ex: orca.bu.edu

# General
my $NPROCESSES = -1; # set this to the number of processors on your system (or less if sharing the system with others or RAM is limited)
my $DOALLSTEPS = 0; # set to 0 to do one step at a time (recommended for test run), 1 to run though all steps (THIS IS OTIONAL AS SPECIFYING END STEP IS POSSIBLE)
my $strip_454_keytags = -1; # whether or not to strip leadint 'TCAG'
my $is_paired_reads = -1; # 0 = no paired reads, 1 = paired reads

# TRF options
my $TRF_EXECUTABLE = "trf407b-ngs.linux.exe";
my $TRF_EXE = "./$TRF_EXECUTABLE";

my $MATCH = 2;
my $MISMATCH = 5;
my $INDEL = 7;

my $MIN_FLANK_REQUIRED = -1;   # anything with less flank then this is discarded
my $MAX_FLANK_CONSIDERED = -1; # flank will be shorted during mapping to this
my $MIN_PERIOD_REQUIRED = 7;   # anything with pattern less then this is discarded

# temp (scratch) dir
my $TMPDIR = "";

# html folder (must be writable and executable!)
my $html_dir = ""; # ex: /var/www/html/vntrview/

# this is where gzipped fasta files are 
my $fasta_folder = ""; # ex: "/bfdisk/fastafiles/";

# this is where output will go
my $output_root = "";

# this is the reference leb36 file and sequence+flank data files, must be in install directory
my $reference_file = "";
my $reference_seq  = ""; 
my $reference_indist  = "";

my $reference_indist_produce  = -1; # setting this to 1 will produce reference_indist file instead of using the one provided

# hardcoded statistics
my $REFS_TOTAL = -1;

#my $REFS_REDUND = 374579;
my $REFS_REDUND = 0; # used to be used in latex file, not anymore

my $HELP = 0;
my $LOGIN = "";
my $PASS = "";
my $HOST = "";

# enter install directory
if (!chdir("$install_dir")) {
     { die("Install directory does not exist!"); }
}

# read global config file
read_global_config_file("$install_dir");

# get dbsuffix from command line
my @argv2 = @ARGV;
GetOptionsFromArray ( \@argv2 ,
		"HELP" => \$HELP,
		"LOGIN=s" => \$LOGIN,
		"PASS=s" => \$PASS,
		"HOST=s" => \$HOST,
		"NPROCESSES=i" => \$NPROCESSES,
		"MIN_FLANK_REQUIRED=i" => \$MIN_FLANK_REQUIRED,
		"MAX_FLANK_CONSIDERED=i" => \$MAX_FLANK_CONSIDERED,
		"MIN_SUPPORT_REQUIRED=i" => \$MIN_SUPPORT_REQUIRED,
		"DBSUFFIX=s" => \$DBSUFFIX,
		"SERVER=s" => \$SERVER,
		"STRIP_454_KEYTAGS=i" => \$strip_454_keytags,
		"IS_PAIRED_READS=i" => \$is_paired_reads,
		"HTML_DIR=s" => \$html_dir,
		"FASTA_DIR=s" => \$fasta_folder,
		"OUTPUT_ROOT=s" => \$output_root,
		"TMPDIR=s" => \$TMPDIR,
		"REFERENCE_FILE=s" => \$reference_file,
		"REFERENCE_SEQ=s" => \$reference_seq,
		"REFERENCE_INDIST=s" => \$reference_indist,
		"REFERENCE_INDIST_PRODUCE=i" => \$reference_indist_produce,
		"REFS_TOTAL=i" => \$REFS_TOTAL);



if ("" eq $DBSUFFIX) {
     die("Please set database suffix (DBSUFFIX) variable using command line. ");
}

# where config file will go
my $MSDIR = $ENV{HOME}."/${DBSUFFIX}.";

# set variables from vs.cnf
($SERVER,$TMPDIR,$html_dir,$fasta_folder,$output_root,$reference_file,$reference_seq,$reference_indist) = get_config($MSDIR);

# set more variables from vs.cnf
($NPROCESSES,$strip_454_keytags,$is_paired_reads,$reference_indist_produce,$MIN_SUPPORT_REQUIRED,$MIN_FLANK_REQUIRED,$MAX_FLANK_CONSIDERED,$REFS_TOTAL) = get_config_vars($MSDIR);


my $HELPSTRING = "\nUsage: $0 <start step> <end step> To tell the master script what step to execute. The first step is 0, last step is 19. \n\nOPTIONS:\n\n".
                 "\t--HELP                        prints this help message\n".
                 "\t--LOGIN                       mysql login\n".
                 "\t--PASS                        mysql pass\n".
                 "\t--HOST                        mysql host (default localhost)\n".
                 "\t--NPROCESSES                  number of processors on your system\n".
                 "\t--MIN_FLANK_REQUIRED          minimum required flank on both sides for a read TR to be considered (default 10)\n".
                 "\t--MAX_FLANK_CONSIDERED        maximum flank length used in flank alignments, set to big number to use full flank (default 50)\n".
                 "\t--MIN_SUPPORT_REQUIRED        minimum number of mapped reads which agree on copy number to call an allele (default 2)\n".
                 "\t--DBSUFFIX                    suffix for database name\n".
                 "\t--SERVER                      server name, used for html generating links\n".
                 "\t--STRIP_454_KEYTAGS           for 454 platform, strip leading 'TCAG', 0/1 (default 0)\n".
                 "\t--IS_PAIRED_READS             data is paired reads, 0/1 (default 0)\n".
                 "\t--HTML_DIR                    html directory (must be writable and executable!)\n".
                 "\t--FASTA_DIR                   input data directory (plain or gzipped fasta/fastq files)\n".
                 "\t--OUTPUT_ROOT                 output directory (must be writable and executable!)\n".
                 "\t--TMPDIR                      temp (scratch) directory (must be writable!)\n".
                 "\t--REFERENCE_FILE              reference profile file (default set in global config file)\n".
                 "\t--REFERENCE_SEQ               reference sequence file (default set in global config file)\n".
                 "\t--REFERENCE_INDIST            reference indistinguishables file (default set in global config file)\n".
                 "\t--REFERENCE_INDIST_PRODUCE    generate a file of indistinguishable references, 0/1 (default 0)\n".
                 "\t--REFS_TOTAL                  total number of reference TRs prior to filtering (default set in global config file)\n".
                 "\t\n\nADDITIONAL USAGE:\n\n".
                 "\t$0 100                       clear error\n".
                 "\t$0 100 N                     clear error and set NextRunStep to N (0-19, this is only when running on a cluster using the advanced cluster script that checks for NextRunStep)\n".
                 "\t\n\n";

die $HELPSTRING if not scalar(@ARGV);

my $STEP = $ARGV[0];

if (!($ARGV[0] =~ /^\d+?$/)) { die("Please specify an integer starting step. ");  }

my $STEPEND = -1;
if (scalar(@ARGV) > 1 && ($ARGV[1] =~ /^\d+?$/) && $ARGV[1]>=0 && $ARGV[1]<=99) { 
  $STEPEND = $ARGV[1]; 
  if ($STEPEND > $STEP) { $DOALLSTEPS=1; }
}

my $timestart;

# set these mysql credentials from vs.cnf
($LOGIN,$PASS,$HOST) = get_credentials($MSDIR);

# modify config variables based on command line
GetOptions (	
		"HELP" => \$HELP,
		"LOGIN=s" => \$LOGIN,
		"PASS=s" => \$PASS,
		"HOST=s" => \$HOST,
		"NPROCESSES=i" => \$NPROCESSES,
		"MIN_FLANK_REQUIRED=i" => \$MIN_FLANK_REQUIRED,
		"MAX_FLANK_CONSIDERED=i" => \$MAX_FLANK_CONSIDERED,
		"MIN_SUPPORT_REQUIRED=i" => \$MIN_SUPPORT_REQUIRED,
		"DBSUFFIX=s" => \$DBSUFFIX,
		"SERVER=s" => \$SERVER,
		"STRIP_454_KEYTAGS=i" => \$strip_454_keytags,
		"IS_PAIRED_READS=i" => \$is_paired_reads,
		"HTML_DIR=s" => \$html_dir,
		"FASTA_DIR=s" => \$fasta_folder,
		"OUTPUT_ROOT=s" => \$output_root,
		"TMPDIR=s" => \$TMPDIR,
		"REFERENCE_FILE=s" => \$reference_file,
		"REFERENCE_SEQ=s" => \$reference_seq,
		"REFERENCE_INDIST=s" => \$reference_indist,
		"REFERENCE_INDIST_PRODUCE=i" => \$reference_indist_produce,
		"REFS_TOTAL=i" => \$REFS_TOTAL);

# print help if asked
if ($HELP) {
 
 print $HELPSTRING;
 exit 0;
}

set_config($SERVER,$TMPDIR,$html_dir,$fasta_folder,$output_root,$reference_file,$reference_seq,$reference_indist);
set_config_vars($NPROCESSES,$strip_454_keytags,$is_paired_reads,$reference_indist_produce,$MIN_SUPPORT_REQUIRED,$MIN_FLANK_REQUIRED,$MAX_FLANK_CONSIDERED,$REFS_TOTAL);
set_credentials($LOGIN,$PASS,$HOST);

# write out the config file
print_config($MSDIR);


my $DBNAME = "VNTRPIPE_$DBSUFFIX";
my $HTTPSERVER = "$SERVER/vntrview";

# clustering parameters (only cutoffs, other nonessantial paramters are in run_proclu.pl
my $PROCLU_EXECUTABLE = "psearch.exe";
my $CLUST_PARAMS = " 88 ";
my $MINPROFSCORE = .85;

my $output_folder = "$output_root/vntr_$DBSUFFIX"; # DO NOT CHANGE, this 
# will be created at the output root by the pipeline, ex: "/bfdisk/vntr_$DBSUFFIX"; 

# this is where TRF output will go converted to leb36 format
my $read_profiles_folder = "$output_folder/data_out/";

# this is where renumbered and cyclicly removed reundancy leb36 files will go
my $read_profiles_folder_clean = "$output_folder/data_out_clean/";

# this is where cyclicly removed reundancy leb36 reference will go (also negated index)
my $reference_folder= "$output_folder/reference/";

# this is where edges are calculated
my $edges_folder= "$read_profiles_folder_clean/edges/";

my $TRF_PARAM = "'$TRF_EXE' - $MATCH $MISMATCH $INDEL 80 10 50 2000 -d -h -ngs";
my $TRF2PROCLU_EXE = 'trf2proclu-ngs.exe';
my $TRF2PROCLU_PARAM = "'./$TRF2PROCLU_EXE' -f 1 -m $MATCH -s $MISMATCH -i $INDEL -p $MIN_PERIOD_REQUIRED -l $MIN_FLANK_REQUIRED";


if ("" eq $SERVER) {
     die("Please set machine name (SERVER) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $LOGIN) {
     die("PPlease set  mysql login (LOGIN) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $PASS) {
     die("Please set mysql pass (PASS) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $HOST) {
     die("Please set mysql host (HOST) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($NPROCESSES <= 0) {
     die("Please set number of processes to be used by the pipeline (NPROCESSES) variable on the command line or in the ${MSDIR}vs.cnf.  ");
}

if ($MIN_FLANK_REQUIRED <= 0) {
     die("Please set min flank required to be used by the pipeline (MIN_FLANK_REQUIRED) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($MAX_FLANK_CONSIDERED <= 0) {
     die("Please set max flank required to be used by the pipeline (MAX_FLANK_CONSIDERED) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($MIN_SUPPORT_REQUIRED <= 0) {
     die("Please set min support required to be used by the pipeline (MIN_SUPPORT_REQUIRED) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($DOALLSTEPS < 0) {
     die("Please set doallsteps (DOALLSTEPS) variable. ");
}

if ($strip_454_keytags < 0) {
     die("Please set strip_454_keytags (strip_454_keytags) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($reference_indist_produce < 0) {
     die("Please set reference_indist_produce to be used by the pipeline (reference_indist_produce) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($is_paired_reads < 0) {
     die("Please set is_paired_reads (is_paired_reads) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ($REFS_TOTAL < 0) {
     die("Please set refs total (REFS_TOTAL) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $TRF_EXECUTABLE) {
     die("Please set trf executable (TRF_EXECUTABLE) variable. ");
}

if ("" eq $install_dir) {
     die("Please set install directory (install_dir) variable. ");
}

if ("" eq $html_dir) {
     die("Please set html directory (html_dir) variable on the command line or in the ${MSDIR}vs.cnf. ($html_dir)");
}
if (!(-e $html_dir) && !mkdir("$html_dir")) {
     die("Could not create html_dir directory ($html_dir). ");
}


if ("" eq $fasta_folder) {
     die("Please set fasta directory (fasta_dir) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $output_root) {
     die("Please set output directory (output_root) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $reference_file) {
     die("Please set reference .leb36 file (reference_file) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $reference_seq) {
     die("Please set reference .seq file (reference_seq) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $reference_indist) {
     die("Please set reference .indist file (reference_indist) variable on the command line or in the ${MSDIR}vs.cnf. ");
}

if ("" eq $TMPDIR) {
     die("Please set temporary directory (TMPDIR) variable on the command line or in the ${MSDIR}vs.cnf. ");
}


# check if required files and directories present and have correct permissions
unless (-e $TRF_EXECUTABLE) { die("File '$TRF_EXECUTABLE' not found!"); }
unless (-e $TRF2PROCLU_EXE) { die("File '$TRF2PROCLU_EXE' not found!"); }
unless (-e "redund.exe") { die("File 'redund.exe' not found!"); }
unless (-e "join_clusters.exe") { die("File 'join_clusters.exe' not found!"); }
unless (-e "flankalign.exe") { die("File 'flankalign.exe' not found!"); }
unless (-e "refflankalign.exe") { die("File 'refflankalign.exe' not found!"); }
unless (-e "pcr_dup.exe") { die("File 'pcr_dup.exe' not found!"); }
unless (-e $reference_file) { die("File '$reference_file' not found!"); }
unless (-e $reference_seq)  { die("File '$reference_seq' not found!"); }
if (!(-e $reference_indist) && !$reference_indist_produce)  { die("File '$reference_indist' not found!"); }
unless (-e $install_dir) { die("Directory '$install_dir' not found!"); }
unless (-e $html_dir) { die("Directory '$html_dir' not found!"); }
unless (-e $fasta_folder) { die("Directory '$fasta_folder' not found!"); }
unless (-e $output_root) { die("Directory '$output_root' not found!"); }
unless (-e "$TMPDIR") { die("Temporary directory '$TMPDIR' not found!"); }

unless (-x $TRF_EXECUTABLE) { die("File '$TRF_EXECUTABLE' not executable!"); }
unless (-x $TRF2PROCLU_EXE) { die("File '$TRF2PROCLU_EXE' not executable!"); }
unless (-x "redund.exe") { die("File 'redund.exe' not found!"); }
unless (-x "join_clusters.exe") { die("File 'join_clusters.exe' not executable!"); }
unless (-x "flankalign.exe") { die("File 'flankalign.exe' not executable!"); }
unless (-x "refflankalign.exe") { die("File 'refflankalign.exe' not executable!"); }
unless (-x "pcr_dup.exe") { die("File 'pcr_dup.exe' not executable!"); }
unless (-x $install_dir) { die("Directory '$install_dir' not executable!"); }
unless (-x $html_dir) { die("Directory '$html_dir' not executable!"); }
unless (-x $output_root) { die("Directory '$output_root' not executable!"); }
unless (-x "$TMPDIR") { die("Directory '$TMPDIR' not executable!"); }

unless (-w $html_dir) { die("Directory '$html_dir' not writable!"); }
unless (-w $output_root) { die("Directory '$output_root' not writable!"); }
unless (-w "$TMPDIR") { die("Directory '$TMPDIR' not writable!"); }

#unless (-x "$html_dir/aln.exe") { die("File '$html_dir/aln.exe' not executable!"); }
#unless (-x "$html_dir/malign") { die("File '$html_dir/malign' not executable!"); }


################################################################
sub trim($)
{
        my $string = shift;
        $string =~ s/^\s+//;
        $string =~ s/\s+$//;
        return $string;
}

####################################
sub SetDatetime {

  my $argc = @_;
  if ($argc <1) { die "stats_set: expects 1 parameter, passed $argc !\n"; }

  my $NAME = $_[0];

  return set_datetime($DBNAME,$LOGIN,$PASS,$HOST,$NAME);
}

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

sub SetError {

  my $argc = @_;
  if ($argc <3) { die "stats_set: expects 3 parameters, passed $argc !\n"; }

  my $VALUE1 = $_[0];
  my $VALUE2 = $_[1];
  my $VALUE3 = $_[2];

  stats_set($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_STEP",$VALUE1);
  stats_set($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_DESC",$VALUE2);
  stats_set($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_CODE",$VALUE3);

  return 0;
}

sub GlearError {

  my $argc = @_;
  if ($argc >= 1) {
     my $to = int($_[0]);

     if ($to <= 19) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_REPORTS",undef); }
     if ($to <= 18) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_ASSEMBLYREQ",undef); }
     if ($to <= 17) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_VNTR_PREDICT",undef); }
     if ($to <= 16) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_DUP",undef); }
     if ($to <= 15) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_PCR_DUP",undef); }
     if ($to <= 14) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_INDEX_PCR",undef); }
     if ($to <= 13) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_EDGES",undef); }
     if ($to <= 12) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_INSERT",undef); }
     if ($to <= 11) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_REFFLANKS",undef); }
     if ($to <= 10) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_FLANKS",undef); }
     if ($to <=  9) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_WRITE_FLANKS",undef); }
     if ($to <=  8) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_DB_INSTERT_READS",undef); }
     if ($to <=  7) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_DB_INSTERT_REFS",undef); }
     if ($to <=  5) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_JOINCLUST",undef); }
     if ($to <=  4) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_PROCLU",undef); }
     if ($to <=  3) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_REDUND",undef); }
     if ($to <=  2) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_RENUMB",undef); }
     if ($to <=  1) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_TRF",undef); }
     if ($to ==  0) { stats_set($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MYSQLCREATE",undef); }
     print "\nGlearError: making next step: $to.\n\n";
  }

  SetError($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_STEP",0);
  SetError($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_DESC","");
  SetError($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_CODE",0);
  return 0;
}

sub GetErrorStep {

  my $rc =  int(stats_get($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_STEP"));
  return $rc;
}

sub GetErrorDesc {

  my $rc =  stats_get($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_DESC");
  return $rc;
}

sub GetErrorCode {

  my $rc =  int(stats_get($DBNAME,$LOGIN,$PASS,$HOST,"ERROR_CODE"));
  return $rc;
}

sub GetNextStep {

  my $rc;

  # note: this will return 0 regardless if step 0 has been completed or not

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_REPORTS");
  if ("" ne $rc) { return 20;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_VNTR_PREDICT");
  if ("" ne $rc) { return 19;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_DUP");
  if ("" ne $rc) { return 17;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_PCR_DUP");
  if ("" ne $rc) { return 16;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_INDEX_PCR");
  if ("" ne $rc) { return 15;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_EDGES");
  if ("" ne $rc) { return 14;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_INSERT");
  if ("" ne $rc) { return 13;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_REFFLANKS");
  if ("" ne $rc) { return 12;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MAP_FLANKS");
  if ("" ne $rc) { return 11;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_WRITE_FLANKS");
  if ("" ne $rc) { return 10;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_DB_INSTERT_READS");
  if ("" ne $rc) { return 9;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_DB_INSTERT_REFS");
  if ("" ne $rc) { return 8;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_JOINCLUST");
  if ("" ne $rc) { return 7;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_PROCLU");
  if ("" ne $rc) { return 5 }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_REDUND");
  if ("" ne $rc) { return 4;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_RENUMB");
  if ("" ne $rc) { return 3;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_TRF");
  if ("" ne $rc) { return 2;  }

  $rc = stats_get($DBNAME,$LOGIN,$PASS,$HOST,"DATE_MYSQLCREATE");
  if ("" ne $rc) { return 1;  }

  return 0;
}



####################################


	
# pipeline error checking

if ($STEP != 0) {
	
	# clear error?
	if ($STEP == 100) {

		if ($STEPEND>=0 && $STEPEND<=19) 
			{ GlearError($STEPEND); }
		else
			{ GlearError(); }

	 	print STDERR "\n\nPipeline error cleared!\n";
		exit 0;
	}

        # get next step
        if ($STEP == 99) {
                exit GetNextStep();
        }

	my $rc =  GetErrorStep();
	if ( 0 != $rc ) {
		my $rc2=GetErrorDesc();
		my $rc3=GetErrorCode();
		die "\n\nPipeline error detected at step $rc (CODE:$rc3,'$rc2'). Call this program with step 100 to clear error.\n";
	}
    
}

####################################

if ($STEP == 0)  {

        $timestart = time();

        print STDERR "\n\nExecuting step #$STEP (creating MySQL database)...";

        if (!mkdir("$output_folder")) {
                warn "\nWarning: Failed to create data directory!\n";
        }

        write_mysql($DBNAME,$TMPDIR);

        my $exstring = "mysql -u $LOGIN --password=$PASS -h $HOST < $TMPDIR/${DBNAME}.sql";
        system($exstring);

        $exstring = "rm -f $TMPDIR/${DBNAME}.sql";
        system($exstring);

        if (!mkdir("$html_dir")) {
                warn "\nWarning: Failed to create html directory!\n";
        }
        if (!mkdir("$read_profiles_folder")) {
                warn "\nWarning: Failed to create output directory!\n";
        }


        SetStatistics("MAP_ROOT",$install_dir);
        SetStatistics("N_MIN_SUPPORT",$MIN_SUPPORT_REQUIRED);
        SetStatistics("MIN_FLANK_REQUIRED",$MIN_FLANK_REQUIRED);
	SetStatistics("MAX_FLANK_CONSIDERED",$MAX_FLANK_CONSIDERED);

        SetStatistics("TIME_MYSQLCREATE",time()-$timestart);
	SetDatetime("DATE_MYSQLCREATE");

        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=1;  }

}

if ($STEP == 1) {


        my $exstring = "rm -f ${read_profiles_folder}/*";
        system($exstring);

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (searching for tandem repeats in reads, producing profiles and sorting)...";
        my $extra_param  = ($strip_454_keytags) ? '-s' : '';
	my $extra_param2 = ($is_paired_reads) ? '-r' : '';
        system("./run_trf.pl -t \"$TRF_PARAM\" -u \"$TRF2PROCLU_PARAM\" $extra_param $extra_param2 -p $NPROCESSES $fasta_folder $read_profiles_folder");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"running TRF and TRF2PROCLU",$rc); die "command exited with value $rc"; }
        }



        SetStatistics("PARAM_TRF",$TRF_PARAM);
        SetStatistics("FOLDER_FASTA",$fasta_folder);
        SetStatistics("FOLDER_PROFILES",$read_profiles_folder);

        SetStatistics("TIME_TRF",time()-$timestart);
	SetDatetime("DATE_TRF");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=2;}
}

if ($STEP == 2) {


        print STDERR "\n\nExecuting step #$STEP (reassigning IDs to repeats)...";
        $timestart = time();

        my $exstring = "rm -f $reference_folder -R";
        system($exstring);

        system("./renumber.pl $read_profiles_folder");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling renumber.pl on reads profiles folder",$rc); die "command exited with value $rc"; }
        }


        if (!mkdir("$reference_folder")) {
                warn "\nWarning: Failed to create output directory!\n";
        }

        system("cp $reference_file $reference_folder/start.leb36");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"copying reference leb36 profile file into reference profiles folder",$rc); die "command exited with value $rc"; }
        }



        system("./renumber.pl -r -n  $reference_folder");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling renumber.pl on reference profiles folder",$rc); die "command exited with value $rc"; }
        }



        SetStatistics("FOLDER_REFERENCE",$reference_folder);
        SetStatistics("FILE_REFERENCE_LEB",$reference_file);
        SetStatistics("FILE_REFERENCE_SEQ",$reference_seq);

        SetStatistics("TIME_RENUMB",time()-$timestart);
	SetDatetime("DATE_RENUMB");

        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=3; }
}

if ($STEP == 3) {

        my $exstring = "rm -f ${read_profiles_folder_clean} -R";
        system($exstring);

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (eliminating cyclic redundancies)...";

        system("./redund.exe $reference_folder/start.leb36 $reference_folder/start2.leb36 -s -i");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling redund.exe on start.leb36 failed",$rc); die "command exited with value $rc"; }
        }


        system("./redund.exe $reference_folder/start2.leb36 $reference_folder/reference.leb36 -n -i");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling redund.exe on start2.leb36 failed",$rc); die "command exited with value $rc"; }
        }

        system("rm -f $reference_folder/start.leb36");

        system("rm -f $reference_folder/start2.leb36");


        if (!mkdir("$read_profiles_folder_clean")) {
                warn "\nWarning: Failed to create output directory!\n";
        }

        system("./redund.exe $read_profiles_folder/ $read_profiles_folder_clean/allreads.leb36 -i");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling redund.exe on read profiles folder failed",$rc); die "command exited with value $rc"; }
        }

        if (!chdir("$read_profiles_folder_clean")) {
		SetError($STEP,"could not enter clean profiles directory",-1);
                die("read profiles dir does not exist!");
        }
        my @files = <*>;
        my $file;
        foreach $file (@files) {
                if ($file =~ /^(.*)\.(\d+)$/) {
                        $exstring = "mv $file \"$2.$1\"";
                        system($exstring);
		        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
		        else {
		          my $rc = ($? >> 8);
		          if ( 0 != $rc ) { SetError($STEP,"renaming file `$file` failed",$rc); die "command exited with value $rc"; }
		        }

                }
        }


        if (!chdir("$install_dir")) {
		SetError($STEP,"could not enter install directory",-1);
                die("install dir does not exist!");
        }

        print STDERR "setting additional statistics...\n";
        system("./setdbstats.pl $reference_file $read_profiles_folder $reference_folder $read_profiles_folder_clean $DBNAME $MSDIR");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling setdbstats.pl failed",$rc); die "command exited with value $rc"; }
        }


        SetStatistics("FOLDER_PROFILES_CLEAN",$read_profiles_folder_clean);
        SetStatistics("TIME_REDUND",time()-$timestart);
	SetDatetime("DATE_REDUND");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=4; }
}

if ($STEP == 4) {

        my $exstring;
  
        $exstring = "rm -f ${read_profiles_folder_clean}/*.clu";
        system($exstring);

        $exstring = "rm -f ${read_profiles_folder_clean}/*.cnf";
        system($exstring);

        $exstring = "rm -f ${read_profiles_folder_clean}/*.proclu_log";
        system($exstring);


        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (performing bipartite clustering of tandem repeats profiles)...";

        $exstring = "./checkleb36.pl $read_profiles_folder_clean $reference_folder";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"checking leb36 files",$rc); die "command exited with value $rc"; }
        }

        #$exstring = "./run_proclu.pl 1 $read_profiles_folder_clean $reference_folder \"$CLUST_PARAMS\" $NPROCESSES '$PROCLU_EXECUTABLE' " . max( 4, int(0.4 * $MIN_FLANK_REQUIRED + .01)) . " $MAX_FLANK_CONSIDERED";
 
        # 0 for maxerror, means psearch will pick maxerror based on individual flanklength
        $exstring = "./run_proclu.pl 1 $read_profiles_folder_clean $reference_folder \"$CLUST_PARAMS\" $NPROCESSES '$PROCLU_EXECUTABLE' " . 0 . " $MAX_FLANK_CONSIDERED";

        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"performing bipartite clustering of tandem repeats profiles failed",$rc); die "command exited with value $rc"; }
        }


        # remove clusters with no references
        print STDERR "\nRemoving clusters with no references (clara/pam split)...\n";
        opendir(DIR, $read_profiles_folder_clean);
        my @files = grep(/clu$/, readdir(DIR));
        closedir(DIR);

        foreach my $file (@files) {
          print $file."\n";
          if (open(CLUF,"$read_profiles_folder_clean/$file")) {
            open(CLUFOUT,">$read_profiles_folder_clean/$file.clean");
            while (<CLUF>) {
                if (/-/) { print CLUFOUT $_; }
            }
            close(CLUF);
            close(CLUFOUT);
            system("mv $read_profiles_folder_clean/$file.clean $read_profiles_folder_clean/$file");
            if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
            else {
               my $rc = ($? >> 8);
               if ( 0 != $rc ) { SetError($STEP,"renaming files in clean directory failed",$rc); die "command exited with value $rc"; }
            }
          }
        }

        SetStatistics("PARAM_PROCLU",$CLUST_PARAMS);

        SetStatistics("TIME_PROCLU",time()-$timestart);
	SetDatetime("DATE_PROCLU");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=5; }
}

if ($STEP == 5) {	

	$timestart = time();
	print STDERR "\n\nExecuting step #$STEP (joining clusters from different proclu runs on reference ids)...";
	my $exstring = "./join_clusters.exe $read_profiles_folder_clean $read_profiles_folder_clean/all.clusters";
	system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"joining clusters from different proclu runs on reference ids failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_JOINCLUST",time()-$timestart);
	SetDatetime("DATE_JOINCLUST");
	print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=6; }
}

if ($STEP == 6) {

	$timestart = time();
	print STDERR "\n\nSTEP #$STEP IS EMPTY!";
	print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=7; }
}

if ($STEP == 7) {

	$timestart = time();
 	my $exstring;
	print STDERR "\n\nExecuting step #$STEP (inserting REFERENCE flanks into database)...";
	$exstring = "echo \"truncate TABLE $DBNAME.fasta_ref_reps; LOAD DATA LOCAL INFILE '$install_dir/$reference_seq' INTO TABLE $DBNAME.fasta_ref_reps FIELDS TERMINATED BY ',' IGNORE 1 LINES;\" > $TMPDIR/${DBNAME}_2.sql";
	system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"inserting REFERENCE flanks into database (script creation) failed",$rc); die "command exited with value $rc"; }
        }


	$exstring = "mysql -u $LOGIN --password=$PASS -h $HOST --local-infile=1 $DBNAME < $TMPDIR/${DBNAME}_2.sql";
	system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"inserting REFERENCE flanks into database (mysql call) failed",$rc); die "command exited with value $rc"; }
        }

	$exstring = "rm -f $TMPDIR/${DBNAME}_2.sql";
	system($exstring);

	SetStatistics("TIME_DB_INSTERT_REFS",time()-$timestart);
	SetDatetime("DATE_DB_INSTERT_REFS");

	print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=8; }
}

if ($STEP == 8) {

	$timestart = time();
	print STDERR "\n\nExecuting step #$STEP (inserting READS flanks into database)...";
	my $extra_param = ($strip_454_keytags) ? '1' : '0';
	my $exstring = "./insert_reads.pl $read_profiles_folder_clean/all.clusters $read_profiles_folder  $fasta_folder $read_profiles_folder_clean $reference_folder/reference.leb36.rotindex $extra_param $DBNAME $MSDIR $TMPDIR $is_paired_reads";
	system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"inserting READS flanks into database failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_DB_INSTERT_READS",time()-$timestart);
	SetDatetime("DATE_DB_INSTERT_READS");
	print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=9; }
}

if ($STEP == 9) {

	$timestart = time();
	print STDERR "\n\nExecuting step #$STEP (outputting flanks inside each cluster)...";
	my $exstring = "./run_flankcomp.pl $read_profiles_folder_clean/allwithdups.clusters $DBNAME $MSDIR $TMPDIR > $read_profiles_folder_clean/allwithdups.flanks";
	system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"outputting flanks inside each cluster failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_WRITE_FLANKS",time()-$timestart);
	SetDatetime("DATE_WRITE_FLANKS");
	print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=10; }
}

if ($STEP == 10) {

	$timestart = time();

	system("rm -Rf ${read_profiles_folder_clean}/out");

        if (!mkdir("${read_profiles_folder_clean}/out")) {
                warn "\nWarning: Failed to create output directory!\n";
        }

        print STDERR "\n\nExecuting step #$STEP (aligning ref-read flanks)...";        
        #my $exstring = "./flankalign.exe $read_profiles_folder_clean/out $read_profiles_folder_clean/result $read_profiles_folder_clean/allwithdups.flanks " . min( 8, int(0.4 * $MIN_FLANK_REQUIRED + .01)) . " $MAX_FLANK_CONSIDERED $NPROCESSES 15";

        # 0 for maxerror, means flankalign will pick maxerror based on individual flanklength
        my $exstring = "./flankalign.exe $read_profiles_folder_clean/out $read_profiles_folder_clean/result $read_profiles_folder_clean/allwithdups.flanks " . 0 . " $MAX_FLANK_CONSIDERED $NPROCESSES 15";

	print STDERR "$exstring\n";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"aligning ref-read flanks failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_MAP_FLANKS",time()-$timestart);
	SetDatetime("DATE_MAP_FLANKS");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=11; }
}

if ($STEP == 11) {

        $timestart = time();
        my $exstring;

        print STDERR "\n\nExecuting step #$STEP (aligning ref-ref flanks)...";

	system("rm -Rf ${read_profiles_folder_clean}/result");

        if (!mkdir("${read_profiles_folder_clean}/result")) {
                warn "\nWarning: Failed to create output result directory!\n";
        }

	if ($reference_indist_produce) {
        print STDERR "\n\n(generating indist file)...";

		# enter result dir
		if (!chdir("${read_profiles_folder_clean}/result")) {
		     { die("result directory does not exist!"); }
		}


		# copy reference file to result dir
        	system("cp ${install_dir}/$reference_file .");
	        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
	        else {
	          my $rc = ($? >> 8);
	          if ( 0 != $rc ) { SetError($STEP,"copying reference leb36 profile file into reference profiles folder",$rc); die "command exited with value $rc"; }
	        }
	

		$exstring = "${install_dir}/$PROCLU_EXECUTABLE" . " " .  "${reference_folder}/reference.leb36"  . " " . "$reference_file" . " " . "${install_dir}/eucledian.dst" . " " . $CLUST_PARAMS . " " . 5 . " 0  -r 50 2> " . "ref_to_ref.proclu_log";
		print "\nrunning: $exstring\n";
		system($exstring);
        	if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
	        else {
	          my $rc = ($? >> 8);
	          if ( 0 != $rc ) { SetError($STEP,"aligning ref-ref flanks failed",$rc); die "command exited with value $rc"; }
	        }


	        my $refclusfile = "$reference_file.clu";
	        system("mv $refclusfile ${install_dir}/");
	        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
	        else {
	          my $rc = ($? >> 8);
	          if ( 0 != $rc ) { SetError($STEP,"aligning ref-ref flanks failed",$rc); die "command exited with value $rc"; }
	        }
	        $refclusfile =  "${install_dir}/$refclusfile";


	        # create final indist file
	        my $indist_withpath = "${install_dir}/$reference_indist";
	        open TOFILE, ">$indist_withpath" or die $!;
	        open FILE, "<$refclusfile" or die $!;
        	        while (<FILE>) {
                	 my @values = split(' ', $_);
	                 my $repcount = @values - 1;

	                 my $i=0;
        	         foreach my $val (@values) {

	                   $i++;
        	           $val = trim($val);

	                   if (my $ch = ($val =~ m/(\-*\d+)([\-\+])$/g)) {
        	             if ($1 < 0 && $repcount > 2)
                	       { print TOFILE $1."\n"; }
	                   }

        	         }

	        }
	        close(FILE);
	        close(TOFILE);

	        # remove working files
	        system("rm -f ${read_profiles_folder_clean}/result/$reference_file -f");
	        system("rm -f ${read_profiles_folder_clean}/result/ref_to_ref.proclu_log -f");


	        # go back to install dir
	        if (!chdir("$install_dir")) {
	             { die("Install directory does not exist!"); }
	        }
	}

	# update DB
        print STDERR "\n\n(updating database with dist/undist info)...";
        $exstring = "./vntrpipe_xml2sql.pl -r -k5 -t50 -d $DBNAME -u $MSDIR $reference_indist";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"updating database with dist/undist info failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_MAP_REFFLANKS",time()-$timestart);
	SetDatetime("DATE_MAP_REFFLANKS");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=12; }
}

if ($STEP == 12) {

        $timestart = time();

	if (!chdir("$install_dir")) {
	     { die("Install directory does not exist!"); }
	}

        print STDERR "\n\nExecuting step #$STEP (inserting map and rankflank information into database.)";
        my $exstring = "./run_rankflankmap.pl $read_profiles_folder_clean/allwithdups.clusters $read_profiles_folder_clean/out $TMPDIR $DBNAME $MSDIR";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"inserting map and rankflank information into database failed",$rc); die "command exited with value $rc"; }
        }

	SetStatistics("TIME_MAP_INSERT",time()-$timestart);
	SetDatetime("DATE_MAP_INSERT");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=13; }
}

if ($STEP == 13) {

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (calculating edges)...";
        my $exstring = "./run_edges.pl  $reference_file $edges_folder $DBNAME $MSDIR $MINPROFSCORE $NPROCESSES $PROCLU_EXECUTABLE $TMPDIR";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calculating edges failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_EDGES",time()-$timestart);
	SetDatetime("DATE_EDGES");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=14; }
}

if ($STEP == 14) {

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (generating .index files for pcr_dup)...";

        my $exstring = "./extra_index.pl $read_profiles_folder_clean/best $DBNAME $MSDIR $TMPDIR";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"generating .index files for pcr_dup failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_INDEX_PCR",time()-$timestart);
	SetDatetime("DATE_INDEX_PCR");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=15; }
}

if ($STEP == 15) {

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (calculating PCR duplicates) ...";

        my $exstring = "./pcr_dup.pl $read_profiles_folder_clean/best $read_profiles_folder_clean $DBNAME $MSDIR $NPROCESSES $TMPDIR";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calculating PCR duplicates failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_PCR_DUP",time()-$timestart);
	SetDatetime("DATE_PCR_DUP");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=16; }
}

if ($STEP == 16) {

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (removing mapped duplicates) ...";

        my $exstring = "./map_dup.pl $DBNAME $MSDIR $TMPDIR > $read_profiles_folder_clean/result/$DBNAME.map_dup.txt";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calculating mapped duplicates failed",$rc); die "command exited with value $rc"; }
        }


	SetStatistics("TIME_MAP_DUP",time()-$timestart);
	SetDatetime("DATE_MAP_DUP");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=17; }
}

if ($STEP == 17) {

	$timestart = time();
        print STDERR "\n\nExecuting step #$STEP (computing variability)...";
        my $exstring = "./run_variability.pl $read_profiles_folder_clean/allwithdups.clusters $read_profiles_folder_clean/out $DBNAME $MSDIR $MIN_FLANK_REQUIRED $TMPDIR";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"computing variability failed",$rc); die "command exited with value $rc"; }
        }

	SetStatistics("TIME_VNTR_PREDICT",time()-$timestart);
	SetDatetime("DATE_VNTR_PREDICT");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=18; }
}

if ($STEP == 18) {

	$timestart = time();

        print STDERR "\n\nSTEP #$STEP IS EMPTY!";

        #print STDERR "\n\nExecuting step #$STEP (computing variability - assembly required)...";
        #my $exstring = "./run_assemblyreq.pl $read_profiles_folder_clean/allwithdups.clusters $read_profiles_folder_clean/out $DBNAME $MSDIR $MIN_FLANK_REQUIRED $TMPDIR";
        #system($exstring);
        #if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        #else {
        #  my $rc = ($? >> 8);
        #  if ( 0 != $rc ) { SetError($STEP,"computing variability (assembly required) failed",$rc); die "command exited with value $rc"; }
        #}

	SetStatistics("TIME_ASSEMBLYREQ",time()-$timestart);
	SetDatetime("DATE_ASSEMBLYREQ");
        print STDERR "done!\n";

	if ($STEPEND == $STEP) { $STEP = 100; }
	elsif ($DOALLSTEPS) { $STEP=19; }
}

if ($STEP == 19) {

        $timestart = time();
        print STDERR "\n\nExecuting step #$STEP (final database update)...";


        # copy vs.cnf for reading purposes, remove login and pass
        my $thisfile = $MSDIR."/"."vs.cnf";
	if (open(MFREAD,"$thisfile")) {
  	  if (!open(MFWRITE,">${read_profiles_folder_clean}/result/master.txt")) { SetError($STEP,"cannot open ${read_profiles_folder_clean}/result/master.txt for writing",-1); die "cannot open ${read_profiles_folder_clean}/result/master.txt for writing!"; };
	  while(<MFREAD>) {
	    if (index($_, "LOGIN") != -1) {
   	      print MFWRITE "LOGIN=\n";
	    } elsif (index($_, "PASS") != -1) {
   	      print MFWRITE "PASS=\n";
	    } else {
  	      print MFWRITE $_;
	    }
 	  } 
	  close(MFWRITE);
	  close(MFREAD);
	}

	# lets do this setdbstats again (sometimes when copying databases steps are omited so this might not have been executed)
        print STDERR "setting additional statistics...\n";
        system("./setdbstats.pl $reference_file $read_profiles_folder $reference_folder $read_profiles_folder_clean $DBNAME $MSDIR");
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"calling setdbstats.pl failed",$rc); die "command exited with value $rc"; }
        }


	# distribution, image and latex files
        my $exstring = "perl updaterefs.pl $read_profiles_folder $read_profiles_folder_clean $DBNAME $MSDIR $read_profiles_folder_clean/out/representatives.txt ${read_profiles_folder_clean}/result/${DBNAME} $REFS_TOTAL $REFS_REDUND $HTTPSERVER $MIN_SUPPORT_REQUIRED $VERSION $TMPDIR";
        system($exstring);
        if ( $? == -1 ) { SetError($STEP,"command failed: $!",-1); die "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { SetError($STEP,"final database update",$rc); die "command exited with value $rc"; }
        }

	# create sim link to html dir so can be browsed from internet
        $exstring = "ln -s ${read_profiles_folder_clean}/result $html_dir/$DBNAME";
        system($exstring);
        if ( $? == -1 ) {  warn "command failed: $!\n"; }
        else {
          my $rc = ($? >> 8);
          if ( 0 != $rc ) { warn "command exited with value $rc"; }
        }


	# cleanup
	print STDERR "Cleanup...\n";
        #$exstring = "rm -rf $read_profiles_folder_clean/best";
        #system($exstring);
        #$exstring = "rm -rf $read_profiles_folder_clean/edges";
        #system($exstring);
        #$exstring = "rm -rf $read_profiles_folder_clean/out";
        #system($exstring);


	SetStatistics("TIME_REPORTS",time()-$timestart);
	SetDatetime("DATE_REPORTS");
        print STDERR "done!\n";
}

print STDERR "\n\nFinished!\n\n";

0;

