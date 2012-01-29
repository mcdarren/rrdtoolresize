#!/usr/bin/perl
#
my $USAGE = "#
#  Usage: $0 [ -v verbosity ] [ -f ] \
  [ -R rranum:rows[;rranum:rows]* | -P pdp:rows[;pdp:rows]* ] RRDs(s)
#  Where:
#    -v verbosity   Specify the verbosity level (default = 10)
#    -f             Fake (dry) run (assumed if -R not specified)
#    -R X:Y[;X:Y]*  Resize rra X to have Y rows
#    -M X:Y[;X:Y]*  Remap every RRA with X pdps to Y rows
#
#  File(s)
#    These are RRD files that need to be 're-shaped'
#
#  If neither -M nor -P is specified, then info about the RRD
#    will be printed
#  If both -M and -R are specified, then -R takes precedence
#
";
#

use strict;
use warnings;

use RRDs;
use Getopt::Std;
use Data::Dumper;
use Time::HiRes qw/time/;

my $rrdtool = $ENV{'RRDTOOL'} || 'rrdtool';

my %opt;
getopts('fP:R:v:', \%opt) || die $USAGE;

my $verbosity = $opt{'v'} || 10;
my $rrastr    = $opt{'R'};
my $pdpstr    = $opt{'P'};
my $dryrun    = (defined $opt{'f'}) ||
                  ((!defined $rrastr) && (!defined $pdpstr)) ? 1 : 0;
my $dumpinfo  = ($verbosity >= 20) ||
                  (!defined $pdpstr && !defined $rrastr) ? 1 : 0;

my %rramap;
if (defined $rrastr) {
  my @rows = split(/\s*;\s*/, $rrastr);
  foreach my $redo (@rows) {
    my @info = split(/\s*:\s*/, $redo);
    if ($#info != 1) {
      die "Bad rra resize specification ($redo) in -R $rrastr! Died";
    }
    elsif ($info[1] < 1) {
      die "Invalid rra row count ($info[1]) in -R $rrastr! Died";
    }
    elsif ($info[0] !~ /^\d+$/) {
      die "Invalid rra number ($info[0]) in -R $rrastr! Died";
    }
    else {
      $rramap{$info[0]} = int($info[1]);
    }
  }
}

my %pdpmap;
if (defined $pdpstr) {
  my @rows = split(/\s*;\s*/, $pdpstr);
  foreach my $redo (@rows) {
    my @info = split(/\s*:\s*/, $redo);
    if ($#info != 1) {
      die "Bad rra resize specification ($redo) in -P $pdpstr! Died";
    }
    elsif ($info[1] < 1) {
      die "Invalid rra pdp count ($info[1]) in -P $pdpstr! Died";
    }
    elsif ($info[0] !~ /^\d+$/) {
      die "Invalid rra number ($info[0]) in -P $pdpstr! Died";
    }
    else {
      $pdpmap{$info[0]} = int($info[1]);
    }
  }
}


my @rrds = @ARGV;
my $start = time;
my $numfiles = 0;

for my $rrd (sort @rrds) {
    print "\nProcessing $rrd\n";
    my $info = RRDs::info $rrd;
    # Check to ensure we actually have a valid rrd file
    if ($info->{filename}) {
       printf "DEBUG: RRD %s info: %s\n",
         $rrd, join("\n", sort split(/\n/, Dumper($info)))
         if ($dumpinfo);
    }
    else {
        print "$rrd isn't a valid rrd log, skipping\n";
        next;
    }

    $numfiles++;
    my @rras = sort map { substr($_, 4, index($_, ']', 4)-4) }
                   grep { /rra\[\d+\].pdp_per_row/ } keys %{$info};

    ## Debug:
    # printf "Found:\n  %s\n", join("\n  ",
    #        grep { /rra\[\d+\].pdp_per_row/ } keys %{$info});
    # printf "RRAs: %s\n", join(" ", @rras);

    foreach my $rra (sort { $a <=> $b } @rras) {
        my $cmd = qq|$rrdtool resize $rrd |;
        my $rows = $info->{"rra[$rra].rows"};
        my $cf = $info->{"rra[$rra].cf"};
        my $pdp = $info->{"rra[$rra].pdp_per_row"};
        printf "\tDS %s => PDP per row:%.f Rows:%.f CF:%s\n",
            $rra, $pdp, $rows, $cf; 
        my $wanted = (defined $rramap{$rra}) ? $rramap{$rra} :
                        (defined $pdpmap{$pdp}) ? $pdpmap{$pdp} : -1;
        if ($wanted <= 0)
        {
          printf "DEBUG: Skipping RRA %s (no map found)\n", $rra
            if ($verbosity >= 15);
          next;
        }
        
        my $diff = $rows - $wanted;
        if ($diff < 0) {
            $diff = abs($diff);
            $cmd .= qq|$rra GROW $diff|;
        }
        elsif ($diff > 0) {
            $cmd .= qq|$rra SHRINK $diff|;
        }
        else {
            print "\tNo change to DS $rra\n\n";
            next;
        }

        print "\tResizing to $wanted rows, executing $cmd\n";
        if (!$dryrun) {
          system($cmd) == 0 or die "\tCould not execute $cmd: $!";
          print "\tRenaming resized file\n";

          # We jump through a number of hoops because the RRD may not
          # be in the current directory (but the created "resize.rrd"
          # IS in the current directory!)
          unlink $rrd.'.bk';

          # Do this in case one of the steps below fails
          rename $rrd, $rrd.'.bk' ||
            die "\tUnable to move the old $rrd way!  Stopping";

          if (!link('resize.rrd', $rrd)) {
            print "\tNOTICE: link(resize.rrd, $rrd) failed.".
                  "  Trying 'mv' instead!\n";
            if (system("mv resize.rrd $rrd")) {
              # Try to put the original RRD back
              rename $rrd.'.bk', $rrd;
              die "\tFailed to link/move resize.rrd to $rrd!  Died";
            }
          }
          else {
            unlink 'resize.rrd';
            unlink $rrd.'.bk';
          }
          print "\tDone.\n";
        }
    }
}

my $end = time;
my $dur = sprintf('%.2f', $end - $start);
print "Finished, processed $numfiles files in $dur seconds\n\n";
